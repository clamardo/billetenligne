import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/seat_inventory.dart';
import '../db/database.dart';
import 'seat_occupancy.dart';

/// The seat race, decided by Postgres.
///
/// Everything else in this product is recoverable. Selling seat 12A twice is
/// not: two people arrive at a coach with valid tickets and one of them is
/// left at the roadside at 05:00. So this adapter is written the boring way —
/// one transaction, explicit row locks taken in a fixed order, and the
/// database's own clock deciding what "expired" means.
///
/// Three decisions are load-bearing:
///
///  1. **The database is the clock.** Expiry is `now() + interval` computed
///     server-side, never a timestamp from Dart. Two API instances a few
///     seconds apart must not disagree about who owns a seat.
///  2. **The race is decided by a constraint, not by a lock we remembered to
///     take.** Since ADR-0025 a claim writes a row into `seat_occupancy`, and
///     the EXCLUDE constraint there refuses the second one. A `SELECT ... FOR
///     UPDATE` is a rule that has to be repeated in every path that ever
///     touches inventory; an exclusion constraint is a rule the database
///     applies to paths nobody has written yet.
///  3. **An expired hold is available.** Checked here on every read, not left
///     to the sweeper — a worker that has been stuck for ten minutes must not
///     be able to strand an operator's inventory.
/// Somebody else got the seats between the read and the write.
///
/// Carried out of the transaction as an exception so that the transaction is
/// *undone*, rather than committing a hold over seats it does not hold. Never
/// leaves this file: [PostgresSeatInventory.claim] turns it back into the
/// ordinary refusal the caller expects.
final class _SeatsWentFirst implements Exception {
  const _SeatsWentFirst(this.labels);
  final List<String> labels;
}

final class PostgresSeatInventory implements SeatInventory {
  const PostgresSeatInventory(this._db);

  final Database _db;

