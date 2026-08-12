import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// Tells the people waiting that a full coach has room again.
///
/// **The one pass here that is a promise rather than tidy-up.** Somebody
/// asked to be told; if this never runs, they are never told, and there is no
/// other path that would have caught it — unlike a lapsed hold, which the
/// claim path already treats as available.
///
/// Runs **after** the hold sweeper, and the order is the whole point: an
/// abandoned checkout is the commonest way a seat comes back, and the seats
/// are not free until that pass has released them. Running first would mean
/// noticing tomorrow what happened tonight.
///
/// It fires **once**. `notified_at` is the entire state machine: stamped in
/// the same statement that queues the message, so a crash between the two is
/// impossible and a second pass finds nothing to do. The alert is not
/// re-armed if the seat goes again — being told twice about the same coach is
/// how a useful message becomes one people mute.
final class SeatAlertPass {
  const SeatAlertPass(this._db);

  final Database _db;

  /// One pass. `limit` bounds the batch rather than the work: a departure
  /// that just had thirty seats released may have thirty people waiting, and
  /// the next run picks up whoever this one did not reach.
  Future<SweepResult> notify({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final fired = await tx.execute(
          Sql.named('''
            WITH ready AS (
              SELECT a.id
                FROM seat_alerts a
                JOIN departures d ON d.id = a.departure_id
               WHERE a.notified_at IS NULL
                 AND a.cancelled_at IS NULL
                 AND d.status <> 'cancelled'
                 AND d.departs_at > now()
                 AND (d.sales_close_at IS NULL OR d.sales_close_at > now())
                 AND (
                       SELECT count(*)
                         FROM seats s
                        WHERE s.departure_id = d.id
                          AND (s.state = 'available'
                               OR (s.state = 'held'
                                   AND s.held_until <= now()))
                     ) >= a.seats_wanted
               ORDER BY a.created_at
               LIMIT @limit
               FOR UPDATE OF a SKIP LOCKED
            ),
            stamped AS (
              UPDATE seat_alerts
                 SET notified_at = now()
               WHERE id IN (SELECT id FROM ready)
              RETURNING id
            )
            INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                                dedupe_key)
            SELECT 'seat_alert', s.id, 'seat.available',
                   jsonb_build_object('alertId', s.id::text),
                   'seat.available:' || s.id::text
              FROM stamped s
            ON CONFLICT (dedupe_key) DO NOTHING
            RETURNING id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return SweepResult(name: 'alerts.notified', affected: fired.length);
      });

  /// Closes alerts that can no longer come true — the coach left, or it was
  /// cancelled, or sales are shut.
  ///
  /// Cancelled rather than notified, because nothing was sent. A row left
  /// waiting forever would keep being examined by every pass, and would
  /// answer "am I still waiting?" with a yes that is no longer possible.
  Future<SweepResult> expire({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final closed = await tx.execute(
          Sql.named('''
            UPDATE seat_alerts a
               SET cancelled_at = now()
              FROM departures d
             WHERE d.id = a.departure_id
               AND a.notified_at IS NULL
               AND a.cancelled_at IS NULL
               AND (d.status = 'cancelled'
                    OR d.departs_at <= now()
                    OR (d.sales_close_at IS NOT NULL
                        AND d.sales_close_at <= now()))
               AND a.id IN (
                     SELECT a2.id
                       FROM seat_alerts a2
                      WHERE a2.notified_at IS NULL
                        AND a2.cancelled_at IS NULL
                      ORDER BY a2.created_at
                      LIMIT @limit
                   )
            RETURNING a.id
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return SweepResult(name: 'alerts.expired', affected: closed.length);
      });
}
