import 'dart:io';

/// `infra/dev/.env`, when nothing else has said where anything is.
///
/// **Why this exists.** The local stack's variables live in one committed
/// file, and every launcher has its own way of getting them into a process:
/// `tool/api_dev.sh` sources it, VS Code has `envFile`, an IDE run
/// configuration has a table somebody fills in, and `dart run` has nothing at
/// all. When one of those quietly does not work, the API does not fail — it
/// falls back to the in-memory composition, answers 200, serves invented
/// departures and writes the sign-in code to its own stdout. Everything looks
/// like it is running. It cost an evening: a console signed in against fake
/// data, and a mail catcher that was never going to receive anything.
///
/// So the process finds the file itself. There is then one answer to "how do
/// I set the local environment" and it does not depend on what started the
/// program.
///
/// **It never overrides.** A variable already in the environment wins,
/// always — this fills gaps and cannot change a decision somebody made
/// deliberately. And it is skipped entirely when `DATABASE_URL` is already
/// set, which is the marker of a configured process: a deployment has one and
/// does not have this file, and a developer who exported one meant it.
///
/// **A deployed container never sees this.** The image carries
/// `services/api` and its dependencies, not `infra/dev`, so the walk finds
/// nothing and the map comes back untouched.
abstract final class DevEnv {
  /// [env] with anything missing filled in from `infra/dev/.env`.
  ///
  /// `BEL_ENV_FILE=none` turns it off, and `BEL_ENV_FILE=<path>` points it
  /// somewhere else. The off switch is not hypothetical: `tool/smoke_api.sh`
  /// exercises the **fakes** composition on purpose, in a working tree that
  /// has a perfectly good `.env` sitting next to it, and "no DATABASE_URL
  /// means fakes" is a contract that suite is built on.
  static Map<String, String> fill(
    Map<String, String> env, {
    Directory? from,
    void Function(String message)? announce,
  }) {
    final requested = env['BEL_ENV_FILE'] ?? '';
    if (requested == 'none') return env;
    if ((env['DATABASE_URL'] ?? '').isNotEmpty) return env;

    final file = requested.isEmpty
        ? _find(from ?? Directory.current)
        : (File(requested)..existsSync());
    if (file == null || !file.existsSync()) return env;

    final parsed = parse(file.readAsStringSync());
    if (parsed.isEmpty) return env;

    // The environment wins on every key it already has.
    final merged = <String, String>{...parsed, ...env};
    (announce ?? stdout.writeln)('env ${file.path} (${parsed.length} values)');
    return merged;
  }

  /// Up to five levels, because the working directory is `services/api` under
  /// dart_frog, `services/worker` for the worker, and the repository root for
  /// a test — and stopping short of the filesystem root keeps a stray
  /// `infra/dev/.env` in somebody's home directory out of it.
  static File? _find(Directory start) {
    var dir = start;
    for (var i = 0; i < 5; i++) {
      final candidate = File('${dir.path}/infra/dev/.env');
      if (candidate.existsSync()) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// The subset of dotenv this file actually uses: `KEY=value`, `#` comments,
  /// blank lines, and quotes around a value that has spaces in it.
  ///
  /// Deliberately not a dotenv library. The file is committed, it is read by
  /// `set -a; source` in two shell scripts, and anything those two cannot
  /// agree on has no business being in it — so the parser that matches them is
  /// the honest one. A line this does not understand is skipped rather than
  /// thrown on: a comment somebody adds must never stop the API booting.
  static Map<String, String> parse(String contents) {
    final out = <String, String>{};
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final eq = line.indexOf('=');
      if (eq <= 0) continue;

      final key = line.substring(0, eq).trim();
      if (key.isEmpty || !_isName(key)) continue;

      var value = line.substring(eq + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      out[key] = value;
    }
    return out;
  }

  static bool _isName(String key) {
    for (final unit in key.codeUnits) {
      final ok =
          (unit >= 0x41 && unit <= 0x5A) || // A-Z
          (unit >= 0x61 && unit <= 0x7A) || // a-z
          (unit >= 0x30 && unit <= 0x39) || // 0-9
          unit == 0x5F; // _
      if (!ok) return false;
    }
    return true;
  }
}
