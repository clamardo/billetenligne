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
/// The bundle is **flat** — `pages/travel.yaml` under `fr` arrives as
/// `fr__pages__travel.yaml` — because a Flutter `assets:` entry names one
/// directory and does not recurse, and the nested form cost every app six
/// pubspec lines per language. So this compares the source tree against the
/// flattened bundle rather than tree against tree, and it checks `index.txt`
/// too: an index that has lost a file is an app that reads half a catalog and
/// says nothing.
///
/// Fix a failure by running `./tool/sync_i18n.sh`.
void main() {
  final source = Directory('../../packages/bel_localization/i18n');
  final bundled = Directory('assets/i18n');

  test('the bundled catalog matches packages/bel_localization/i18n', () {
    expect(source.existsSync(), isTrue, reason: 'source catalog missing');
    expect(
      bundled.existsSync(),
      isTrue,
      reason: 'assets/i18n missing — run ./tool/sync_i18n.sh',
    );

    expect(
      _fingerprint(bundled, flat: true),
      _fingerprint(source, flat: false),
      reason:
          'The bundled catalog has drifted from the source. '
          'Run ./tool/sync_i18n.sh',
    );
  });

  test('the index names every file the bundle carries', () {
    // The app enumerates this file instead of the file system, so a name
    // missing from it is a page of strings that silently never loads — and
    // the app renders raw keys on whichever screen used them.
    final index = File(
      '${bundled.path}/index.txt',
    ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toSet();

    final expected = _catalogFiles(source)
        .map((f) => f.path.substring(source.path.length + 1))
        .where((p) => p != 'languages.yaml')
        .toSet();

    expect(index, expected, reason: 'stale index — run ./tool/sync_i18n.sh');
  });
}

List<File> _catalogFiles(Directory root) => [
  for (final entity in root.listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.yaml')) entity,
];

/// A hash over every relative path and its contents, so a missing file, an
/// extra file and an edited file all fail. [flat] undoes the bundling, so the
/// two sides are compared in the source's own vocabulary.
String _fingerprint(Directory root, {required bool flat}) {
  final entries = <String>[];

  for (final file in _catalogFiles(root)) {
    var relative = file.path.substring(root.path.length).replaceAll(r'\', '/');
    if (flat) relative = relative.replaceAll('__', '/');
    entries.add('$relative:${file.readAsStringSync()}');
  }

  entries.sort();
  return sha256.convert(utf8.encode(entries.join('\n'))).toString();
}
