import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The translation catalog, loaded from the asset bundle.
///
/// The same YAML the API reads from disk, copied into `assets/i18n` by
/// `tool/sync_i18n.sh` and guarded against drift by `i18n_freshness_test`.
/// One reviewed French sentence serves the screen, the SMS and the PDF
/// (ADR-0008).
abstract final class CatalogAssets {
  /// Every file the bundle carries. Listed explicitly rather than discovered,
  /// because `AssetManifest` costs a parse of the whole manifest at startup on
  /// a device where startup budget is 2.5 seconds total (ADR-0009).
  static const files = <String>[
    'fr/common.yaml',
    'fr/enums/domain.yaml',
    'fr/errors/payment.yaml',
    'fr/errors/travel.yaml',
    'fr/messages/sms.yaml',
    'fr/pages/payment.yaml',
    'fr/pages/travel.yaml',
    'fr/reference/countries.yaml',
    'fr/reference/payment.yaml',
    'en/common.yaml',
    'en/enums/domain.yaml',
    'en/errors/payment.yaml',
    'en/errors/travel.yaml',
    'en/messages/sms.yaml',
    'en/pages/payment.yaml',
    'en/pages/travel.yaml',
    'en/reference/countries.yaml',
    'en/reference/payment.yaml',
  ];

  static Future<TranslationCatalog> load({
    String prefix = 'assets/i18n',
  }) async {
    final manifest = await rootBundle.loadString('$prefix/languages.yaml');

    final sources = <String, String>{};
    for (final file in files) {
      sources[file] = await rootBundle.loadString('$prefix/$file');
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
    super.key,
  });

  final TranslationCatalog catalog;
  final Widget child;
  final String initialLanguage;

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

  @override
  Widget build(BuildContext context) => _LocalizationScope(
    language: _language,
    catalog: widget.catalog,
    translator: CatalogTranslator(widget.catalog, _language),
    setLanguage: (code) => setState(() => _language = code),
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

/// `context.t('travel.search.title')` — the only way a widget reaches a
/// string. A hardcoded sentence anywhere else is a sentence that will ship in
/// the wrong language.
extension TranslationContext on BuildContext {
  CatalogTranslator get translator => Localized._scope(this).translator;

  String t(String key, [Map<String, Object?> args = const {}]) =>
      translator(key, args);

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
