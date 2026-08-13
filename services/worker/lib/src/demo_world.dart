import 'dart:io';

import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_applications.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_protection.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// A world to walk through, and one command to take it away again.
///
///   dart run services/worker/bin/seed_demo.dart
///   dart run services/worker/bin/seed_demo.dart --purge
///
/// **Why this exists.** Several paths in this product cannot be demonstrated
/// without data that only arrives over months: an operator whose insurance is
/// three weeks from lapsing, an application small enough to approve itself, a
/// second company on the same road to hand passengers to. Waiting for real
/// operators to produce those states means the code is written and never once
/// seen working end to end.
///
/// **Built through the real adapters, not by fabricating rows.** The wizard
/// starts the applications, the platform console approves them, the operator
/// console draws the layouts and the roads and materialises the departures.
/// A seed that INSERTed its way to a finished world would prove that INSERT
/// works. This one fails if the product does.
///
/// **Everything it writes is marked, and the mark is the delete path.**
/// Operators carry a `DEMO-` code and people a `@demo.billetenligne.cg`
/// address; `--purge` removes exactly those and nothing else, so the day this
/// deployment carries a real operator, taking the demo world out is one
/// command rather than an afternoon with a psql prompt. The demo numbers are
/// in `+242 0690…` and that is **not** part of the mark: `0690` is a real
/// allocation, so a phone prefix cannot be reserved and a purge keyed to one
/// would eventually delete somebody who exists. Shared reference data — the
/// city catalogue — is deliberately left behind: two operators serving
/// Pointe-Noire must mean the same Pointe-Noire, and it belongs to nobody.
///
/// Needs `SEED_DATABASE_URL` as well as `DATABASE_URL`: creating people and
/// appointing platform staff are things no running surface may do (migration
/// 0012), and a seeder that could would make every other control decorative.
const demoCodePrefix = 'DEMO-';
const demoEmailDomain = 'demo.billetenligne.cg';
const demoPhonePrefix = '+2420690';

final class DemoWorld {
  DemoWorld({required Database db, required Connection seed})
    : _db = db,
      _seed = seed,
      _applications = PostgresOperatorApplications(db),
      _platform = PostgresPlatformConsole(db),
      _console = PostgresOperatorConsole(db, timeZone: 'Africa/Brazzaville'),
      _protection = PostgresProtection(db);

  final Database _db;
  final Connection _seed;
  final PostgresOperatorApplications _applications;
  final PostgresPlatformConsole _platform;
  final PostgresOperatorConsole _console;
  final PostgresProtection _protection;

