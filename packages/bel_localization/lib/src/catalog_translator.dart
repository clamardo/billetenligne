import 'interpolation.dart';
import 'plural_rules.dart';
import 'translation_catalog.dart';

/// Looks strings up for one resolved language.
///
/// Fallback chain: requested language -> default (`fr`) -> the key itself.
/// **Never throws.** A missing translation degrades to French, then to a
/// visible key — never to a crash and never to a blank (ADR-0008).
///
/// Ported from `CogitovaSchool.Localization.CatalogTranslator`.
final class CatalogTranslator {
  CatalogTranslator(
    TranslationCatalog catalog,
    String requested, {
    void Function(String key)? onMissing,
  }) : language = catalog.isSupported(requested)
           ? requested
           : catalog.defaultLanguage,
       _strings = catalog.strings(
         catalog.isSupported(requested) ? requested : catalog.defaultLanguage,
       ),
       _fallback = catalog.strings(catalog.defaultLanguage),
       _onMissing = onMissing;

  /// The language actually resolved — never an unsupported code.
  final String language;

  final Map<String, String> _strings;
  final Map<String, String> _fallback;
  final void Function(String key)? _onMissing;

  /// `t('payment.waiting.body', {'operator': 'Airtel Money'})`
  String call(String key, [Map<String, Object?> args = const {}]) =>
      TranslationInterpolation.format(_lookup(key) ?? _missing(key), args);

  /// A message encoded as `key|arg|arg`, rendered with `a1`, `a2`, …
  ///
  /// The convention ADR-0008 uses everywhere a layer knows *what happened*
  /// but not *who is reading*: a workspace emits `layout.saved|Car 51`, a
  /// refund policy emits `policy.line.tier|48|90`, and the sentence is
  /// assembled here. It lives in the translator rather than in each shell
  /// because it was written three times before this — twice identically, once
  /// with a different prefix — and a decoder that disagrees with the encoder
  /// renders somebody's key on screen.
  ///
  /// [prefix] is prepended to the key, so a surface with its own namespace of
  /// notices does not have to carry it in every emitted string.
  String encoded(String message, {String prefix = ''}) {
    final parts = message.split('|');
    return call('$prefix${parts.first}', {
      for (var i = 1; i < parts.length; i++) 'a$i': parts[i],
    });
  }

  /// Plural-aware lookup. Resolves `key.one` / `key.other` by CLDR category
  /// for the active language, and always injects `count`.
  ///
  /// French and English disagree at zero, which is exactly why this exists.
  String plural(String key, int count, [Map<String, Object?> args = const {}]) {
    final category = PluralRules.category(language, count);
    final template =
        _lookup('$key.$category') ?? _lookup('$key.other') ?? _missing(key);
    return TranslationInterpolation.format(template, {'count': count, ...args});
  }

  /// Enum labels live under `enum.{TypeName}.{value}`, so no surface needs a
  /// switch over domain states.
  String enumLabel(String typeName, String value) =>
      _lookup('enum.$typeName.$value') ?? value;

  /// Renders a domain failure. The domain never produces prose — it produces
  /// a key and params, and each surface renders it in the reader's language.
  String failure(String messageKey, [Map<String, Object?> params = const {}]) =>
      call(messageKey, params);

  String? _lookup(String key) => _strings[key] ?? _fallback[key];

  String _missing(String key) {
    _onMissing?.call(key);
    return key;
  }
}
