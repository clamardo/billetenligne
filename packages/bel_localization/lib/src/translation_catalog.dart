import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'supported_language.dart';

/// The immutable, in-memory translation catalog (ADR-0008).
///
/// Every `i18n/{lang}/**.yaml` file is flattened to `lang -> (dotted key ->
/// value)`, alongside the `languages.yaml` manifest and a content hash for
/// cache-busting. Built once at startup and held as a singleton — on the
/// server, and in each Flutter app.
///
/// Ported from `CogitovaSchool.Localization.TranslationCatalog`.
final class TranslationCatalog {
  TranslationCatalog._(
    this.languages,
    this.defaultLanguage,
    this._byLanguage,
    this.hash,
  );

  /// Switchable languages, in display order.
  final List<SupportedLanguage> languages;

  /// Platform default *and* source language — `fr` (ADR-0008).
  final String defaultLanguage;

  /// Stable hash over the whole catalog — the client ETag / cache key.
  final String hash;

  final Map<String, Map<String, String>> _byLanguage;
  final Map<String, Map<String, String>> _merged = {};

  bool isSupported(String? code) =>
      code != null && code.isNotEmpty && _byLanguage.containsKey(code);

  SupportedLanguage? find(String? code) {
    for (final l in languages) {
      if (l.code == code) return l;
    }
    return null;
  }

  /// The flat key/value map for a language, falling back to the default.
  Map<String, String> strings(String code) =>
      _byLanguage[code] ?? _byLanguage[defaultLanguage]!;

  /// The language's map with default-language strings folded in for missing
  /// keys — what a web console fetches, so one dictionary gives it the same
  /// fallback behaviour the server has.
  Map<String, String> mergedStrings(String code) {
    if (code == defaultLanguage || !_byLanguage.containsKey(code)) {
      return _byLanguage[defaultLanguage]!;
    }
    return _merged.putIfAbsent(code, () {
      final merged = Map<String, String>.from(_byLanguage[defaultLanguage]!);
      merged.addAll(_byLanguage[code]!);
      return merged;
    });
  }

  /// All language codes present in the catalog.
  Iterable<String> get codes => _byLanguage.keys;

  /// Builds the catalog from raw file contents.
  ///
  /// [files] maps a catalog-relative path (`fr/pages/payment.yaml`) to its
  /// text. Keeping I/O out of here is what lets the same code run on the
  /// server (read from disk) and in Flutter (read from the asset bundle).
  static TranslationCatalog fromSources({
    required String languagesYaml,
    required Map<String, String> files,
  }) {
    final manifest = loadYaml(languagesYaml) as YamlMap;
    final defaultLanguage = (manifest['defaultLanguage'] as String?) ?? 'fr';

    final languages = <SupportedLanguage>[
      for (final entry in (manifest['languages'] as YamlList))
        SupportedLanguage(
          code: entry['code'] as String,
          culture: entry['culture'] as String? ?? entry['code'] as String,
          englishName: entry['englishName'] as String? ?? '',
          nativeName: entry['nativeName'] as String? ?? '',
          flag: entry['flag'] as String? ?? '',
          rtl: entry['rtl'] as bool? ?? false,
          displayOrder: entry['displayOrder'] as int? ?? 0,
        ),
    ]..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

    final byLanguage = <String, Map<String, String>>{};
    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      if (!path.endsWith('.yaml')) continue;
      final slash = path.indexOf('/');
      if (slash <= 0) continue;
      final lang = path.substring(0, slash);

      final root = loadYaml(entry.value);
      final map = byLanguage.putIfAbsent(lang, () => <String, String>{});
      _flatten(root, null, map);
    }

    if (!byLanguage.containsKey(defaultLanguage)) {
      throw StateError(
        'Catalog has no files for the default language "$defaultLanguage".',
      );
    }

    return TranslationCatalog._(
      languages,
      defaultLanguage,
      byLanguage,
      _computeHash(byLanguage),
    );
  }

  static void _flatten(Object? node, String? prefix, Map<String, String> into) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final path = prefix == null ? key : '$prefix.$key';
        _flatten(entry.value, path, into);
      }
      return;
    }
    if (node == null) return;
    if (node is List) return;
    if (prefix != null) into[prefix] = node.toString();
  }

  /// FNV-1a over lang/key/value triples in stable order. Cheap, dependency
  /// free, and only ever compared for equality.
  static String _computeHash(Map<String, Map<String, String>> byLanguage) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    final langs = byLanguage.keys.toList()..sort();
    for (final lang in langs) {
      final keys = byLanguage[lang]!.keys.toList()..sort();
      for (final key in keys) {
        final line = '$lang|$key|${byLanguage[lang]![key]}\n';
        for (final byte in utf8.encode(line)) {
          hash = ((hash ^ byte) * prime) & 0xFFFFFFFFFFFFFFFF;
        }
      }
    }
    // Mask to 63 bits: Dart ints are signed, and a negative value would
    // render with a leading '-' and break the fixed-width ETag.
    return (hash & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0');
  }
}
