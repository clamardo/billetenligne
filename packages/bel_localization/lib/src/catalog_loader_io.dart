import 'dart:io';

import 'translation_catalog.dart';

/// Filesystem loader — used by the Dart Frog API, the workers and tests.
///
/// Flutter apps do not use this: they load the same YAML from the asset
/// bundle and call [TranslationCatalog.fromSources] directly. Keeping I/O out
/// of the catalog itself is what lets one implementation serve both.
final class CatalogLoader {
  const CatalogLoader._();

  /// Reads `<dir>/languages.yaml` plus every `<dir>/<lang>/**.yaml`.
  static TranslationCatalog fromDirectory(String dir) {
    final root = Directory(dir);
    if (!root.existsSync()) {
      throw StateError('i18n directory not found: $dir');
    }

    final manifestFile = File('${root.path}/languages.yaml');
    if (!manifestFile.existsSync()) {
      throw StateError('languages.yaml not found in $dir');
    }

    final files = <String, String>{};
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml')) continue;
      if (entity.path == manifestFile.path) continue;

      final relative = entity.path
          .substring(root.path.length)
          .replaceAll(r'\', '/')
          .replaceFirst(RegExp(r'^/'), '');
      files[relative] = entity.readAsStringSync();
    }

    return TranslationCatalog.fromSources(
      languagesYaml: manifestFile.readAsStringSync(),
      files: files,
    );
  }
}
