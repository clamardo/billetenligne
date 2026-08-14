import 'dart:io';

import 'package:postgres/postgres.dart';

/// Why a migration was refused, when it was.
enum MigrationRefusal {
  /// The database has a schema and no ledger, and nothing here can tell which
  /// files it has already seen.
  unknownBaseline,
}

/// What a run did.
final class MigrationOutcome {
  const MigrationOutcome.applied(this.applied, {this.baselined = 0})
    : refusal = null;
  const MigrationOutcome.refused(this.refusal) : applied = 0, baselined = 0;

  final int applied;
  final int baselined;
  final MigrationRefusal? refusal;

  bool get isRefusal => refusal != null;
}

/// Applies every migration [directory] holds that [session] has not seen.
///
/// **Forward-only and deliberately not idempotent.** `CREATE TYPE
/// operator_status` on a database that already has one is an error rather
/// than a no-op, and guarding every statement in forty-five files means
/// getting one of them wrong. So `schema_migrations` records what has run and
/// only what is missing runs.
///
/// A file is recorded **after** it succeeds, never before: one that failed
/// half way must run again, and it can, because every migration here is a
/// transaction of its own.
///
/// **A schema with no ledger is refused rather than guessed at.** Both ways
/// of guessing are destructive — re-running `0001` fails loudly, and marking
/// everything applied silently skips whatever it had not actually seen. The
/// caller says where the database is with [baseline], and **nothing is
/// written before that decision**: a refusal that had already created the
/// ledger would make the second attempt look like a fresh database and try to
/// apply `0001` over a live schema.
Future<MigrationOutcome> applyMigrations({
  required Session session,
  required Directory directory,
  String? baseline,
  void Function(String message)? log,
}) async {
  final say = log ?? stdout.writeln;
  final files = migrationFiles(directory);

  final hadLedger = await _exists(session, 'schema_migrations');
  final hadSchema = await _exists(session, 'operators');

  if (!hadLedger && hadSchema && (baseline ?? '').isEmpty) {
    return const MigrationOutcome.refused(MigrationRefusal.unknownBaseline);
  }

  await session.execute('''
    CREATE TABLE IF NOT EXISTS schema_migrations (
      filename   TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  ''');

  var baselined = 0;
  if (!hadLedger && hadSchema) {
    say('baseline $baseline');
    for (final file in files) {
      if (versionOf(file).compareTo(baseline!) > 0) continue;
      await session.execute(
        Sql.named(
          'INSERT INTO schema_migrations (filename) VALUES (@f) '
          'ON CONFLICT DO NOTHING',
        ),
        parameters: {'f': nameOf(file)},
      );
      baselined++;
    }
  }

  final seen = <String>{
    for (final row in await session.execute(
      'SELECT filename FROM schema_migrations',
    ))
      row[0]! as String,
  };

  var applied = 0;
  for (final file in files) {
    final name = nameOf(file);
    if (seen.contains(name)) continue;

    say('   $name');
    try {
      // Simple query mode, because a migration is a *script*: several
      // statements, its own BEGIN and COMMIT, and no parameters. The extended
      // protocol would refuse it at the first semicolon.
      await session.execute(
        file.readAsStringSync(),
        queryMode: QueryMode.simple,
      );
    } on Exception {
      // A file that failed half way leaves its own transaction open and
      // aborted, and every statement after it on this connection — including
      // the one that would say what happened — comes back 25P02 instead. End
      // it here, then let the real error out.
      try {
        await session.execute('ROLLBACK', queryMode: QueryMode.simple);
      } on Exception {
        // Nothing to roll back: the file had no BEGIN of its own.
      }
      rethrow;
    }

    await session.execute(
      Sql.named('INSERT INTO schema_migrations (filename) VALUES (@f)'),
      parameters: {'f': name},
    );
    applied++;
  }

  return MigrationOutcome.applied(applied, baselined: baselined);
}

/// The numbered `.sql` files in [directory], in order.
///
/// Anything else living there — a README, `verify.sql`, an editor's backup —
/// is not a migration and is not applied by accident.
List<File> migrationFiles(Directory directory) =>
    directory.listSync().whereType<File>().where(_isMigration).toList()
      ..sort((a, b) => nameOf(a).compareTo(nameOf(b)));

String nameOf(File file) => file.uri.pathSegments.last;

/// `0044_operator_active_for_identity.sql` → `0044`.
String versionOf(File file) => nameOf(file).split('_').first;

bool _isMigration(File file) {
  final name = nameOf(file);
  return name.endsWith('.sql') &&
      name.length > 4 &&
      name.substring(0, 4).codeUnits.every((u) => u >= 0x30 && u <= 0x39);
}

Future<bool> _exists(Session session, String table) async {
  final result = await session.execute(
    Sql.named("SELECT to_regclass('public.' || @t) IS NOT NULL"),
    parameters: {'t': table},
  );
  return result.first[0]! as bool;
}
