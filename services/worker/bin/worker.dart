import 'dart:io';

import 'package:bel_api/src/adapters/acs_notification_gateway.dart';
import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/adapters/smtp_notification_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_ticket_links.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_worker/src/compliance_watch.dart';
import 'package:bel_worker/src/disbursement_pass.dart';
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
      // The local mail catcher, so a statement drained by the worker arrives
      // as a readable message with its PDF attached rather than as a line of
      // log saying a PDF existed. Same order as the API, and for the same
      // reason: ACS wins wherever it is configured.
      SmtpNotificationGateway.tryParse(
        Platform.environment['SMTP__HOST'],
        port: Platform.environment['SMTP__PORT'],
        emailFrom: Platform.environment['COMMS__EMAILFROM'],
      ) ??
      const LoggingNotificationGateway();

  // The same composition the API uses, so the worker polls through exactly
  // the adapters that opened the intents — a second wiring here would be a
  // second set of rail credentials to keep in step.
  final services = Services.resolve();

  final sweepers = Sweepers(db);
  final disbursements = DisbursementPass(
    db: db,
    rails: services.payoutRails,
    clock: services.clock,
  );
  final compliance = ComplianceWatch(db);
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
    // Where a ticket link points (ADR-0026). The same environment variable
    // the API reads for a trip share, because they are the same short domain
    // and two settings for one host is how one of them goes stale.
    links: PostgresTicketLinks(
      db,
      linkBase: Uri.parse(
        Platform.environment['BEL__SHAREBASEURL'] ?? 'https://blt.cg',
      ),
    ),
  );

  final passes = <String, Future<SweepResult> Function()>{
    // Payments first, and by a distance. Every other pass here is tidy-up
    // that costs a tidier database when it is skipped; this one is the
    // difference between a traveller boarding and a traveller who paid and
    // cannot.
    'payments': poller.poll,
    // Then money going the other way, and before the drain on purpose: a
    // refund that settles this pass sends its message the same run rather
    // than the next one, and "your money is on its way" is a sentence people
    // wait for.
    'refunds': disbursements.run,
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
    // A call for help nobody answered. Cheap, and it has to run often rather
    // than early: an inbox of stale requests is an inbox nobody opens, and
    // the cost of that lands on the next real call.
    'calls': sweepers.expireProtectionCalls,
    // The one pass that takes something away rather than tidying up: it
    // stops an operator whose insurance lapsed from selling, and suspends
    // them a week later. Late in the order because the ladder is measured in
    // days — a block that lands ten minutes after the drain is a block that
    // landed on time.
    'compliance': compliance.watch,
    'challenges': sweepers.purgeChallenges,
    // Sorting the review queue and approving the small complete ones. Late,
    // because nobody is standing at a coach door waiting for it — but before
    // the drain would be better, so an approval sends its message the same
    // run rather than the next one, and that is a reordering worth doing the
    // day the pass is doing anything at all.
    'onboarding': () async {
      final result = await services.autoReview.run();
      return SweepResult(
        name: 'onboarding.assessed',
        affected: result.assessed,
      );
    },
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
