import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled catalog must match the source catalog, byte for byte.
///
/// `bel_localization` is pure Dart — the API imports it — so it cannot declare
/// Flutter assets, and Flutter refuses `..` in asset paths. The YAML is
/// therefore copied by `tool/sync_i18n.sh`, and a copy that drifts is the
/// failure mode worth guarding: it ships an app whose strings quietly disagree
/// with the server's, which is exactly the disagreement ADR-0008 exists to
/// prevent.
///
/// Fix a failure by running `./tool/sync_i18n.sh`.
void main() {
  test('the bundled catalog matches packages/bel_localization/i18n', () {
    final source = Directory('../../packages/bel_localization/i18n');
    final bundled = Directory('assets/i18n');

    expect(source.existsSync(), isTrue, reason: 'source catalog missing');
    expect(
      bundled.existsSync(),
      isTrue,
      reason: 'assets/i18n missing — run ./tool/sync_i18n.sh',
    );

    expect(
      _fingerprint(bundled),
      _fingerprint(source),
      reason:
          'The bundled catalog has drifted from the source. '
          'Run ./tool/sync_i18n.sh',
    );
  });
}

/// A hash over every relative path and its contents, so a missing file, an
/// extra file and an edited file all fail.
String _fingerprint(Directory root) {
  final entries = <String>[];

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final relative = entity.path
        .substring(root.path.length)
        .replaceAll(r'\', '/');
    entries.add('$relative:${entity.readAsStringSync()}');
  }

  entries.sort();
  return sha256.convert(utf8.encode(entries.join('\n'))).toString();
}
