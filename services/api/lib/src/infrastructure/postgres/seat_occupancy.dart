import 'package:postgres/postgres.dart';

/// Who is sitting in which part of which seat — the one place that is written.
///
/// Before ADR-0025 a seat was taken by setting `seats.state`, and eleven
/// places in this codebase did it. That was survivable while "taken" was a
/// scalar. It stopped being survivable the moment a seat could be sold
/// Brazzaville→Dolisie and free Dolisie→Pointe-Noire, because a scalar has one
/// answer and that seat has two.
///
/// So `seats.state` is now derived by trigger from `seat_occupancy`, and every
/// path that used to write the state writes a row here instead. The rules that
/// used to live in eleven WHERE clauses live in two places now: the EXCLUDE
/// constraint, which refuses the overlap under concurrency, and this file,
/// which is the only Dart that names the table.
///
/// Three things are true of every method here:
///
///  1. **The span comes from the departure, never from Dart.** A whole-road
///     sale writes the road the departure was put on sale with, read inside
///     the same statement — so a road edited between the read and the write
///     cannot produce a journey nobody sold.
///  2. **A lapsed hold is cleared before anybody insists.** `claim()` has
///     always treated an expired hold as available rather than waiting for
///     the sweeper, and a stalled worker must not be able to lock inventory
///     any more than it can leak it.
///  3. **Refusal is an empty result, never an exception.** An EXCLUDE
///     violation aborts the transaction and takes every row lock with it;
///     `ON CONFLICT DO NOTHING` turns the collision into a fact the caller can
///     act on, which is the same reason `holds` is written that way.
final class SeatOccupancy {
  const SeatOccupancy._();

  /// Frees whatever the hold was holding.
  ///
  /// Deleted rather than marked, because occupancy is not a history — the
  /// hold, the booking and the audit log are. A row here means somebody is in
  /// that seat right now.
  static Future<void> releaseHold(TxSession tx, String holdId) => tx.execute(
    Sql.named('DELETE FROM seat_occupancy WHERE hold_id = @hold'),
    parameters: {'hold': TypedValue(Type.uuid, holdId)},
    ignoreRows: true,
  );

  /// Frees whatever the booking was occupying, on one departure or on all.
  ///
  /// [departureId] is passed by the paths that move a passenger between
  /// coaches: they take the new seat first and release the old one after, and
  /// a release that was not told which coach to free would undo the take.
  ///
  /// Two ways a booking occupies a seat, and this frees both. A paid one owns
  /// its occupancy outright. One that is still `pending_payment` occupies
  /// under the *hold* it was reserved from — which is what makes it held
  /// rather than sold — so a cancellation that only looked for `booking_id`
  /// would leave an unpaid reservation's seats occupied by a hold nobody will
  /// ever pay for.
  static Future<void> releaseBooking(
    TxSession tx,
    String bookingId, {
    String? departureId,
  }) => tx.execute(
    Sql.named('''
      DELETE FROM seat_occupancy o
       USING bookings b
       WHERE b.id = @booking
         AND (o.booking_id = b.id OR o.hold_id = b.hold_id)
         AND (@departure::uuid IS NULL OR o.departure_id = @departure)
    '''),
    parameters: {
      'booking': TypedValue(Type.uuid, bookingId),
      'departure': TypedValue(Type.uuid, departureId),
    },
    ignoreRows: true,
  );

  /// Clears occupancy whose hold expired, on these seats.
  ///
  /// Called before a take rather than left to the sweeper. See rule 2 above.
  static Future<void> clearLapsed(
    TxSession tx, {
    required String departureId,
    required List<String> labels,
  }) => tx.execute(
    Sql.named('''
      DELETE FROM seat_occupancy
       WHERE departure_id = @departure
         AND seat_label = ANY(@labels)
         AND held_until IS NOT NULL
         AND held_until <= now()
    '''),
    parameters: {
      'departure': TypedValue(Type.uuid, departureId),
      'labels': TypedValue(Type.textArray, labels),
    },
    ignoreRows: true,
  );

  /// Takes the whole road on [labels] under a hold.
  ///
  /// Returns the labels it could NOT take — empty when every one of them is
  /// now this hold's. The caller decides what a refusal means; here it only
  /// ever means somebody else got there first.
  static Future<List<String>> takeUnderHold(
    TxSession tx, {
    required String departureId,
    required String operatorId,
    required List<String> labels,
    required String holdId,
    required DateTime heldUntil,
  }) async {
    await clearLapsed(tx, departureId: departureId, labels: labels);
    return _take(
      tx,
      departureId: departureId,
      operatorId: operatorId,
      labels: labels,
      holdId: holdId,
      bookingId: null,
      heldUntil: heldUntil,
    );
  }

