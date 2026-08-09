import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import 'adapters/memory_idempotency_store.dart';
import 'application/hold_seats.dart';
import 'application/ports/seat_inventory.dart';
import 'infrastructure/db/database.dart';
import 'infrastructure/memory/memory_seat_inventory.dart';
import 'infrastructure/postgres/postgres_idempotency_store.dart';
import 'infrastructure/postgres/postgres_seat_inventory.dart';
import 'middleware/idempotency.dart';

/// Where the wires meet.
///
/// The one file allowed to know both an interface and its adapter. Everything
/// else takes ports, which is what makes swapping Postgres for a fake — or
/// Airtel for Orange Money later — a change here and nowhere else.
///
/// **No `DATABASE_URL` means fakes.** Deliberate: `dart_frog dev` and
/// `tool/smoke_api.sh` work on a fresh clone with nothing installed, so the
/// first thing a new engineer sees is a running API rather than a stack trace
/// about a socket. The moment the variable is set, every one of these becomes
/// the real thing and the handlers do not notice.
final class Services {
  Services._({
    required this.holdSeats,
    required this.inventory,
    required this.idempotency,
    required this.clock,
    required this.usingDatabase,
    Database? database,
  }) : _database = database;

  final HoldSeats holdSeats;
  final SeatInventory inventory;
  final Idempotency idempotency;
  final Clock clock;

  /// False when the API is running on fakes. Reported by `/health`, because
  /// "the tests passed" and "the tests passed against a database" are
  /// different claims and confusing them wastes an afternoon.
  final bool usingDatabase;

  final Database? _database;

  factory Services.resolve({
    Map<String, String>? environment,
    Clock clock = const SystemClock(),
  }) {
    final env = environment ?? Platform.environment;
    final url = env['DATABASE_URL'];

    if (url == null || url.isEmpty) return Services.inMemory(clock: clock);

    final db = Database.open(url);
    final inventory = PostgresSeatInventory(db);

    return Services._(
      holdSeats: HoldSeats(inventory: inventory),
      inventory: inventory,
      // Scoped per request in the handler; this instance carries the anonymous
      // scope so a key written outside a signed-in request cannot masquerade
      // as one.
      idempotency: Idempotency(
        PostgresIdempotencyStore(db, scope: const DbScope.anonymous()),
      ),
      clock: clock,
      usingDatabase: true,
      database: db,
    );
  }

  /// Fakes, with one coach already on sale so the API answers something useful
  /// on a fresh clone.
  factory Services.inMemory({
    Clock clock = const SystemClock(),
    List<MemoryDeparture>? departures,
  }) {
    final inventory = MemorySeatInventory(
      clock: clock,
      departures:
          departures ??
          [
            MemoryDeparture.coach(
              id: 'dep-demo-0001',
              operatorId: 'op-demo',
              departsAt: clock.now().add(const Duration(days: 1)),
            ),
          ],
    );

    return Services._(
      holdSeats: HoldSeats(inventory: inventory),
      inventory: inventory,
      idempotency: Idempotency(MemoryIdempotencyStore()),
      clock: clock,
      usingDatabase: false,
    );
  }

  /// Idempotency scoped to one traveller, so two travellers cannot see or
  /// clobber each other's keys.
  Idempotency idempotencyFor(String? userId) {
    final db = _database;
    if (db == null) return idempotency;
    return Idempotency(
      PostgresIdempotencyStore(
        db,
        scope: userId == null || userId.isEmpty
            ? const DbScope.anonymous()
            : DbScope.traveller(userId),
      ),
    );
  }

  Future<void> close() async => _database?.close();
}
