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
  /// The occupancy is deleted in the **same statement set** as the hold, and
  /// only the occupancy that names it — a piece of a seat that has since been
  /// sold under a booking carries no hold at all, so a sweeper arriving late
  /// cannot drag it back on sale.
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
            DELETE FROM seat_occupancy WHERE hold_id = ANY(@ids::uuid[])
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

        // An unpaid reservation occupies its seats under the hold it was
        // made from, never under its own id — that is what makes it read as
        // held rather than sold. So this deletes by the hold, which also
        // means a booking that was paid for between the SELECT and here is
        // untouched: its occupancy stopped naming a hold at the moment of the
        // sale. A sweeper that could un-sell a seat is worse than no sweeper.
        await tx.execute(
          Sql.named('''
            DELETE FROM seat_occupancy o
             USING bookings b
             WHERE b.id = ANY(@ids::uuid[]) AND o.hold_id = b.hold_id
          '''),
          parameters: {'ids': TypedValue(Type.textArray, ids)},
          ignoreRows: true,
        );

        return SweepResult(name: 'bookings.expired', affected: expired.length);
      });

  /// Closes change orders whose seats have gone back on sale.
  ///
  /// Runs **after** `expireHolds`, and depends on it: the hold is what
  /// actually released the seats, and this pass only records that the promise
  /// attached to them has lapsed. Written the other way round it would mark
  /// orders expired while their seats were still held, which is a departure
  /// that looks full to everybody and is owed to nobody.
  ///
  /// An order with a payment still in flight is left alone. The money may yet
  /// land; the capture path finds the seats gone, closes the order itself and
  /// leaves an intent somebody has to refund — which is a state a human can
  /// see and fix, unlike an order quietly expired underneath a live prompt.
  Future<SweepResult> expireChangeOrders({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final lapsed = await tx.execute(
          Sql.named('''
            UPDATE booking_changes SET state = 'expired'
             WHERE id IN (
                     SELECT c.id FROM booking_changes c
                      WHERE c.state = 'awaiting_payment'
                        AND c.expires_at <= now()
                        AND NOT EXISTS (
                              SELECT 1 FROM payment_intents i
                               WHERE i.change_id = c.id
                                 AND i.state IN ('created','pending',
                                                 'authorized','indeterminate'))
                      ORDER BY c.expires_at
                      LIMIT @limit
                      FOR UPDATE SKIP LOCKED
                   )
            RETURNING id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return SweepResult(name: 'changes.expired', affected: lapsed.length);
      });

  /// Closes open protection calls nobody answered in time
  /// (`08-disruption.md` §5).
  ///
  /// A call with no end is a call still on every console on the road next
  /// week, and an inbox of stale requests for help is an inbox nobody opens —
  /// which costs the next real call its answer. `expires_at` is what the
  /// broadcaster chose; this pass is what makes it mean anything.
  ///
  /// Marks rather than deletes, like every sweeper here but one: the coach
  /// that broke down and the fact that nobody came is what an operator looks
  /// at when they are deciding whether this channel is worth being in.
  Future<SweepResult> expireProtectionCalls({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final lapsed = await tx.execute(
          Sql.named('''
            UPDATE protection_calls SET state = 'expired', closed_at = now()
             WHERE id IN (
                     SELECT c.id FROM protection_calls c
                      WHERE c.state = 'open'
                        AND c.expires_at <= now()
                      ORDER BY c.expires_at
                      LIMIT @limit
                      FOR UPDATE SKIP LOCKED
                   )
            RETURNING id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return SweepResult(name: 'calls.expired', affected: lapsed.length);
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
