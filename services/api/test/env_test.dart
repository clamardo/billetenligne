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
}
