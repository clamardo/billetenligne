import 'dart:io';

import 'package:bel_api/src/adapters/acs_notification_gateway.dart';
import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_worker/src/outbox_drain.dart';
import 'package:bel_worker/src/payment_poller.dart';
import 'package:bel_worker/src/reliability.dart';
import 'package:bel_worker/src/seat_alerts.dart';
import 'package:bel_worker/src/sweepers.dart';
import 'package:bel_worker/src/timetable_horizon.dart';

/// One pass, then exit.
///
/// **Run-once, not a service.** It deploys as a cron job (a KEDA ScaledJob in
/// production), and that shape is the reason it is safe to be behind. A
/// long-lived process would need health checks, restart policies and a story
/// about what happens when two of them are alive — for work that is three
/// UPDATEs, a queue and a materialisation.
///
/// Most of these passes are tidy-up over a property that already holds
/// elsewhere, so a pass that does not run costs a tidier database and nothing
/// else. **Two are not.** `payments` is the difference between a traveller
/// boarding and a traveller who paid and cannot; `departures` keeps the far
/// edge of the sales window moving, and a night it is skipped is a night
/// nobody can book three weeks out — recoverable by a dispatcher in the
/// console, which is how it worked before this pass existed, but not
/// invisible.
///
///   dart run bin/worker.dart              # every pass
///   dart run bin/worker.dart outbox       # just the drain
///
/// The exit code is what a scheduler reads: non-zero if any pass threw, so a
/// failing drain is visible rather than a quiet gap in delivery.
Future<int> main(List<String> args) async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null || url.isEmpty) {
    stderr.writeln(
      'DATABASE_URL is unset. The worker has nothing to sweep and no queue '
      'to drain; the fakes composition serves the API only.',
    );
    return 2;
  }

  final only = args.isEmpty ? null : args.first;
  final db = Database.open(url);

  // Blank connection string is a supported state (ADR-0019): messages go to
  // the log rather than a handset, so a developer can watch the drain work
  // without anybody receiving anything.
  final NotificationGateway notifications =
      AcsNotificationGateway.tryParse(
        Platform.environment['COMMS__CONNECTIONSTRING'],
        emailFrom: Platform.environment['COMMS__EMAILFROM'],
        smsFrom: Platform.environment['COMMS__SMSFROM'],
      ) ??
      const LoggingNotificationGateway();

  // The same composition the API uses, so the worker polls through exactly
  // the adapters that opened the intents — a second wiring here would be a
  // second set of rail credentials to keep in step.
  final services = Services.resolve();

  final sweepers = Sweepers(db);
  final seatAlerts = SeatAlertPass(db);
  final reliability = Reliability(db);
  final horizon = TimetableHorizon(
    db: db,
    console: services.console,
    clock: services.clock,
  );
  final poller = PaymentPoller(
    payments: services.payments,
    pay: services.payForBooking,
  );
  final drain = OutboxDrain(
    db: db,
    notifications: notifications,
    catalog: CatalogLoader.fromDirectory(
      Platform.environment['BEL_I18N_DIR'] ?? 'packages/bel_localization/i18n',
    ),
    // Every time in every message is rendered in this zone. The market's, not
    // the host's: a container in Europe would otherwise tell a traveller in
    // Brazzaville that their 06:00 coach leaves at 05:00.
    timeZone: services.market.timeZone,
  );

  final passes = <String, Future<SweepResult> Function()>{
    // Payments first, and by a distance. Every other pass here is tidy-up
    // that costs a tidier database when it is skipped; this one is the
    // difference between a traveller boarding and a traveller who paid and
    // cannot.
    'payments': poller.poll,
    // Then the drain — the only other pass a traveller notices.
    'outbox': drain.drain,
    // Then the one pass here that creates rather than tidies. After the two
    // a traveller notices, because a night without new inventory at the far
    // edge of a three-week window is a smaller problem than a payment left
    // unresolved.
    'departures': horizon.extend,
    'holds': sweepers.expireHolds,
    // After the holds, and the order matters: the hold is what puts the seats
    // back on sale, and this pass only records that the promise attached to
    // them has lapsed.
    'changes': sweepers.expireChangeOrders,
    // After the holds, and that ordering is the pass: an abandoned checkout
    // is the commonest way a seat comes back, and it is not free until
    // `holds` has released it. Before the outbox would be better still, but
    // the drain runs every few minutes and payments come first.
    'alerts': seatAlerts.notify,
    'alerts-expired': seatAlerts.expire,
    'reservations': sweepers.expireReservations,
    'challenges': sweepers.purgeChallenges,
    // Last, and cheap to be last: the figure moves once a day, and a search
    // reading yesterday's is reading something true about the operator.
    'reliability': reliability.recompute,
  };

  var failed = false;

  for (final entry in passes.entries) {
    if (only != null && only != entry.key) continue;
    try {
      final result = await entry.value();
      stdout.writeln('   ${result.name}: ${result.affected}');
    } catch (e, s) {
      // One failing pass must not stop the others: a jammed outbox is not a
      // reason to stop releasing lapsed holds.
      failed = true;
      stderr.writeln('[worker] ${entry.key} failed: $e\n$s');
    }
  }

  await db.close();
  await services.close();
  return failed ? 1 : 0;
}