  /// Takes the whole road on [labels] for a booking that is already paid.
  ///
  /// Every path that moves a paid passenger onto another coach — a rescue, a
  /// reschedule, protection, a dispatcher reseating somebody — comes through
  /// here, and comes through it *before* releasing the seat they are leaving.
  static Future<List<String>> takeUnderBooking(
    TxSession tx, {
    required String departureId,
    required String operatorId,
    required List<String> labels,
    required String bookingId,
  }) async {
    await clearLapsed(tx, departureId: departureId, labels: labels);
    return _take(
      tx,
      departureId: departureId,
      operatorId: operatorId,
      labels: labels,
      holdId: null,
      bookingId: bookingId,
      heldUntil: null,
    );
  }

  /// The hold this booking was made from becomes the sale itself.
  ///
  /// The same rows, re-attributed: nothing is released and re-taken, so there
  /// is no instant at which a paid seat is free. Returns how many pieces
  /// changed hands, which is how the capture path finds out that the hold
  /// lapsed underneath it.
  static Future<int> sell(
    TxSession tx, {
    required String holdId,
    required String bookingId,
  }) async {
    final sold = await tx.execute(
      Sql.named('''
        UPDATE seat_occupancy
           SET booking_id = @booking, hold_id = NULL, held_until = NULL
         WHERE hold_id = @hold
        RETURNING seat_label
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'hold': TypedValue(Type.uuid, holdId),
      },
    );
    return sold.length;
  }

  /// Moves a hold's deadline out — the reservation path's four hours.
  ///
  /// The occupancy keeps the hold as its authority rather than taking the
  /// booking's name, and that is the whole design of an unpaid reservation:
  /// the seat is held, not sold, so it cannot board and it cannot be resold.
  static Future<void> holdUntil(
    TxSession tx, {
    required String holdId,
    required Duration payWithin,
  }) => tx.execute(
    Sql.named('''
      UPDATE seat_occupancy
         SET held_until = now() + make_interval(secs => @secs)
       WHERE hold_id = @hold
    '''),
    parameters: {
      'hold': TypedValue(Type.uuid, holdId),
      'secs': TypedValue(Type.double, payWithin.inSeconds.toDouble()),
    },
    ignoreRows: true,
  );

  /// Re-seats occupancy at a new label on the same departure.
  ///
  /// The rescue coach. [span] is the piece of road that was already sold and
  /// is carried across verbatim — a passenger who bought Dolisie→Pointe-Noire
  /// does not acquire the first leg by changing coaches.
  static Future<void> reseat(
    TxSession tx, {
    required String departureId,
    required String seatLabel,
    required String operatorId,
    required String span,
    required String? holdId,
    required String? bookingId,
    required DateTime? heldUntil,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO seat_occupancy (departure_id, seat_label, operator_id, span,
                                  hold_id, booking_id, held_until)
      VALUES (@departure, @label, @operator, @span::int4range,
              @hold, @booking, @until)
    '''),
    parameters: {
      'departure': TypedValue(Type.uuid, departureId),
      'label': TypedValue(Type.text, seatLabel),
      'operator': TypedValue(Type.uuid, operatorId),
      'span': TypedValue(Type.text, span),
      'hold': TypedValue(Type.uuid, holdId),
      'booking': TypedValue(Type.uuid, bookingId),
      'until': TypedValue(Type.timestampTz, heldUntil),
    },
    ignoreRows: true,
  );

  static Future<List<String>> _take(
    TxSession tx, {
    required String departureId,
    required String operatorId,
    required List<String> labels,
    required String? holdId,
    required String? bookingId,
    required DateTime? heldUntil,
  }) async {
    // `d.road_span` in the SELECT, not a range built in Dart: the road a
    // departure was put on sale with is the only span a whole-road sale may
    // claim, and reading it in the same statement leaves no window.
    final taken = await tx.execute(
      Sql.named('''
        INSERT INTO seat_occupancy (departure_id, seat_label, operator_id,
                                    span, hold_id, booking_id, held_until)
        SELECT @departure, label, @operator, d.road_span,
               @hold, @booking, @until
          FROM unnest(@labels::text[]) AS label
          JOIN departures d ON d.id = @departure
         -- Sorted, and it is not cosmetic. Two travellers racing for
         -- {12A, 12B} insert in the same sequence, so one waits on the
         -- other's speculative row instead of both waiting on each other.
         ORDER BY label
        ON CONFLICT DO NOTHING
        RETURNING seat_label
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
        'labels': TypedValue(Type.textArray, labels),
        'hold': TypedValue(Type.uuid, holdId),
        'booking': TypedValue(Type.uuid, bookingId),
        'until': TypedValue(Type.timestampTz, heldUntil),
      },
    );

    final got = {
      for (final row in taken) row.toColumnMap()['seat_label'] as String,
    };
    return [
      for (final label in labels)
        if (!got.contains(label)) label,
    ]..sort();
  }
}
