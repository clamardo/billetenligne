@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/departure_catalogue.dart';
import 'package:bel_api/src/application/ports/seat_inventory.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_compliance_desk.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_departure_catalogue.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The expiry ladder, read and enforced against the real schema
/// (`03-operator-lifecycle.md` §3.3).
///
/// Three claims a fake cannot make:
///
///   * the standing an operator reads and the standing our compliance screen
///     reads come out of **one object over one table**, so the date on the
///     banner is the date we acted on;
///   * a blocked operator **disappears from search** rather than selling a
///     seat and refusing it at checkout;
///   * the refusal at checkout is **the sale, not the departure** — the coach
///     still exists, the tickets already sold are untouched.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresComplianceDesk desk;
  late PostgresDepartureCatalogue catalogue;
  late PostgresSeatInventory inventory;
  late String reviewer;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    desk = PostgresComplianceDesk(db);
    catalogue = PostgresDepartureCatalogue(
      db,
      timeZone: Market.current.timeZone,
    );
    inventory = PostgresSeatInventory(db);
    reviewer = await fixture.platformStaff('operations', suffix: 'compl');
  });

  tearDownAll(() async {
    // The fixture operator is shared with every other suite in this run. A
    // block left behind here would look like a bug in somebody else's file.
    await fixture.blockSales(PgFixture.operatorId);
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String docType() => 'insurance_${++seq}';

  group('what the operator reads', () {
    test('an operator with nothing dated is not thereby in trouble', () async {
      final id = await fixture.applicant(
        code: 'CMP${DateTime.now().microsecondsSinceEpoch % 100000}',
        legalName: 'Sans papiers datés',
        status: 'active',
      );

      final standing = await desk.standing(id);

      expect(standing.stage, 'clear');
      expect(standing.salesBlocked, isFalse);
      expect(standing.documents, isEmpty);
    });

    test(
      'a certificate three weeks out is a warning, and says which',
      () async {
        final type = docType();
        await fixture.kybDocument(
          operatorId: PgFixture.operatorId,
          docType: type,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 21)),
        );

        final standing = await desk.standing(PgFixture.operatorId);
        final mine = standing.documents.firstWhere((d) => d.docType == type);

        expect(mine.stage, 'warned');
        expect(mine.daysLeft, 20);
      },
    );

    test('an unverified upload is a claim, not a licence', () async {
      final type = docType();
      await fixture.kybDocument(
        operatorId: PgFixture.operatorId,
        docType: type,
        expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
        verified: false,
      );

      final standing = await desk.standing(PgFixture.operatorId);

      expect(
        standing.documents.map((d) => d.docType),
        isNot(contains(type)),
        reason: 'nobody has looked at it, so it cannot block anybody',
      );
    });

    test('last year\'s lapsed copy is history, not a block', () async {
      final type = docType();
      await fixture.kybDocument(
        operatorId: PgFixture.operatorId,
        docType: type,
        expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 400)),
      );
      await fixture.kybDocument(
        operatorId: PgFixture.operatorId,
        docType: type,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 300)),
      );

      final standing = await desk.standing(PgFixture.operatorId);
      final mine = standing.documents.where((d) => d.docType == type);

      expect(mine, hasLength(1));
      expect(mine.single.stage, 'clear');
    });
  });

  group('what we read', () {
    test(
      'the calendar carries the operator\'s name and the worst first',
      () async {
        final type = docType();
        await fixture.kybDocument(
          operatorId: PgFixture.operatorId,
          docType: type,
          expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
        );

        final calendar = await desk.calendar(actorUserId: reviewer);
        final mine = calendar.firstWhere(
          (c) => c.operatorId == PgFixture.operatorId,
        );

        expect(mine.operatorName, isNotNull);
        expect(mine.stage, 'blocked');
        // Already lapsed and still listed: a calendar that only looked forward
        // would drop an operator off the screen at the moment they became the
        // reason for a phone call.
        expect(mine.documents.first.daysLeft, lessThanOrEqualTo(0));
        expect(calendar.first.stage, anyOf('blocked', 'suspended'));
      },
    );

    test('a window of one day hides what is months away', () async {
      final calendar = await desk.calendar(
        actorUserId: reviewer,
        withinDays: 1,
      );

      for (final c in calendar) {
        expect(
          c.documents.map((d) => d.daysLeft),
          anyElement(lessThan(1)),
          reason:
              'an operator is listed for what is close, not for what is '
              'merely dated',
        );
      }
    });

    test('a renewed certificate does not read as a lapsed one', () async {
      // The window matches documents, and the standing is decided per kind
      // over every copy. An operator whose insurance lapsed last year and was
      // renewed for another year matches on the old row — and must not be
      // listed as though the old row were their standing.
      final type = docType();
      final company = await fixture.applicant(
        code: 'RNW${DateTime.now().microsecondsSinceEpoch % 100000}',
        legalName: 'Renouvelé à temps',
        status: 'active',
      );
      await fixture.kybDocument(
        operatorId: company,
        docType: type,
        expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 400)),
      );
      await fixture.kybDocument(
        operatorId: company,
        docType: type,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 300)),
      );

      final calendar = await desk.calendar(actorUserId: reviewer);

      expect(
        calendar.map((c) => c.operatorId),
        isNot(contains(company)),
        reason: 'their paperwork is in order; the lapsed copy is history',
      );
    });
  });

  group('what a block actually costs', () {
    setUp(() => fixture.blockSales(PgFixture.operatorId));

    test('a blocked operator disappears from search', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 9),
      );
      final when = await fixture.localDateIn(const Duration(hours: 9));

      final before = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: when,
        ),
      );
      expect(before.map((d) => d.id), contains(departureId));

      await fixture.blockSales(PgFixture.operatorId, doc: 'fleet_insurance');

      final after = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: when,
        ),
      );

      expect(
        after.map((d) => d.id),
        isNot(contains(departureId)),
        reason: 'a seat we would refuse at checkout must not be advertised',
      );
    });

    test('the seat map still resolves, because the coach still runs', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 10),
      );
      await fixture.blockSales(PgFixture.operatorId, doc: 'fleet_insurance');

      expect(await catalogue.seatMap(departureId), isNotNull);
    });

    test('checkout refuses the sale, and names the reason', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 11),
      );
      final user = await fixture.traveller('7001');
      await fixture.blockSales(PgFixture.operatorId, doc: 'fleet_insurance');

      final outcome = await inventory.claim(
        fixture.claimFor(
          departureId: departureId,
          userId: user,
          seatLabels: const ['1A'],
          key: 'blocked-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );

      expect(outcome, isA<DepartureNotSellable>());
      expect(
        (outcome as DepartureNotSellable).reason,
        DepartureNotSellable.operatorBlocked,
        reason: 'not "cancelled" — nothing about the departure changed',
      );
    });

    test('the block lifts and the same seat sells', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 12),
      );
      final user = await fixture.traveller('7002');
      await fixture.blockSales(PgFixture.operatorId, doc: 'fleet_insurance');
      await fixture.blockSales(PgFixture.operatorId);

      final outcome = await inventory.claim(
        fixture.claimFor(
          departureId: departureId,
          userId: user,
          seatLabels: const ['1A'],
          key: 'unblocked-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );

      expect(outcome, isA<SeatsClaimed>());
    });
  });
}
