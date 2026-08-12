import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/seat_alerts.dart';
import '../db/database.dart';

/// Waiting for a seat, against Postgres.
///
/// Everything here runs as the traveller. There is no cross-tenant read and
/// no escalation: an alert is a row that belongs to one person, and the
/// policy on the table is what says so — an operator cannot see who is
/// waiting for a seat on their 06:00, because that is a list of people who
/// want to travel and holding it is being able to sell it.
final class PostgresSeatAlerts implements SeatAlerts {
  const PostgresSeatAlerts(this._db);

  final Database _db;

  @override
  Future<Result<SeatAlert, SeatAlertFailure>> watch({
    required String departureId,
    required String userId,
    required int seatsWanted,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    // The coach as a traveller sees it: on sale, not left, and how many seats
    // are actually free right now. A lapsed hold counts as free here for the
    // same reason it does in search — the sweeper is tidy-up, not authority.
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.id,
               COUNT(s.seat_label) FILTER (
                 WHERE s.state = 'available'
                    OR (s.state = 'held' AND s.held_until <= now())
               )::int AS free
          FROM departures d
          LEFT JOIN seats s ON s.departure_id = d.id
         WHERE d.id = @departure
           AND d.status <> 'cancelled'
           AND d.departs_at > now()
           AND (d.sales_close_at IS NULL OR d.sales_close_at > now())
         GROUP BY d.id
      '''),
      parameters: {'departure': TypedValue(Type.uuid, departureId)},
    );

    if (rows.isEmpty) return Err(NotWorthWaitingFor(departureId));

    final free = rows.first.toColumnMap()['free'] as int;
    // Room right now. The honest answer is "go and book it" — an alert here
    // would queue a message about a seat they are looking at.
    if (free >= seatsWanted) return Err(SeatsAreAvailable(free));

    // Asking twice is asking once. `DO NOTHING` on the partial unique index
    // rather than an existence check, because two taps on a bad connection
    // arrive as two transactions and only the index can arbitrate that.
    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
        VALUES (@departure, @user, @seats)
        ON CONFLICT DO NOTHING
        RETURNING id, departure_id, seats_wanted, created_at, notified_at
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'user': TypedValue(Type.uuid, userId),
        'seats': TypedValue(Type.integer, seatsWanted),
      },
    );

    if (inserted.isNotEmpty) return Ok(_alertOf(inserted.first.toColumnMap()));

    // Already waiting. The existing row is the answer — a second alert would
    // be a second message about one seat.
    final existing = await tx.execute(
      Sql.named('''
        SELECT id, departure_id, seats_wanted, created_at, notified_at
          FROM seat_alerts
         WHERE departure_id = @departure AND user_id = @user
           AND notified_at IS NULL AND cancelled_at IS NULL
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'user': TypedValue(Type.uuid, userId),
      },
    );

    if (existing.isEmpty) return Err(NotWorthWaitingFor(departureId));
    return Ok(_alertOf(existing.first.toColumnMap()));
  });

  @override
  Future<void> forget({required String departureId, required String userId}) =>
      _db.transaction(DbScope.traveller(userId), (tx) async {
        await tx.execute(
          Sql.named('''
        UPDATE seat_alerts SET cancelled_at = now()
         WHERE departure_id = @departure AND user_id = @user
           AND notified_at IS NULL AND cancelled_at IS NULL
      '''),
          parameters: {
            'departure': TypedValue(Type.uuid, departureId),
            'user': TypedValue(Type.uuid, userId),
          },
          ignoreRows: true,
        );
      });

  @override
  Future<List<SeatAlert>> waitingFor(String userId) =>
      _db.transaction(DbScope.traveller(userId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT a.id, a.departure_id, a.seats_wanted, a.created_at,
                   a.notified_at
              FROM seat_alerts a
              JOIN departures d ON d.id = a.departure_id
             WHERE a.user_id = @user
               AND a.notified_at IS NULL AND a.cancelled_at IS NULL
               AND d.departs_at > now()
             ORDER BY d.departs_at
          '''),
          parameters: {'user': TypedValue(Type.uuid, userId)},
        );
        return [for (final row in rows) _alertOf(row.toColumnMap())];
      });

  static SeatAlert _alertOf(Map<String, Object?> row) => SeatAlert(
    id: '${row['id']}',
    departureId: '${row['departure_id']}',
    seatsWanted: row['seats_wanted'] as int,
    createdAt: row['created_at'] as DateTime,
    notifiedAt: row['notified_at'] as DateTime?,
  );
}
