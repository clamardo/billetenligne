@Tags(['integration'])
library;

import 'dart:io';

import 'package:bel_api/src/adapters/demo_applicant_screening.dart';
import 'package:bel_api/src/application/auto_review_applications.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_review_queue.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_worker/src/compliance_watch.dart';
import 'package:bel_worker/src/demo_world.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// The demo world, seeded into a real database and taken out again.
///
/// **What is actually under test is the delete path.** Seeded data whose
/// removal is untested is seeded data that will still be in production a year
/// from now, under a name nobody recognises, with a real ticket sold against
/// it. So the last test here is the one that matters most: after `--purge`,
/// nothing bearing the mark is left in any table.
///
/// The rest of the file asserts that the world is worth having — that it
/// arrives in states the product actually branches on, rather than as four
/// rows that happen to be present.
void main() {
  final url = Platform.environment['DATABASE_URL'];
  final seedUrl = Platform.environment['SEED_DATABASE_URL'];

  if (url == null || url.isEmpty || seedUrl == null || seedUrl.isEmpty) {
    test('demo world', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late Database db;
  late Connection seed;
  late DemoWorld world;

  setUpAll(() async {
    db = Database.open(url);
    seed = await openSeedConnection(seedUrl);
    world = DemoWorld(db: db, seed: seed);
    await world.purge();
    await world.seed();
  });

  tearDownAll(() async {
    // The suite shares this database with every other integration test, so a
    // world left behind is a world the next file has to reason about.
    await world.purge();
    await db.close();
    await seed.close();
  });

  Future<List<Map<String, dynamic>>> query(String sql) async {
    final rows = await seed.execute(sql);
    return rows.map((r) => r.toColumnMap()).toList();
  }

  group('a world you can shop in', () {
    test('two companies are selling, on roads that meet', () async {
      final rows = await query('''
        SELECT o.code, o.status::text AS status, count(DISTINCT d.id) AS departures
          FROM operators o
          LEFT JOIN departures d ON d.operator_id = o.id
         WHERE o.status = 'active'
           AND o.code LIKE 'DEMO-%'
         GROUP BY o.code, o.status
         ORDER BY o.code
      ''');

      expect(rows.map((r) => r['code']), containsAll(['DEMO-ALZ', 'DEMO-KLV']));
      for (final row in rows.where((r) => r['code'] != 'DEMO-LKN')) {
        // A fortnight on two roads. The figure is not the point; having
        // something to search on any ordinary date is.
        expect(row['departures'], greaterThan(20), reason: '${row['code']}');
      }
    });

    test('every departure has a seat map to sell from', () async {
      final rows = await query('''
        SELECT count(*) AS empty
          FROM departures d
          JOIN operators o ON o.id = d.operator_id
         WHERE o.code LIKE 'DEMO-%'
           AND NOT EXISTS (SELECT 1 FROM seats s WHERE s.departure_id = d.id)
      ''');
      expect(rows.single['empty'], 0);
    });

    test('the approvals are real approvals, with a trail', () async {
      final rows = await query('''
        SELECT count(*) AS approvals
          FROM audit_log a
          JOIN operators o ON o.id = a.operator_id
         WHERE o.code LIKE 'DEMO-%'
           AND a.action = 'operator.approve'
           AND a.actor_id IS NOT NULL
      ''');
      // Not INSERTed into place: a reviewer decided, and the log says so.
      expect(rows.single['approvals'], greaterThanOrEqualTo(3));
    });
  });

  group('the onboarding pass has something to do', () {
    test(
      'it approves the small complete one and flags the duplicate',
      () async {
        final review = AutoReviewApplications(
          queue: PostgresReviewQueue(db),
          screening: const DemoApplicantScreening(),
          clock: const SystemClock(),
        );

        final result = await review.run();
        expect(result.assessed, greaterThanOrEqualTo(2));

        final rows = await query('''
        SELECT o.code, o.status::text AS status, o.risk_band, o.risk_reasons
          FROM operators o
         WHERE o.code IN ('DEMO-SERGE', 'DEMO-CLONE')
      ''');
        expect(rows, hasLength(2));

        final niari = rows.firstWhere((r) => r['code'] == 'DEMO-SERGE');
        // Asserted before the band, so a collision with another suite's
        // fixture names the reason rather than saying only "expected low".
        // The demo names are invented for exactly that reason, and this is
        // the line that notices when an invented one stops being unique.
        expect(niari['risk_reasons'], isEmpty);
        expect(niari['risk_band'], 'low');
        // `active`, not `approved`: the pass goes the whole way, because an
        // approval that still needs somebody to press activate is a queue with
        // an extra step rather than one item fewer.
        expect(niari['status'], 'active');

        final clone = rows.firstWhere((r) => r['code'] == 'DEMO-CLONE');
        expect(clone['risk_band'], 'elevated');
        expect(clone['risk_reasons'], contains('duplicate_operator'));
        // Sorted, not decided. An elevated band is a reason to look, and the
        // pass never approves one.
        expect(clone['status'], 'under_review');
      },
    );

    test('screening clears the demo companies and nobody else', () async {
      const screening = DemoApplicantScreening();
      expect(
        await screening.screen(operatorId: 'x', code: 'DEMO-SERGE'),
        ScreeningOutcome.clear,
      );
      // The guard that makes this safe to leave wired in production: it is
      // keyed to the operator's own code, not to an environment flag, so
      // BEL__SCREENING=demo surviving a deployment approves nobody.
      expect(
        await screening.screen(operatorId: 'x', code: 'SOT'),
        ScreeningOutcome.notRun,
      );
    });
  });

  group('the compliance pass has something to do', () {
    test('the lapsed company stops selling; the others do not', () async {
      await ComplianceWatch(db).watch();

      final rows = await query('''
        SELECT code, sales_blocked_at IS NOT NULL AS blocked, sales_blocked_doc
          FROM operators
         WHERE code IN ('DEMO-LKN', 'DEMO-ALZ', 'DEMO-KLV')
         ORDER BY code
      ''');

      final lapsed = rows.firstWhere((r) => r['code'] == 'DEMO-LKN');
      expect(lapsed['blocked'], isTrue);
      expect(lapsed['sales_blocked_doc'], 'fleet_insurance');

      // Three weeks out is a banner, not a stop — which is the whole point of
      // having a ladder rather than a deadline.
      expect(
        rows.firstWhere((r) => r['code'] == 'DEMO-KLV')['blocked'],
        isFalse,
      );
      expect(
        rows.firstWhere((r) => r['code'] == 'DEMO-ALZ')['blocked'],
        isFalse,
      );
    });
  });

  group('somebody to call for help', () {
    test('both selling companies are in the open channel, and dated', () async {
      // A channel with one member is a channel that looks broken. Both, so a
      // call put out from either console has somebody on the other end.
      final rows = await query('''
        SELECT code, open_protection_at
          FROM operators
         WHERE code IN ('DEMO-ALZ', 'DEMO-KLV', 'DEMO-LKN')
         ORDER BY code
      ''');

      for (final code in ['DEMO-ALZ', 'DEMO-KLV']) {
        expect(
          rows.firstWhere((r) => r['code'] == code)['open_protection_at'],
          isNotNull,
          reason: '$code is not in the open-protection channel',
        );
      }
    });

    test('joining is a person on a date, not a column that was set', () async {
      // The question a dispute about a rebill asks is who agreed to carry
      // somebody else's passengers, and when. A seeder that set the column
      // would answer neither.
      final rows = await query('''
        SELECT a.action, u.email
          FROM audit_log a
          JOIN user_accounts u ON u.id = a.actor_id
          JOIN operators o ON o.id = a.operator_id
         WHERE o.code = 'DEMO-ALZ' AND a.action = 'protection.open_in'
      ''');

      expect(rows, hasLength(1));
      expect(rows.single['email'], 'angele@$demoEmailDomain');
    });
  });

  group('taking it away again', () {
    test('seeding twice leaves one world, not two', () async {
      await world.purge();
      await world.seed();

      final rows = await query(
        "SELECT count(*) AS n FROM operators WHERE code LIKE 'DEMO-%'",
      );
      expect(rows.single['n'], 5);
    });

    test('purge leaves nothing behind', () async {
      await world.purge();

      final leftovers = await query('''
        SELECT
          (SELECT count(*) FROM operators WHERE code LIKE 'DEMO-%') AS operators,
          (SELECT count(*) FROM user_accounts
            WHERE email LIKE '%@demo.billetenligne.cg') AS people,
          (SELECT count(*) FROM operator_applications a
            JOIN operators o ON o.id = a.operator_id
           WHERE o.code LIKE 'DEMO-%') AS applications,
          (SELECT count(*) FROM departures d
            JOIN operators o ON o.id = d.operator_id
           WHERE o.code LIKE 'DEMO-%') AS departures,
          (SELECT count(*) FROM platform_staff s
            JOIN user_accounts u ON u.id = s.user_id
           WHERE u.email LIKE '%@demo.billetenligne.cg') AS staff,
          (SELECT count(*) FROM audit_log
            WHERE reason = 'dossier complet, RCCM verifie') AS audit
      ''');

      expect(leftovers.single, {
        'operators': 0,
        'people': 0,
        'applications': 0,
        'departures': 0,
        'staff': 0,
        'audit': 0,
      });

      // And the shared catalogue stays, deliberately: two operators serving
      // Pointe-Noire must mean the same Pointe-Noire, and it belongs to
      // nobody. Purging it would take the real world's routes with it.
      final cities = await query(
        "SELECT count(*) AS n FROM cities WHERE code = 'PNR'",
      );
      expect(cities.single['n'], 1);
    });
  });
}