  /// Removes the demo world.
  ///
  /// **This is the method that matters.** Seeded data whose removal is
  /// untested is seeded data still sitting in production a year from now,
  /// under a name nobody recognises, with a real ticket sold against it.
  ///
  /// The order is not hand-written, and deliberately not. Most tenant tables
  /// cascade from `operators`, but the ones that hold money — bookings,
  /// tickets, ledger entries, payouts, the audit log — are RESTRICT on
  /// purpose, because money must never disappear because a parent row did.
  /// A hand-written list of those would be correct today and quietly wrong
  /// the first time a migration adds a table, which is exactly the failure
  /// this whole slice exists to prevent. So [_cut] reads the foreign keys out
  /// of the catalogue and walks them, and a table added next year is removed
  /// without anybody remembering to come back here.
  ///
  /// **The append-only guarantee is suspended, not broken.** Three tables
  /// refuse UPDATE and DELETE by grant *and* by trigger (0004), and the
  /// trigger fires for the table's owner too — which is correct, and is the
  /// reason unmaking a world has to be a deliberate act rather than a DELETE.
  /// The suspension here is the narrowest one available: `DISABLE TRIGGER`
  /// takes an ACCESS EXCLUSIVE lock, so no other session can write an audit
  /// row while it is off, and DDL in Postgres is transactional, so a purge
  /// that fails halfway rolls the trigger back on along with everything else.
  /// The guarantee is unavailable for the length of one transaction on one
  /// connection; it is never weakened for anybody.
  ///
  /// That this needs a superuser connection at all is the right shape rather
  /// than an inconvenience: creating people and appointing platform staff are
  /// writes no surface holds a grant for (0012), and unmaking a world is not
  /// an operation the product should be able to perform.
  Future<int> purge() => _seed.runTx((tx) async {
    final operators = await _ids(
      tx,
      'SELECT id::text FROM operators WHERE code LIKE @p',
      {'p': '$demoCodePrefix%'},
    );
    // Matched on the address alone, and never on the number: `0690…` is a
    // real Congolese allocation, so a phone prefix cannot be reserved and a
    // purge keyed to one would eventually delete a person who exists. The
    // domain is ours, every demo persona has an address in it, and that makes
    // the mark both complete and unambiguous.
    final people = await _ids(
      tx,
      'SELECT id::text FROM user_accounts WHERE email LIKE @email',
      {'email': '%@$demoEmailDomain'},
    );

    if (operators.isEmpty && people.isEmpty) return 0;

    for (final table in _appendOnly) {
      await tx.execute(
        'ALTER TABLE $table DISABLE TRIGGER ${table}_append_only',
      );
    }

    // Operators first: an application holds its applicant with ON DELETE
    // RESTRICT, so the people cannot go until the companies have.
    await _cut(tx, 'operators', ids: operators);
    await _cut(tx, 'user_accounts', ids: people);

    // The outbox holds no foreign key to anything, and deliberately: a
    // message has to be able to outlive the row it describes long enough to
    // be sent (ADR-0019). The walker therefore cannot see it, so it is named
    // here — and this is the one place a new table could hide, which is why
    // the integration suite counts leftovers rather than trusting the walk.
    await tx.execute(
      Sql.named('DELETE FROM outbox WHERE aggregate_id::text = ANY(@ids)'),
      parameters: {
        'ids': TypedValue(Type.textArray, [...operators, ...people]),
      },
      ignoreRows: true,
    );

    for (final table in _appendOnly) {
      await tx.execute(
        'ALTER TABLE $table ENABLE TRIGGER ${table}_append_only',
      );
    }

    return operators.length;
  });

  /// The three tables 0004 makes append-only by trigger as well as by grant.
  static const _appendOnly = ['audit_log', 'ledger_entries', 'payment_events'];

  Future<List<String>> _ids(
    Session session,
    String sql,
    Map<String, Object?> parameters,
  ) async {
    final rows = await session.execute(Sql.named(sql), parameters: parameters);
    return [for (final row in rows) row[0]! as String];
  }

  /// Deletes [ids] from [table], taking everything that points at them first.
  ///
  /// Only RESTRICT and NO ACTION references are walked: CASCADE and SET NULL
  /// already say what should happen, and the database does it better than a
  /// second implementation of it would.
  ///
  /// Ids travel as text and are compared as text, so one routine serves a
  /// UUID primary key, a bigserial one and a code column alike. A purge is
  /// not a hot path, and the index scan saved here would cost a third variant
  /// of this method.
  Future<void> _cut(
    Session session,
    String table, {
    required List<String> ids,
    Set<String> visiting = const {},
  }) async {
    if (ids.isEmpty || visiting.contains(table)) return;

    final references = await session.execute(
      Sql.named(r'''
        SELECT child.relname AS child_table, att.attname AS child_column
          FROM pg_constraint c
          JOIN pg_class child ON child.oid = c.conrelid
          JOIN pg_class parent ON parent.oid = c.confrelid
          JOIN pg_namespace n ON n.oid = child.relnamespace
          JOIN unnest(c.conkey) AS k(attnum) ON true
          JOIN pg_attribute att
            ON att.attrelid = c.conrelid AND att.attnum = k.attnum
         WHERE c.contype = 'f'
           AND n.nspname = 'public'
           AND parent.relname = @table
           AND c.confdeltype IN ('a', 'r')
      '''),
      parameters: {'table': TypedValue(Type.text, table)},
    );

    for (final reference in references) {
      final row = reference.toColumnMap();
      final childTable = row['child_table'] as String;
      final childColumn = row['child_column'] as String;
      final childKey = await _primaryKeyOf(session, childTable);

      if (childKey != null) {
        await _cut(
          session,
          childTable,
          ids: await _ids(
            session,
            'SELECT $childKey::text FROM $childTable '
            'WHERE $childColumn::text = ANY(@ids)',
            {'ids': TypedValue(Type.textArray, ids)},
          ),
          visiting: {...visiting, table},
        );
      }

      await session.execute(
        Sql.named(
          'DELETE FROM $childTable WHERE $childColumn::text = ANY(@ids)',
        ),
        parameters: {'ids': TypedValue(Type.textArray, ids)},
        ignoreRows: true,
      );
    }

    final key = await _primaryKeyOf(session, table) ?? 'id';
    await session.execute(
      Sql.named('DELETE FROM $table WHERE $key::text = ANY(@ids)'),
      parameters: {'ids': TypedValue(Type.textArray, ids)},
      ignoreRows: true,
    );
  }

