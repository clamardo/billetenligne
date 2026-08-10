@Tags(['integration'])
library;

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_storefronts.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The vitrine and the public storefront, against a real database.
///
/// Two claims here that no fake can make, and both are policy rather than
/// Dart:
///
///   * the storefront resolves **because** migration 0005 lets the public
///     role read active operators, and stops resolving when the operator
///     stops being active. There is no status clause in the adapter's SQL,
///     which is the point;
///   * a storefront lists only the lines with a departure still to come, so
///     a poster campaign never lands somebody on an empty search result.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresStorefronts storefronts;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    storefronts = PostgresStorefronts(db);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  group('the editor', () {
    test('an operator who never opened it still has a storefront', () async {
      final vitrine = await storefronts.forOperator(PgFixture.operatorId);

      expect(vitrine, isNotNull);
      // The schema's defaults, and they are the documented ones: the house
      // green and a flat header, with the legal name carrying the title.
      expect(vitrine!.accentHue, 'foret');
      expect(vitrine.headerPattern, 'flat');
      expect(vitrine.titleFr, isNull);
      expect(vitrine.titleFor('fr'), 'Ocean du Nord');
    });

    test('what is saved is what comes back', () async {
      final saved = await storefronts.save(
        operatorId: PgFixture.operatorId,
        edit: const SaveVitrineRequest(
          accentHue: 'indigo',
          headerPattern: 'vagues',
          titleFr: 'Océan du Nord',
          titleEn: 'Ocean of the North',
          taglineFr: 'Le confort sur toutes les routes',
        ),
      );

      expect(saved!.accentHue, 'indigo');
      expect(saved.headerPattern, 'vagues');
      expect(saved.taglineFor('fr'), 'Le confort sur toutes les routes');
      // No English tagline was sent, so an English reader falls through to
      // the French one rather than to an empty header.
      expect(saved.taglineFor('en'), 'Le confort sur toutes les routes');
    });

    test('clearing a tagline stores null, not an empty string', () async {
      await storefronts.save(
        operatorId: PgFixture.operatorId,
        edit: const SaveVitrineRequest(
          accentHue: 'foret',
          headerPattern: 'flat',
          titleFr: '  ',
          taglineFr: '',
        ),
      );

      final row = await storefronts.forOperator(PgFixture.operatorId);

      // The difference matters: an empty string would win the fall-through
      // and render a header with nothing in it.
      expect(row!.titleFr, isNull);
      expect(row.titleFor('fr'), 'Ocean du Nord');
    });
  });

  group('the public storefront', () {
    test('resolves by code, case-insensitively', () async {
      await storefronts.save(
        operatorId: PgFixture.operatorId,
        edit: const SaveVitrineRequest(
          accentHue: 'ocean',
          headerPattern: 'diagonale',
          titleFr: 'Océan du Nord',
        ),
      );

      // A code read off a poster is typed however it is typed.
      final page = await storefronts.byCode('odn');

      expect(page, isNotNull);
      expect(page!.vitrine.accentHue, 'ocean');
      expect(page.vitrine.titleFor('fr'), 'Océan du Nord');
    });

    test('lists the lines with a departure still to come', () async {
      await fixture.departureAtLocalTime(
        seatLabels: const ['1A', '1B'],
        daysAhead: 3,
        localHour: 6,
      );

      final page = await storefronts.byCode('ODN');

      expect(page!.routes, isNotEmpty);
      final line = page.routes.first;
      expect(line.originCity, 'Brazzaville');
      expect(line.destinationCity, 'Pointe-Noire');
      // Enough to say "à partir de" without a second request.
      expect(line.fromFare.minor, greaterThan(0));
      expect(line.nextDepartureAt, isNotNull);
    });

    test('an unknown code is nothing, not an empty page', () async {
      expect(await storefronts.byCode('NOPE'), isNull);
    });

    test('an operator who is not selling has no storefront', () async {
      final suspended = await fixture.applicant(
        code: 'SUSP',
        legalName: 'Sotrapo',
        status: 'suspended',
      );

      // Not a branch in the adapter: the public role's policy is
      // `app_is_public() AND status = 'active'`, so the row simply is not
      // there. A page that outlives the right to sell is worse than a dead
      // link.
      expect(await storefronts.byCode('SUSP'), isNull);
      expect(await storefronts.forOperator(suspended), isNotNull);
    });
  });
}
