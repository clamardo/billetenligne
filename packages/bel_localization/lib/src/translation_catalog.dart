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

  /// The best language we carry for somebody who prefers [preferred], in
  /// their own order of preference.
  ///
  /// **The one place a locale becomes a language.** A handset and a browser
  /// both hand out BCP-47 tags — `en-GB`, `fr-CA`, `pt_BR` — and this catalog
  /// is keyed by folder name. Four apps were each deciding that on their own:
  /// three said `'fr'` and asked nobody, and the fourth read `dart:io` and
  /// compared the string to `en`, which answers French for `en-GB` if the
  /// separator is an underscore and throws outright on the web, where
  /// `Platform` does not exist.
  ///
  /// Each tag is resolved in turn — exact code, then primary subtag — and the
  /// first that lands wins, because the list is somebody's order of preference
  /// and it outranks how precisely they wrote any one entry. A Quebecois
  /// browser asking for `fr-CA` and then `en` reads French; `de-DE, en-GB`
  /// reads English. Case and separator are not part of a language, so `EN_gb`
  /// is somebody who reads English.
  ///
  /// [defaultLanguage] when nothing matches, which is the honest answer rather
  /// than a guess: French is what this market reads and what every string in
  /// this catalog is written in first (ADR-0008).
  String bestMatch(Iterable<String> preferred) {
    for (final raw in preferred) {
      final tag = raw.trim().toLowerCase().replaceAll('_', '-');
      if (tag.isEmpty) continue;

      // The primary subtag, which for a tag with no region is the tag itself —
      // so this is one comparison covering both, rather than two passes.
      final primary = tag.split('-').first;
      for (final language in languages) {
        final code = language.code.toLowerCase();
        if (code == tag || code == primary) return language.code;
      }
    }

    return defaultLanguage;
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
  ///
  /// **Two 32-bit lanes, not one 64-bit hash**, and that is not a style
  /// choice. The 64-bit version compiled fine and ran correctly everywhere it
  /// had ever been run — the API, the workers, `dart test` — and the first
  /// web build refused it outright: `0xcbf29ce484222325` cannot be
  /// represented exactly in JavaScript, where an int is a double. This
  /// package is shared by the server and by three Flutter apps, one of which
  /// is now a web build, so anything here has to be exact on both number
  /// systems.
  ///
  /// The multiply is done in shifts because `hash * 16777619` overflows the
  /// 53 bits a JS double holds exactly, while every operation below stays
  /// inside the 32 bits dart2js gives bitwise operators. Two independently
  /// seeded lanes are concatenated to keep the same 16-hex-character width
  /// the ETag depends on and to keep collisions as unlikely as before.
  static String _computeHash(Map<String, Map<String, String>> byLanguage) {
    var a = 0x811c9dc5;
    // A different seed for the second lane, so the two do not move together
    // and the concatenation is worth more than either half.
    var b = 0x1000193;

    final langs = byLanguage.keys.toList()..sort();
    for (final lang in langs) {
      final keys = byLanguage[lang]!.keys.toList()..sort();
      for (final key in keys) {
        final line = '$lang|$key|${byLanguage[lang]![key]}\n';
        for (final byte in utf8.encode(line)) {
          a = _fnvStep(a, byte);
          b = _fnvStep(b, byte ^ 0x5a);
        }
      }
    }

    return _hex8(a) + _hex8(b);
  }

  /// One FNV-1a round, entirely within 32 bits.
  ///
  /// `x * 16777619` written as shifts: the prime is
  /// `2^24 + 2^8 + 2^7 + 2^4 + 2^1 + 1`, so the sum of those shifted copies
  /// is the product. Every intermediate is masked, so nothing ever leaves the
  /// range both Dart VM ints and JS doubles represent exactly.
  static int _fnvStep(int hash, int byte) {
    var h = (hash ^ byte) & 0xFFFFFFFF;
    h =
        (h +
            ((h << 1) & 0xFFFFFFFF) +
            ((h << 4) & 0xFFFFFFFF) +
            ((h << 7) & 0xFFFFFFFF) +
            ((h << 8) & 0xFFFFFFFF) +
            ((h << 24) & 0xFFFFFFFF)) &
        0xFFFFFFFF;
    return h;
  }

  static String _hex8(int value) =>
      (value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