  @override
  Future<ClaimOutcome> claim(SeatClaim claim) async {
    final scope = DbScope.traveller(claim.userId);

    try {
      return await _db.transaction(scope, (tx) async {
        // ── A retry is the normal case, not the exception ────────────────────
        // Congo's networks drop requests routinely, so clients retry. The unique
        // index on holds.idempotency_key is what makes that safe; this lookup is
        // what makes it *fast* and lets the traveller see the hold they already
        // have rather than an error about a seat they already hold.
        final replay = await _findByKey(tx, claim.idempotencyKey);
        if (replay != null) return replay;

        final sellable = await _checkDeparture(tx, claim.departureId);
        if (sellable != null) return sellable;

        // ── Read the seats once, and classify ────────────────────────────────
        // One plain read, and no lock. The seats race is settled by the
        // exclusion constraint a few statements below, so there is nothing here
        // worth locking; what this read is for is the fare, the operator, and
        // being able to tell a traveller *which* seats went rather than that
        // their seat map is out of date.
        final priced = await tx.execute(
          Sql.named('''
          SELECT seat_label,
                 state::text AS state,
                 fare_minor,
                 currency,
                 operator_id,
                 held_until IS NOT NULL AND held_until <= now() AS hold_lapsed
            FROM seats
           WHERE departure_id = @departure AND seat_label = ANY(@labels)
           ORDER BY seat_label
        '''),
          parameters: {
            'departure': TypedValue(Type.uuid, claim.departureId),
            'labels': TypedValue(Type.textArray, claim.seatLabels),
          },
        );

        final states = {
          for (final row in priced)
            row.toColumnMap()['seat_label'] as String:
                row.toColumnMap()['state'] as String,
        };

        final unknown = [
          for (final label in claim.seatLabels)
            if (!states.containsKey(label)) label,
        ];
        if (unknown.isNotEmpty) return SeatsUnknown(unknown);

        // `sold` and `blocked` are terminal — neither becomes available again.
        final terminal = [
          for (final entry in states.entries)
            if (entry.value == 'sold' || entry.value == 'blocked') entry.key,
        ]..sort();
        if (terminal.isNotEmpty) return SeatsTaken(terminal);

        final taken = <String>[];
        var fareMinor = 0;
        String? currencyCode;
        String? operatorId;

        for (final row in priced) {
          final r = row.toColumnMap();
          final label = r['seat_label'] as String;
          final state = r['state'] as String;
          final lapsed = (r['hold_lapsed'] as bool?) ?? false;

          // Held and still live belongs to somebody else. Held but lapsed is
          // ours to take — that is the check the sweeper is a backstop for, not
          // the other way round. `partial` is a seat somebody bought a piece
          // of, and a claim for the whole road cannot have it.
          if ((state == 'held' && !lapsed) || state == 'partial') {
            taken.add(label);
            continue;
          }

          fareMinor += r['fare_minor'] as int;
          currencyCode ??= (r['currency'] as String).trim();
          operatorId ??= r['operator_id'] as String;
        }

        if (taken.isNotEmpty) return SeatsTaken(taken..sort());

        // ── Claim ────────────────────────────────────────────────────────────
        // ON CONFLICT rather than a caught exception, and the difference is not
        // stylistic. A unique violation *aborts* the transaction: every
        // statement after it fails, including the COMMIT, so everything done
        // above would be thrown away and the claim lost. `DO NOTHING` keeps the
        // transaction healthy and turns the collision into an empty result set,
        // which is a fact we can act on.
        //
        // Empty here means exactly one thing. The replay lookup above already
        // established that this key is not ours; if the insert also collides,
        // the key belongs to a different traveller.
        final inserted = await tx.execute(
          Sql.named('''
          INSERT INTO holds (operator_id, departure_id, user_id, seat_labels,
                             expires_at, idempotency_key, channel)
          VALUES (@operator, @departure, @user, @labels,
                  now() + make_interval(secs => @ttl), @key, @channel)
          ON CONFLICT (idempotency_key) DO NOTHING
          RETURNING id, expires_at
        '''),
          parameters: {
            'operator': TypedValue(Type.uuid, operatorId),
            'departure': TypedValue(Type.uuid, claim.departureId),
            'user': TypedValue(Type.uuid, claim.userId),
            'labels': TypedValue(Type.textArray, claim.seatLabels),
            'ttl': TypedValue(Type.double, claim.ttl.inSeconds.toDouble()),
            'key': TypedValue(Type.text, claim.idempotencyKey),
            'channel': TypedValue(Type.text, claim.channel),
          },
        );

        if (inserted.isEmpty) return const IdempotencyKeyTaken();

        final row = inserted.first.toColumnMap();
        final holdId = row['id'] as String;
        final expiresAt = (row['expires_at'] as DateTime).toUtc();

        // The seats themselves. Between the read above and here, somebody else
        // may have taken one — the constraint says so, and says it under
        // concurrency, which is the only condition that matters.
        final missed = await SeatOccupancy.takeUnderHold(
          tx,
          departureId: claim.departureId,
          operatorId: operatorId!,
          labels: claim.seatLabels,
          holdId: holdId,
          heldUntil: expiresAt,
        );

        // Thrown, not returned, and that is the point: it takes the hold above
        // down with it. A committed hold over seats we did not get would burn
        // the idempotency key, so the traveller's retry — the normal case on
        // these networks — would be answered with "that key is spent" instead
        // of "somebody was faster". Rolled back, their retry is a fresh claim.
        if (missed.isNotEmpty) throw _SeatsWentFirst(missed);

        return SeatsClaimed(
          holdId: holdId,
          operatorId: operatorId,
          seatLabels: claim.seatLabels,
          fare: Money(
            fareMinor,
            Currency.byCode(currencyCode!) ?? Currency.xaf,
          ),
          expiresAt: expiresAt,
        );
      });
    } on _SeatsWentFirst catch (e) {
      return SeatsTaken(e.labels);
    }
  }