  /// Null for a composite key: those tables are reached through their parent,
  /// so there is nothing to recurse on and the delete above is enough.
  Future<String?> _primaryKeyOf(Session session, String table) async {
    final rows = await session.execute(
      Sql.named(r'''
        SELECT att.attname
          FROM pg_index i
          JOIN pg_attribute att
            ON att.attrelid = i.indrelid AND att.attnum = ANY(i.indkey)
         WHERE i.indrelid = @table::regclass AND i.indisprimary
      '''),
      parameters: {'table': TypedValue(Type.text, table)},
    );
    return rows.length == 1 ? rows.first[0] as String : null;
  }

  Future<void> seed() async {
    await _cities();
    final reviewer = await _staff('operations', 'operations');
    await _staff('super_admin', 'direction');

    // Two companies actually selling, on the same road. The second is not
    // decoration: a protection agreement, a rescue coach and an open call for
    // room all need somebody on the other end, and a demo world with one
    // operator cannot show any of them.
    //
    // The names are invented rather than borrowed. Real Congolese operators
    // exist and a demo world wearing one of their names is a screenshot that
    // says something untrue about a company that never agreed to be in it.
    final alizes = await _company(
      code: 'ALZ',
      legalName: 'Alizés Transport SARL',
      tradingName: 'Alizés',
      owner: 'angele',
      ownerName: 'Angèle Mbemba',
      reviewer: reviewer,
      fleet: 14,
    );
    final kouilou = await _company(
      code: 'KLV',
      legalName: 'Kouilou Voyages SARL',
      tradingName: 'Kouilou Voyages',
      owner: 'prosper',
      ownerName: 'Prosper Loubaki',
      reviewer: reviewer,
      fleet: 9,
    );

    await _network(alizes, code: 'ALZ', hour: '06:00', fare: 12000);
    await _network(kouilou, code: 'KLV', hour: '07:30', fare: 11000);

    // Both in the open-protection channel (`08-disruption.md` §5), so a call
    // put out from either console has somebody on the other end of it. Opting
    // in is the one decision here that no amount of waiting produces: a
    // channel with one member is a channel that looks broken.
    //
    // Through the desk rather than by setting the column, so the audit trail
    // says a person joined on a date — which is the question a dispute about
    // a rebill actually asks.
    for (final (operator, owner) in [
      (alizes, 'angele'),
      (kouilou, 'prosper'),
    ]) {
      await _protection.receiveOpenCalls(
        operatorId: operator,
        receiving: true,
        actorUserId: await _userIdOf(owner),
      );
    }

    // Paperwork in three states, because the expiry ladder is only visible
    // when something is actually approaching a date (03-operator-lifecycle.md
    // §3.3): one company entirely in order, one three weeks out so the console
    // carries the banner, and one already lapsed so Conformité has a red row
    // and the compliance pass has something to stop selling.
    //
    // The lapsed one is deliberately a *third* company rather than either of
    // the two selling — blocking a company the demo shops from would empty
    // the search results, which reads as a broken build rather than as the
    // rule working.
    //
    // These dates do not match the ones on the applications, and should not:
    // a company submits a certificate that is valid and the certificate
    // lapses later. `submit` refuses an already-expired insurance (§2.2), so
    // a lapsed operator can only ever be one that lapsed after approval.
    await _documents(alizes, licence: 900, insurance: 700);
    await _documents(kouilou, licence: 400, insurance: 20);

    final lapsed = await _company(
      code: 'LKN',
      legalName: 'Cars Lékana SARL',
      tradingName: 'Cars Lékana',
      owner: 'mireille',
      ownerName: 'Mireille Nzaba',
      reviewer: reviewer,
      fleet: 4,
    );
    await _documents(lapsed, licence: 300, insurance: -3);

    // The application the auto-review pass will approve on its next run:
    // small, complete, and named so `DemoApplicantScreening` clears it.
    // Left submitted rather than approved here, because "the pass did it" is
    // the thing worth being able to watch.
    await _applicant(
      legalName: 'Niari Express SARL',
      owner: 'serge',
      ownerName: 'Serge Loubaki',
      fleet: 3,
      dailyDepartures: 4,
    );

    // And one the pass will sort to `elevated` and leave alone: the same
    // legal name as a company already here. A queue with nothing in it proves
    // nothing about a queue.
    await _applicant(
      legalName: 'Alizés Transport SARL',
      owner: 'clone',
      ownerName: 'Inconnu Mabiala',
      fleet: 2,
      dailyDepartures: 2,
    );

    // People on the coaches. Tomorrow's 06:00 to Pointe-Noire is the one that
    // carries a load worth breaking down: enough passengers that a rescue
    // coach is a decision rather than an arithmetic exercise, and few enough
    // that a manifest fits on a screen. The day after is thinner, so a
    // dispatcher looking at both can tell which is which.
    final onBoard =
        await _sell(alizes, code: 'ALZ', inDays: 1, seats: 12) +
        await _sell(alizes, code: 'ALZ', inDays: 2, seats: 3) +
        await _sell(kouilou, code: 'KLV', inDays: 1, seats: 5);

    // Somebody to buy a ticket as. The Auth emulator accepts 123456 for any
    // number, so this account is signed into without a handset.
    await _person('voyageur', 'Chancelvie Okemba', phone: '00001');

    stdout
      ..writeln('── demo world seeded')
      ..writeln('   3 operators selling · 1 of them with lapsed paperwork')
      ..writeln('   2 of them in the open-protection channel')
      ..writeln(
        '   $onBoard passengers on tomorrow\'s coaches, paid at the guichet',
      )
      ..writeln('   2 applications waiting for the onboarding pass')
      ..writeln(
        '   people: *@$demoEmailDomain, traveller ${demoPhonePrefix}00001',
      )
      ..writeln(
        '   remove with: dart run services/worker/bin/seed_demo.dart --purge',
      );
  }

