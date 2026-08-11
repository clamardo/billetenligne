@Tags(['integration'])
library;

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The funnel, against the rows it is derived from (`04-payments.md` §8).
///
/// Four claims, and none of them can be made by a fake, because the whole
/// point of this query is that it invents nothing:
///
///   * the cohort is keyed on the day the **hold** was created, so a journey
///     that crosses midnight is counted once, on the day it started;
///   * a day with nothing on it is a **row of zeroes**, not a missing row —
///     the alert compares consecutive days and a gap makes it lie;
///   * the numbers agree with the tables: a booking that was never paid for
///     is `reserved` and not `paid`, and a hold that lapsed is neither;
///   * the channel filter is real, so a cash sale at a counter does not sit
///     in the same funnel as the app.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresPlatformConsole platform;
  late String analyst;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    platform = PostgresPlatformConsole(db, timeZone: PgFixture.timeZone);
    analyst = await fixture.platformStaff('viewer');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  test('every step is counted from the rows the sale left behind', () async {
    // Deltas, not absolutes: every other suite in this run sold something
    // through this same database today, and a test that asserted "six holds"
    // would be asserting what the suites before it happened to do.
    //
    // **The same window on both sides.** Asking for one day and then for
    // three compares two different queries: the shorter one's cohort begins
    // at midnight, and a suite that ran either side of it — which is any run
    // that happens to cross midnight in the market's own timezone, not UTC —
    // makes the two rows count different sets of holds.
    final before = (await platform.funnel(actorUserId: analyst, days: 3)).first;

    await fixture.journey(daysAgo: 0, stoppedAt: 'hold');
    await fixture.journey(daysAgo: 0, stoppedAt: 'lapsed');
    await fixture.journey(daysAgo: 0, stoppedAt: 'booking');
    await fixture.journey(daysAgo: 0, stoppedAt: 'refused');
    await fixture.journey(daysAgo: 0, stoppedAt: 'paid');
    await fixture.journey(daysAgo: 0, stoppedAt: 'paid');

    final today = (await platform.funnel(actorUserId: analyst, days: 3)).first;

    expect(today.held - before.held, 6);
    // Four of the six got as far as a booking; two never did.
    expect(today.reserved - before.reserved, 4);
    expect(today.paid - before.paid, 2);
    expect(today.holdsLapsed - before.holdsLapsed, 1);
    expect(today.paymentsFailed - before.paymentsFailed, 1);

    // And the rates are of the whole day, denominators included — which is
    // the point of sending counts rather than percentages down the wire.
    expect(
      today.holdToReservation,
      (100 * today.reserved / today.held).round(),
    );
    expect(today.holdToPaid, isNotNull);
  });

  test('a day with nothing on it is a row of zeroes, not a gap', () async {
    final funnel = await platform.funnel(actorUserId: analyst, days: 7);

    // Seven asked for, seven returned, newest first — whatever happened.
    expect(funnel, hasLength(7));
    expect(
      funnel.map((d) => d.day).toList(),
      orderedEquals(
        [...funnel.map((d) => d.day)]..sort((a, b) => b.compareTo(a)),
      ),
    );

    final quiet = funnel.firstWhere(
      (d) => d.held == 0,
      orElse: () => funnel.last,
    );
    if (quiet.held == 0) {
      expect(quiet.reserved, 0);
      expect(quiet.holdToPaid, isNull, reason: 'nought of nought is not zero');
    }
  });

  test('the cohort is the day the seat was held, not the day it was '
      'paid for', () async {
    final before = await platform.funnel(actorUserId: analyst, days: 5);
    final threeDaysAgoBefore = before[3];

    // The hold is backdated; the booking and its confirmation are stamped
    // now. If the query bucketed on the booking this would land on today.
    await fixture.journey(daysAgo: 3, stoppedAt: 'paid');

    final after = await platform.funnel(actorUserId: analyst, days: 5);

    expect(after[3].held, threeDaysAgoBefore.held + 1);
    expect(after[3].paid, threeDaysAgoBefore.paid + 1);
    expect(after.first.held, before.first.held);
  });

  test('a counter sale is not in the app funnel', () async {
    final before = await platform.funnel(actorUserId: analyst, days: 2);

    await fixture.journey(daysAgo: 0, stoppedAt: 'paid', channel: 'console');

    final app = await platform.funnel(actorUserId: analyst, days: 2);
    expect(app.first.held, before.first.held);

    final counter = await platform.funnel(
      actorUserId: analyst,
      days: 2,
      channel: 'console',
    );
    expect(counter.first.held, greaterThanOrEqualTo(1));
    expect(counter.first.paid, greaterThanOrEqualTo(1));
  });

  test(
    'the window is clamped, so a year cannot be asked for by typing',
    () async {
      final huge = await platform.funnel(actorUserId: analyst, days: 4000);

      expect(huge, hasLength(90));
    },
  );

  test('a reader is recorded, because this crosses every tenant', () async {
    await platform.recordRead(
      actorUserId: analyst,
      reason: 'weekly review',
      action: 'analytics.funnel',
      subjectType: 'funnel',
      subjectId: 'app/14d',
    );

    final trail = await fixture.auditByAction('analytics.funnel');

    expect(trail, isNotEmpty);
    expect(trail.last['actor_id'], analyst);
    expect(trail.last['reason'], 'weekly review');
    // No operator: the funnel is nobody's file, and stamping one on the row
    // would put a platform-wide read into a single company's history.
    expect(trail.last['operator_id'], isNull);
  });
}
