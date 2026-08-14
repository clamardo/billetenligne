import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The translation catalog, loaded from the asset bundle.
///
/// A copy of the console's loader, for the same reason it is a copy there:
/// `bel_localization` is pure Dart so it cannot declare Flutter assets, and
/// the thing being shared is the *catalog* rather than the loader.
///
/// The scanner reaches for it in exactly one place — the conductor's sign-in,
/// which is `bel_backoffice`'s shared screen and speaks in catalog keys. Every
/// other string in this app is a French sentence written where it is shown:
/// there is one audience, they are standing at a coach door, and a translation
/// indirection between them and the word *EMBARQUÉ* buys nothing.
///
/// The same YAML the API reads from disk, copied into `assets/i18n` by
/// `tool/sync_i18n.sh` and guarded against drift by `i18n_freshness_test`.
/// One reviewed French sentence serves the screen, the SMS and the PDF
/// (ADR-0008).
abstract final class CatalogAssets {
  static Future<TranslationCatalog> load({
    String prefix = 'assets/i18n',
  }) async {
    final manifest = await rootBundle.loadString('$prefix/languages.yaml');

    // Enumerated from an index written by `tool/sync_i18n.sh`, not listed
    // here. What stood here was every file of every language, spelled out —
    // so Portuguese meant editing this list in four apps and six `assets:`
    // lines in four pubspecs, none of which have anything to do with
    // Portuguese, and any one of them missed shipped an app that silently
    // could not read half its own catalog. A language is now a folder and a
    // row in `languages.yaml`.
    //
    // Still not `AssetManifest`: parsing the whole bundle's manifest costs
    // more than reading one text file, on a device whose entire startup budget
    // is 2.5 seconds (ADR-0009).
    final index = await rootBundle.loadString('$prefix/index.txt');

    final sources = <String, String>{};
    for (final path in index.split('\n')) {
      final relative = path.trim();
      if (relative.isEmpty) continue;
      // `pages/travel.yaml` under `fr` is bundled flat, because a Flutter
      // `assets:` entry names one directory and does not recurse.
      final flat = relative.replaceAll('/', '__');
      sources[relative] = await rootBundle.loadString('$prefix/$flat');
    }

    return TranslationCatalog.fromSources(
      languagesYaml: manifest,
      files: sources,
    );
  }
}

/// Puts a translator in the tree, and lets any widget change the language.
///
/// Changing language is a *rebuild*, not a restart: on a shared handset the
/// person who hands you the phone has already set it to the wrong one, and
/// making them wait through a cold start to fix it is a small cruelty.
final class Localized extends StatefulWidget {
  const Localized({
    required this.catalog,
    required this.child,
    this.initialLanguage = 'fr',
    this.onChanged,
    super.key,
  });

  final TranslationCatalog catalog;
  final Widget child;
  final String initialLanguage;

  /// Told after the tree has already repainted, so whoever composed the app
  /// can put the choice somewhere it survives.
  ///
  /// **Here rather than threaded down to whichever widget holds the control.**
  /// Every app has a different one — a settings screen, an icon in a
  /// navigation rail, a menu in an app bar — and passing a callback down to
  /// each of them means the language only persists on the surfaces somebody
  /// remembered to wire. `context.setLanguage(code)` is the whole act, from
  /// anywhere.
  ///
  /// Null in tests and in any composition with nothing to write to, where a
  /// switch holds for the run and no further.
  final void Function(String code)? onChanged;

  @override
  State<Localized> createState() => _LocalizedState();

  static _LocalizationScope _scope(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_LocalizationScope>();
    assert(scope != null, 'No Localized ancestor. Wrap the app in one.');
    return scope!;
  }
}

class _LocalizedState extends State<Localized> {
  late String _language = widget.initialLanguage;

  /// Repaint first, tell everybody else afterwards. Writing to a preference
  /// store and reaching the server are both allowed to be slow, and neither is
  /// allowed to hold up the screen somebody just asked to be able to read.
  ///
  /// Re-picking the language already in use is not an event: it would write a
  /// preference and call the server to arrive exactly where it started.
  void _set(String code) {
    if (code == _language) return;
    setState(() => _language = code);
    widget.onChanged?.call(code);
  }

  @override
  Widget build(BuildContext context) => _LocalizationScope(
    language: _language,
    catalog: widget.catalog,
    translator: CatalogTranslator(widget.catalog, _language),
    setLanguage: _set,
    child: widget.child,
  );
}

class _LocalizationScope extends InheritedWidget {
  const _LocalizationScope({
    required this.language,
    required this.catalog,
    required this.translator,
    required this.setLanguage,
    required super.child,
  });

  final String language;
  final TranslationCatalog catalog;
  final CatalogTranslator translator;
  final void Function(String) setLanguage;

  @override
  bool updateShouldNotify(_LocalizationScope old) => old.language != language;
}

/// `context.t('auth.email.label')` — the only way a widget reaches a
/// string. A hardcoded sentence anywhere else is a sentence that will ship in
/// the wrong language.
extension TranslationContext on BuildContext {
  CatalogTranslator get translator => Localized._scope(this).translator;

  String t(String key, [Map<String, Object?> args = const {}]) =>
      translator(key, args);

  /// A `key|arg|arg` message, rendered through the catalog (ADR-0008).
  String tEncoded(String message, {String prefix = ''}) =>
      translator.encoded(message, prefix: prefix);

  String tPlural(
    String key,
    int count, [
    Map<String, Object?> args = const {},
  ]) => translator.plural(key, count, args);

  String get language => Localized._scope(this).language;

  List<SupportedLanguage> get languages =>
      Localized._scope(this).catalog.languages;

  void setLanguage(String code) => Localized._scope(this).setLanguage(code);
}