  /// Shared reference data, and **not** demo-owned: `--purge` leaves it. Two
  /// operators serving Pointe-Noire must mean the same Pointe-Noire.
  Future<void> _cities() => _seed.execute('''
    INSERT INTO cities (code, market_code, name_fr, name_en) VALUES
      ('BZV', 'CG', 'Brazzaville', 'Brazzaville'),
      ('PNR', 'CG', 'Pointe-Noire', 'Pointe-Noire'),
      ('DOL', 'CG', 'Dolisie', 'Dolisie'),
      ('OYO', 'CG', 'Oyo', 'Oyo')
    ON CONFLICT (code) DO NOTHING
  ''', ignoreRows: true);

  Future<String> _person(
    String handle,
    String fullName, {
    String? phone,
  }) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO user_accounts (email, phone_e164, full_name, language)
        VALUES (@email, @phone, @name, 'fr')
        ON CONFLICT (lower(email)) WHERE email IS NOT NULL
        DO UPDATE SET full_name = EXCLUDED.full_name
        RETURNING id
      '''),
      parameters: {
        'email': '$handle@$demoEmailDomain',
        'phone': phone == null ? null : '$demoPhonePrefix$phone',
        'name': fullName,
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  /// The id behind a demo handle. Read rather than re-created: [_person]
  /// upserts a name as well, and calling it for an id alone would rewrite one.
  Future<String> _userIdOf(String handle) async {
    final rows = await _seed.execute(
      Sql.named('SELECT id FROM user_accounts WHERE email = @email'),
      parameters: {'email': '$handle@$demoEmailDomain'},
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  Future<String> _staff(String role, String handle) async {
    final userId = await _person(handle, 'BEL — $handle');
    await _seed.execute(
      Sql.named('''
        INSERT INTO platform_staff (user_id, role) VALUES (@user, @role)
        ON CONFLICT (user_id) DO UPDATE SET role = EXCLUDED.role,
                                            revoked_at = NULL
      '''),
      parameters: {
        'user': TypedValue(Type.uuid, userId),
        'role': TypedValue(Type.text, role),
      },
      ignoreRows: true,
    );
    return userId;
  }

  /// An application, through the wizard, submitted and left in the queue.
  Future<String> _applicant({
    required String legalName,
    required String owner,
    required String ownerName,
    required int fleet,
    required int dailyDepartures,
    String? tradingName,
    String? code,
  }) async {
    final userId = await _person(owner, ownerName);

    final started = ok(
      await _applications.start(
        userId: userId,
        legalName: legalName,
        marketCode: 'CG',
      ),
      'start $legalName',
    );
    final operatorId = started.operatorId;

    // The mark, stamped over the code the wizard derived from the name. It is
    // what `--purge` finds and what `DemoApplicantScreening` clears, and it is
    // written here rather than passed into the wizard because a real
    // applicant has no say in their own code either.
    await _mark(operatorId, code ?? owner);

    ok(
      await _applications.save(
        userId: userId,
        facts: ApplicationFacts(
          legalName: legalName,
          tradingName: tradingName ?? legalName.split(' ').take(2).join(' '),
          rccmNumber: 'CG-BZV-01-2019-B12-${_digits(owner)}',
          taxId: 'M20191100${_digits(owner)}',
          legalForm: 'sarl',
          registeredAddress: '12 avenue de la Paix, Brazzaville',
          yearFounded: 2019,
          ownerName: ownerName,
          ownerIdType: 'passport',
          ownerIdNumber: '19CD${_digits(owner)}',
          ownerPhone: '$demoPhonePrefix${_digits(owner)}',
          ownerEmail: '$owner@$demoEmailDomain',
          transportLicenceNumber: 'TR-2025-${_digits(owner)}',
          transportLicenceExpires: _inDays(900),
          insurerName: 'NSIA Congo',
          fleetInsuranceExpires: _inDays(700),
          routesServed: 'Brazzaville — Pointe-Noire',
          fleetSize: fleet,
          stationCount: 1,
          dailyDepartures: dailyDepartures,
          settlementKind: 'momo',
          // Must match the legal name (§2.2 step 5), or the risk pass sorts it
          // to a person for a reason the demo did not intend to show.
          settlementAccountName: legalName,
          settlementAccountRef: '$demoPhonePrefix${_digits(owner)}',
          agreementAccepted: true,
        ),
      ),
      'save $legalName',
    );

    ok(
      await _applications.submit(userId: userId, asOf: DateTime.now().toUtc()),
      'submit $legalName',
    );
    return operatorId;
  }

  /// An operator selling: applied for, reviewed and activated, exactly as one
  /// arrives in production.
  Future<String> _company({
    required String code,
    required String legalName,
    required String tradingName,
    required String owner,
    required String ownerName,
    required String reviewer,
    required int fleet,
  }) async {
    final operatorId = await _applicant(
      legalName: legalName,
      tradingName: tradingName,
      owner: owner,
      ownerName: ownerName,
      fleet: fleet,
      dailyDepartures: 8,
      code: code,
    );

    // Through the console the `operations` role uses, so the audit trail this
    // world carries is a real trail rather than a fabricated one.
    await _platform.decide(
      operatorId: operatorId,
      decision: OperatorDecision.approve,
      actorUserId: reviewer,
      reason: 'dossier complet, RCCM verifie',
    );
    await _platform.decide(
      operatorId: operatorId,
      decision: OperatorDecision.activate,
      actorUserId: reviewer,
      reason: 'mise en service',
    );

    return operatorId;
  }

  /// A road, a coach and a fortnight of departures on it.
  Future<void> _network(
    String operatorId, {
    required String code,
    required String hour,
    required int fare,
  }) async {
    final layout = await _console.saveLayout(
      operatorId: operatorId,
      name: 'Car 2+2 (49)',
      layout: SeatLayout.busStandard49(),
    );

    final vehicle = must(
      await _console.saveVehicle(
        operatorId: operatorId,
        registration: '$code-001-CG',
        layoutId: layout.id,
        nickname: 'Car 1',
        amenities: const ['air_conditioning', 'usb'],
      ),
      'vehicle $code-001-CG',
    );

    final station = must(
      await _console.saveStation(
        operatorId: operatorId,
        cityCode: 'BZV',
        name: 'Gare routière de Mikalou',
        boardingNotes: 'Portail bleu, en face de la station-service.',
      ),
      'station Mikalou',
    );

    for (final road in const [('PNR', 450), ('DOL', 300)]) {
      final route = must(
        await _console.saveRoute(
          operatorId: operatorId,
          code: 'BZV-${road.$1}',
          originCity: 'BZV',
          destinationCity: road.$1,
          durationMinutes: road.$2,
        ),
        'route BZV-${road.$1}',
      );

      final pattern = must(
        await _console.savePattern(
          operatorId: operatorId,
          routeId: route.id,
          recurrence: Recurrence.daily(),
          departureTime: hour,
          fare: Money.xaf(road.$1 == 'PNR' ? fare : fare - 3000),
          validFrom: _inDays(0),
          vehicleId: vehicle.id,
          originStationId: station.id,
        ),
        'pattern BZV-${road.$1}',
      );

      // A fortnight, which is enough for a traveller to search any ordinary
      // date and for the horizon pass to have something to extend.
      await _console.materialise(
        operatorId: operatorId,
        patternId: pattern.id,
        from: _inDays(0),
        to: _inDays(14),
      );
    }
  }

  /// The two dated pieces §3.3 enforces against. Negative days are a document
  /// that has already lapsed.
  Future<void> _documents(
    String operatorId, {
    required int licence,
    required int insurance,
  }) => _seed.execute(
    Sql.named('''
      INSERT INTO kyb_documents (operator_id, doc_type, storage_key,
                                 expires_at, verified_at)
      VALUES
        (@id, 'transport_licence', 'demo/licence.pdf',
         now() + make_interval(days => @licence), now()),
        (@id, 'fleet_insurance', 'demo/insurance.pdf',
         now() + make_interval(days => @insurance), now())
    '''),
    parameters: {
      'id': TypedValue(Type.uuid, operatorId),
      'licence': TypedValue(Type.integer, licence),
      'insurance': TypedValue(Type.integer, insurance),
    },
    ignoreRows: true,
  );

  /// Passengers on a coach, sold over the counter.
  ///
  /// **Without this the demo world has roads and no people on them**, and
  /// most of what this product does only exists once somebody has paid: a
  /// disruption has nobody to tell, a rescue coach has nobody to move, an
  /// open call for room is refused because a call for an empty departure is
  /// not a call. A world you can look at is not the same as a world you can
  /// break.
  ///
  /// Cash at the guichet rather than a mobile-money rail, and that is the
  /// only choice here that needed making: a rail sale would have to be
  /// authorised by a handset nobody is holding, whereas a counter sale is one
  /// transaction the operator console genuinely performs — hold, reserve,
  /// take the money, post the ledger, issue the tickets, queue the message.
  /// It goes through `HoldSeats` and `ReserveBooking` for the same reason
  /// everything else here does: a seed that INSERTed a booking would prove
  /// that INSERT works, and would quietly skip the ledger the payout run
  /// later reads.
  Future<int> _sell(
    String operatorId, {
    required String code,
    required int inDays,
    required int seats,
  }) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT d.id::text AS id, d.origin_station_id::text AS station
          FROM departures d
          JOIN routes r ON r.id = d.route_id
         WHERE d.operator_id = @op
           AND r.destination_city = 'PNR'
           AND d.departs_at::date = (now() + make_interval(days => @days))::date
         ORDER BY d.departs_at
         LIMIT 1
      '''),
      parameters: {
        'op': TypedValue(Type.uuid, operatorId),
        'days': TypedValue(Type.integer, inDays),
      },
    );
    if (rows.isEmpty) return 0;
    final departureId = rows.first.toColumnMap()['id'] as String;
    final stationId = rows.first.toColumnMap()['station'] as String;

    // The development signer, whose seed is fixed (ADR-0020), so a ticket in
    // yesterday's screenshot still scans today.
    final bookings = PostgresBookingStore(
      _db,
      issuer: await Ed25519TicketIssuer.development(),
    );
    final holds = HoldSeats(inventory: PostgresSeatInventory(_db));
    final reserve = ReserveBooking(bookings: bookings);

    final free = await _seed.execute(
      Sql.named('''
        SELECT seat_label FROM seats
         WHERE departure_id = @id AND state = 'available'
         ORDER BY seat_label
         LIMIT @n
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'n': TypedValue(Type.integer, seats),
      },
    );

    var sold = 0;
    for (final (index, row) in free.indexed) {
      final label = row.toColumnMap()['seat_label'] as String;
      final who = _passengers[index % _passengers.length];
      // A handle per seat, so re-seeding produces the same people and the
      // purge finds every one of them by the address it already looks for.
      final handle = '${code.toLowerCase()}-p${index + 1}';
      final userId = await _person(handle, who, phone: '${_digits(handle)}');

      final held = await holds(
        departureId: departureId,
        seatLabels: [label],
        userId: userId,
        idempotencyKey: 'demo:$handle:$departureId',
        channel: 'agency',
      );
      if (held case Err()) continue;

      final booked = await reserve(
        holdId: held.valueOrNull!.id,
        userId: userId,
        passengers: [PassengerDto(fullName: who, seatLabel: label)],
        channel: 'agency',
      );
      if (booked case Err()) continue;

      final booking = booked.valueOrNull!;
      final posting = Postings.cashSale(
        operatorId: booking.operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      );
      if (posting case Err()) continue;

      final paid = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: stationId,
        // Nobody: the demo has no vendor account, and inventing one would put
        // a name on a till reading that never sat at it.
        soldByUserId: null,
        posting: posting.valueOrNull!,
      );
      if (paid != null) sold++;
    }
    return sold;
  }

  /// Names for the seats. Ordinary Congolese names, invented, and reused
  /// across coaches on purpose — a manifest of forty distinct strangers is
  /// harder to read at a glance than one with people you start to recognise.
  static const _passengers = [
    'Chancelvie Okemba',
    'Rodrigue Bakala',
    'Fideline Ngoma',
    'Bertrand Mavoungou',
    'Clarisse Itoua',
    'Juste Bouiti',
    'Ornella Massamba',
    'Landry Ondongo',
  ];

  Future<void> _mark(String operatorId, String suffix) => _seed.execute(
    Sql.named('UPDATE operators SET code = @code WHERE id = @id'),
    parameters: {
      'id': TypedValue(Type.uuid, operatorId),
      'code': TypedValue(Type.text, '$demoCodePrefix${suffix.toUpperCase()}'),
    },
    ignoreRows: true,
  );

  static DateTime _inDays(int days) {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day).add(Duration(days: days));
  }

  /// A stable five digits per persona, so re-seeding produces the same
  /// registration numbers and a screenshot taken last week still matches.
  ///
  /// Five, because they are also the tail of a phone number: Congo-Brazzaville
  /// national numbers are nine digits and `0690` takes four of them.
  static String _digits(String handle) {
    var hash = 0;
    for (final unit in handle.codeUnits) {
      hash = (hash * 31 + unit) % 100000;
    }
    return hash.toString().padLeft(5, '0');
  }
}

/// A superuser connection.
///
/// Creating people and appointing platform staff are writes no running
/// surface holds a grant for (0012), and a seeder that could perform them
/// through `bel_api` would make every other control decorative.
Future<Connection> openSeedConnection(String url) async {
  final uri = Uri.parse(url);
  final auth = uri.userInfo.split(':');
  return Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.port,
      database: uri.pathSegments.first,
      username: auth.first,
      password: auth.length > 1 ? auth[1] : null,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );
}

/// A seed that half-worked is worse than one that stopped: the world it leaves
/// looks finished and is not. Both helpers turn a refusal into a message that
/// names the step, rather than a null dereference two lines later.
T ok<T, F>(Result<T, F> result, String step) {
  final value = result.valueOrNull;
  if (value == null) {
    throw StateError('$step refused: ${result.failureOrNull}');
  }
  return value;
}

T must<T>(T? value, String step) {
  if (value == null) throw StateError('$step came back empty');
  return value;
}
