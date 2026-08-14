import 'dart:io';

import 'package:bel_api/src/infrastructure/config/env.dart';
import 'package:test/test.dart';

/// Empty is unset.
///
/// The bug this exists for is not in this file. It is in the forty places
/// that read `env['X'] ?? 'a default'` — a reading that is right for a
/// variable somebody deliberately set to nothing, and wrong for the thing
/// that actually produces empties here. A Kubernetes ConfigMap is a map of
/// strings and cannot say *no value*, so a template with its keys filled in
/// and its values not arrives as `MTN__BASEURL: ""`, and the default host is
/// replaced by `Uri.parse('')`.
void main() {
  test('an empty value is not a value', () {
    final env = Env.present({
      'MTN__BASEURL': '',
      'DATABASE_URL': 'postgres://x',
    });
    expect(env.containsKey('MTN__BASEURL'), isFalse);
    // Which is what makes the default work again.
    expect(
      env['MTN__BASEURL'] ?? 'https://sandbox.momodeveloper.mtn.com',
      'https://sandbox.momodeveloper.mtn.com',
    );
    expect(env['DATABASE_URL'], 'postgres://x');
  });

  test('a value made of spaces is a value', () {
    // Trimming would be a second rule, and one that silently rewrites what
    // somebody wrote. A space is as broken as an empty string for a URL and
    // meaningful for a separator; only the unambiguous case is taken out.
    expect(Env.present({'X': ' '})['X'], ' ');
  });

  test('nothing else moves', () {
    final raw = {'A': '1', 'B': '', 'C': 'three'};
    expect(Env.present(raw).keys, ['A', 'C']);
    // And the original is left alone: this is read in one place at startup
    // and the caller may still hold the map it passed.
    expect(raw.length, 3);
  });

  group('a secret arrives as a file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('bel-secrets'));
    tearDown(() => dir.deleteSync(recursive: true));

    void mount(String name, String value) =>
        File('${dir.path}/$name').writeAsStringSync(value);

    test('one variable per file', () {
      mount('DATABASE_URL', 'postgres://bel_api@10.0.0.3/billetenligne');
      mount('TICKETS__SIGNINGSEED', 'c2VlZA==');

      final env = Env.resolve({'BEL__SECRETSDIR': dir.path});
      expect(env['DATABASE_URL'], 'postgres://bel_api@10.0.0.3/billetenligne');
      expect(env['TICKETS__SIGNINGSEED'], 'c2VlZA==');
    });

    test('the newline whoever wrote it did not mean', () {
      // `echo secret > file` appends one. A DATABASE_URL with a trailing
      // newline fails to connect with an error about the *host*, which sends
      // somebody to the network for a problem that is in a text file.
      mount('DATABASE_URL', 'postgres://x\n');
      expect(
        Env.resolve({'BEL__SECRETSDIR': dir.path})['DATABASE_URL'],
        'postgres://x',
      );
      mount('OTHER', 'value\r\n');
      expect(Env.resolve({'BEL__SECRETSDIR': dir.path})['OTHER'], 'value');
    });

    test('a trailing space is left alone', () {
      // Unlikely, and trimming it would be this code rewriting a credential.
      mount('KEY', 'value ');
      expect(Env.resolve({'BEL__SECRETSDIR': dir.path})['KEY'], 'value ');
    });

    test("Kubernetes's own hidden entries are not variables", () {
      // A projected volume is a timestamped directory and a `..data` symlink,
      // so a naive listing finds `..data` beside the real names.
      mount('DATABASE_URL', 'postgres://x');
      Directory('${dir.path}/..2026_08_14_10_00_00').createSync();
      File('${dir.path}/..data').writeAsStringSync('not a variable');

      final env = Env.resolve({'BEL__SECRETSDIR': dir.path});
      expect(env.keys, containsAll(['DATABASE_URL', 'BEL__SECRETSDIR']));
      expect(env.containsKey('..data'), isFalse);
    });

    test('the mount wins over what was exported', () {
      // A ConfigMap and a secrets mount naming the same key is a mistake, and
      // the more specific of the two is the one that was mounted.
      mount('DATABASE_URL', 'postgres://mounted');
      final env = Env.resolve({
        'BEL__SECRETSDIR': dir.path,
        'DATABASE_URL': 'postgres://exported',
      });
      expect(env['DATABASE_URL'], 'postgres://mounted');
    });

    test('an empty file is an unset variable', () {
      mount('COMMS__SMSFROM', '\n');
      expect(
        Env.resolve({
          'BEL__SECRETSDIR': dir.path,
        }).containsKey('COMMS__SMSFROM'),
        isFalse,
      );
    });

    test('a directory that is not there refuses, rather than starting', () {
      // With no DATABASE_URL this API falls back to the in-memory
      // composition and serves invented departures — a green deployment
      // selling seats on coaches that do not exist. A volume that did not
      // mount has to be louder than that.
      expect(
        () => Env.resolve({'BEL__SECRETSDIR': '${dir.path}/nowhere'}),
        throwsA(isA<StateError>()),
      );
    });
  });
}
