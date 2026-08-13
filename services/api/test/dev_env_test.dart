import 'dart:io';

import 'package:bel_api/src/infrastructure/config/dev_env.dart';
import 'package:test/test.dart';

/// Finding `infra/dev/.env` when nothing else did.
///
/// The bug this exists for is not a crash. A launcher whose env file quietly
/// does not apply leaves the API on the in-memory composition, answering 200
/// with invented departures and the sign-in code on stdout — so every test
/// here is about the difference between *configured* and *looks configured*.
void main() {
  group('reading the file', () {
    test('the ordinary shape', () {
      final parsed = DevEnv.parse('''
# A comment
SMTP__HOST=localhost
SMTP__PORT=1025

DATABASE_URL=postgres://bel:bel@localhost:5432/db?sslmode=disable
''');
      expect(parsed['SMTP__HOST'], 'localhost');
      expect(parsed['SMTP__PORT'], '1025');
      expect(parsed['DATABASE_URL'], contains('sslmode=disable'));
      expect(parsed, hasLength(3));
    });

    test('a blank value is a value, because blank is a supported state', () {
      // `COMMS__CONNECTIONSTRING=` is how a local run says "no ACS, use the
      // catcher". Dropping the key would change the answer.
      final parsed = DevEnv.parse('COMMS__CONNECTIONSTRING=\nA=1');
      expect(parsed.containsKey('COMMS__CONNECTIONSTRING'), isTrue);
      expect(parsed['COMMS__CONNECTIONSTRING'], '');
    });

    test('an `=` inside a value survives', () {
      // Base64 keys end in `=` and a connection string is full of them.
      final parsed = DevEnv.parse('STORAGE__KEY=Eby8vdM0+2xNOcq/K1SZ==');
      expect(parsed['STORAGE__KEY'], 'Eby8vdM0+2xNOcq/K1SZ==');
    });

    test('quotes come off, because `source` takes them off too', () {
      final parsed = DevEnv.parse('A="a value"\nB=\'another\'');
      expect(parsed['A'], 'a value');
      expect(parsed['B'], 'another');
    });

    test('a line nobody meant as a variable is skipped, never thrown on', () {
      // A comment somebody adds must not stop the API booting.
      final parsed = DevEnv.parse('''
this is prose
=novalue
KEY WITH SPACE=1
GOOD=1
''');
      expect(parsed.keys, ['GOOD']);
    });
  });

  group('filling the gaps', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('devenv');
      Directory('${root.path}/infra/dev').createSync(recursive: true);
      File('${root.path}/infra/dev/.env')
          .writeAsStringSync('DATABASE_URL=postgres://from-file\nSMTP__HOST=localhost\n');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('an empty environment is filled', () {
      final filled = DevEnv.fill(const {}, from: root, announce: (_) {});
      expect(filled['DATABASE_URL'], 'postgres://from-file');
      expect(filled['SMTP__HOST'], 'localhost');
    });

    test('found from a subdirectory, because the API runs in services/api', () {
      final deep = Directory('${root.path}/services/api')
        ..createSync(recursive: true);
      final filled = DevEnv.fill(const {}, from: deep, announce: (_) {});
      expect(filled['SMTP__HOST'], 'localhost');
    });

    test('a configured process is left completely alone', () {
      // `DATABASE_URL` set is the marker: a deployment has one and does not
      // have this file, and a developer who exported one meant it. Reading
      // the file anyway is how a production process picks up a local Postgres.
      final filled = DevEnv.fill(
        const {'DATABASE_URL': 'postgres://real'},
        from: root,
        announce: (_) {},
      );
      expect(filled['DATABASE_URL'], 'postgres://real');
      expect(filled.containsKey('SMTP__HOST'), isFalse);
    });

    test('no file is not an error — that is a container', () {
      final bare = Directory.systemTemp.createTempSync('nowhere');
      addTearDown(() => bare.deleteSync(recursive: true));
      expect(DevEnv.fill(const {}, from: bare, announce: (_) {}), isEmpty);
    });

    test('it says so, because a value arriving from a file is worth knowing',
        () {
      final said = <String>[];
      DevEnv.fill(const {}, from: root, announce: said.add);
      expect(said.single, contains('infra/dev/.env'));
    });

    test('`none` turns it off, and something depends on that', () {
      // `tool/smoke_api.sh` exercises the fakes composition on purpose, in a
      // working tree that has a real `.env` next to it. Without the off
      // switch this helper quietly gave that suite a database.
      expect(
        DevEnv.fill(const {'BEL_ENV_FILE': 'none'}, from: root, announce: (_) {}),
        const {'BEL_ENV_FILE': 'none'},
      );
    });

    test('a named file is read instead of the walk', () {
      final other = File('${root.path}/elsewhere.env')
        ..writeAsStringSync('SMTP__HOST=elsewhere\n');
      final filled = DevEnv.fill(
        {'BEL_ENV_FILE': other.path},
        from: root,
        announce: (_) {},
      );
      expect(filled['SMTP__HOST'], 'elsewhere');
    });

    test('a named file that is not there is not a crash', () {
      // A path typed wrong must produce the ordinary "nothing configured"
      // path, not a stack trace at startup.
      final filled = DevEnv.fill(
        const {'BEL_ENV_FILE': '/nowhere/at/all.env'},
        from: root,
        announce: (_) {},
      );
      expect(filled.containsKey('SMTP__HOST'), isFalse);
    });
  });
}