  /// The hold this key already produced, or null.
  ///
  /// RLS scopes this to the caller, which is what makes the failure of this
  /// lookup meaningful: if the key exists and this returns null, the key
  /// belongs to someone else.
  Future<SeatsClaimed?> _findByKey(TxSession tx, String key) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT h.id,
               h.operator_id,
               h.seat_labels,
               h.expires_at,
               h.state::text AS state,
               COALESCE(SUM(s.fare_minor), 0)::bigint AS fare_minor,
               MIN(s.currency) AS currency
          FROM holds h
          LEFT JOIN seats s
            ON s.departure_id = h.departure_id
           AND s.seat_label = ANY(h.seat_labels)
         WHERE h.idempotency_key = @key
         GROUP BY h.id
      '''),
      parameters: {'key': TypedValue(Type.text, key)},
    );

    if (rows.isEmpty) return null;
    final r = rows.first.toColumnMap();

    // A consumed or released hold is not something to hand back as if it were
    // live. The caller falls through and tries again, and the unique index
    // then refuses — which is the correct answer: that attempt is over.
    if (r['state'] != 'active') return null;

    final currency = (r['currency'] as String?)?.trim();

    return SeatsClaimed(
      holdId: r['id'] as String,
      operatorId: r['operator_id'] as String,
      seatLabels: (r['seat_labels'] as List).cast<String>(),
      fare: Money(
        r['fare_minor'] as int,
        (currency == null ? null : Currency.byCode(currency)) ?? Currency.xaf,
      ),
      expiresAt: (r['expires_at'] as DateTime).toUtc(),
      replayed: true,
    );
  }

  /// Whether this departure can be sold at all.
  ///
  /// Checked before the seat rows are touched, so a cancelled coach costs one
  /// index lookup instead of a lock on six seats.
  Future<ClaimOutcome?> _checkDeparture(
    TxSession tx,
    String departureId,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.status::text AS status,
               d.departs_at <= now() AS has_left,
               d.sales_close_at IS NOT NULL AND d.sales_close_at <= now()
                 AS sales_closed,
               -- LEFT, and it matters: the public policy on `operators` only
               -- exposes active ones, so a suspended operator's row is not
               -- missing from the table — it is invisible to this session.
               -- A missing row and a blocked one are the same refusal here,
               -- and an inner join would have made the departure itself look
               -- like it had ceased to exist.
               (o.id IS NULL OR o.sales_blocked_at IS NOT NULL) AS blocked
          FROM departures d
          LEFT JOIN operators o ON o.id = d.operator_id
         WHERE d.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );

    if (rows.isEmpty) {
      return const DepartureNotSellable(DepartureNotSellable.missing);
    }

    final r = rows.first.toColumnMap();
    final status = r['status'] as String;

    if (status == 'cancelled') {
      return const DepartureNotSellable(DepartureNotSellable.cancelled);
    }
    if (status == 'departed' || status == 'arrived') {
      return const DepartureNotSellable(DepartureNotSellable.gone);
    }
    if ((r['has_left'] as bool?) ?? false) {
      return const DepartureNotSellable(DepartureNotSellable.gone);
    }
    // Sales close before departure so the manifest can be printed. A traveller
    // who buys while the coach is pulling out is a traveller the conductor has
    // no record of.
    if ((r['sales_closed'] as bool?) ?? false) {
      return const DepartureNotSellable(DepartureNotSellable.salesClosed);
    }
    // Checked last, and deliberately: an operator whose licence lapsed this
    // morning is still refused, but a traveller looking at a cancelled coach
    // is told it was cancelled rather than told about somebody's paperwork.
    if ((r['blocked'] as bool?) ?? false) {
      return const DepartureNotSellable(DepartureNotSellable.operatorBlocked);
    }

    return null;
  }

  @override
  Future<bool> release({
    required String holdId,
    required String userId,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    // Scoped by RLS to the caller's own holds, so a leaked hold id is not a
    // way to release a stranger's seats. `state = 'active'` makes it
    // idempotent: releasing twice is a no-op rather than an error, because the
    // second tap of a "Cancel" button is not a failure.
    final released = await tx.execute(
      Sql.named('''
        UPDATE holds
           SET state = 'released'
         WHERE id = @id AND state = 'active'
        RETURNING id
      '''),
      parameters: {'id': TypedValue(Type.uuid, holdId)},
    );

    if (released.isEmpty) return false;

    // Scoped to the hold, not to the seats: what this traveller is entitled
    // to let go of is what this hold took, and a seat that has since been
    // rebuilt under another authority is none of their business.
    await SeatOccupancy.releaseHold(tx, holdId);

    return true;
  });

  @override
  Future<int> sweepExpired(DateTime now, {int limit = 500}) =>
      throw UnimplementedError(
        'The sweeper runs in services/worker under platform scope. '
        'claim() already treats a lapsed hold as available, so inventory is '
        'never stranded by this being absent.',
      );
}
