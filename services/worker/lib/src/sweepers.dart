import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:postgres/postgres.dart';

/// What one pass did. Reported rather than logged as a sentence, so a run can
/// be asserted on in a test and graphed in production.
final class SweepResult {
  const SweepResult({required this.name, required this.affected});
  final String name;
  final int affected;

  @override
  String toString() => '$name: $affected';
}

/// Tidying up after the paths that already work without it.
///
/// **None of these is a guarantee.** Every one of them is an optimisation over
/// a correctness property that already holds elsewhere, and that ordering is
/// deliberate: a worker that has not run for a day must not be able to sell a
/// seat twice or let a spent code work.
///
///   * `claim()` already treats a lapsed hold as available, so a stalled
///     sweeper cannot leak inventory — it can only leave a row saying `active`
///     that everybody already ignores.
///   * A sign-in code is refused by the conditional write that consumes it, so
///     an unswept challenge is not a way in; it is personal data we no longer
///     need.
///   * A reservation past its deadline is refused by `payment_deadline > now()`
///     in the lookup, so an unswept one cannot be collected.
///
/// If any of that stops being true, the fix belongs in the path, not here.
final class Sweepers {
  const Sweepers(this._db);

  final Database _db;

  /// Marks lapsed holds and puts their seats back on sale.
  ///
  /// The seats are released in the **same statement set** as the hold, and
  /// only for seats still pointing at that hold — a seat that has since been
  /// sold under a booking must not be dragged back to `available` by a
  /// sweeper arriving late.
  Future<SweepResult> expireHolds({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final lapsed = await tx.execute(
          Sql.named('''
            UPDATE holds SET state = 'expired'
             WHERE id IN (
                     SELECT id FROM holds
                      WHERE state = 'active' AND expires_at <= now()
                      ORDER BY expires_at
                      LIMIT @limit
                      FOR UPDATE SKIP LOCKED
                   )
            RETURNING id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        if (lapsed.isEmpty) {
          return const SweepResult(name: 'holds.expired', affected: 0);
        }

        final ids = [for (final row in lapsed) row.toColumnMap()['id']];

        await tx.execute(
          Sql.named('''
            UPDATE seats
               SET state = 'available', hold_id = NULL, held_until = NULL
             WHERE hold_id = ANY(@ids::uuid[])
               AND state = 'held'
          '''),
          parameters: {
            'ids': TypedValue(Type.textArray, [for (final id in ids) '$id']),
          },
          ignoreRows: true,
        );

        return SweepResult(name: 'holds.expired', affected: lapsed.length);
      });

  /// Expires reservations nobody paid for, and puts the seats back.
  ///
  /// The four-hour window closed and the traveller never walked in. Their
  /// seats have been unsellable since, which is the cost of the flow and the
  /// reason the window is four hours rather than a day.
  Future<SweepResult> expireReservations({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final expired = await tx.execute(
          Sql.named('''
            UPDATE bookings
               SET state = 'expired', payment_code = NULL
             WHERE id IN (
                     SELECT id FROM bookings
                      WHERE state = 'pending_payment'
                        AND payment_deadline <= now()
                      ORDER BY payment_deadline
                      LIMIT @limit
                      FOR UPDATE SKIP LOCKED
                   )
            RETURNING id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        if (expired.isEmpty) {
          return const SweepResult(name: 'bookings.expired', affected: 0);
        }

        final ids = [for (final row in expired) '${row.toColumnMap()['id']}'];

        // `state = 'held'` in the WHERE, so a seat somebody paid for between
        // the SELECT and here is untouched. A sweeper that could un-sell a
        // seat is worse than no sweeper.
        await tx.execute(
          Sql.named('''
            UPDATE seats
               SET state = 'available', hold_id = NULL, held_until = NULL,
                   booking_id = NULL
             WHERE booking_id = ANY(@ids::uuid[]) AND state = 'held'
          '''),
          parameters: {'ids': TypedValue(Type.textArray, ids)},
          ignoreRows: true,
        );

        return SweepResult(name: 'bookings.expired', affected: expired.length);
      });

  /// Deletes spent and stale sign-in codes.
  ///
  /// The only sweeper here that deletes rather than marks, and the reason is
  /// that these rows are **personal data with no remaining purpose**: an
  /// address, a timestamp and a dead hash. A retention window rather than
  /// immediate deletion, so "how many people bounced off sign-in this week"
  /// stays answerable for a week.
  Future<SweepResult> purgeChallenges({
    Duration retain = const Duration(days: 7),
    int limit = 5000,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    final deleted = await tx.execute(
      Sql.named('''
        DELETE FROM auth_challenges
         WHERE id IN (
                 SELECT id FROM auth_challenges
                  WHERE created_at < now() - make_interval(secs => @retain)
                  LIMIT @limit
               )
        RETURNING id
      '''),
      parameters: {
        'retain': TypedValue(Type.double, retain.inSeconds.toDouble()),
        'limit': TypedValue(Type.integer, limit),
      },
    );

    return SweepResult(name: 'challenges.purged', affected: deleted.length);
  });
}
