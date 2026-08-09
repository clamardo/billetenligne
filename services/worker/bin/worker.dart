import 'dart:io';

import 'package:bel_api/src/adapters/acs_notification_gateway.dart';
import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_worker/src/outbox_drain.dart';
import 'package:bel_worker/src/sweepers.dart';

/// One pass, then exit.
///
/// **Run-once, not a service.** It deploys as a cron job (a KEDA ScaledJob in
/// production), and that shape is the reason it is safe to be behind: nothing
/// here is a correctness guarantee, so a pass that does not run costs a tidier
/// database and nothing else. A long-lived process would need health checks,
/// restart policies and a story about what happens when two of them are alive
/// — for work that is three UPDATEs and a queue.
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

  final sweepers = Sweepers(db);
  final drain = OutboxDrain(
    db: db,
    notifications: notifications,
    catalog: CatalogLoader.fromDirectory(
      Platform.environment['BEL_I18N_DIR'] ??
          'packages/bel_localization/i18n',
    ),
  );

  final passes = <String, Future<SweepResult> Function()>{
    // The drain first. It is the only pass a traveller notices.
    'outbox': drain.drain,
    'holds': sweepers.expireHolds,
    'reservations': sweepers.expireReservations,
    'challenges': sweepers.purgeChallenges,
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
  return failed ? 1 : 0;
}
