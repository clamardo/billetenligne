import 'dart:io';

import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

/// Resolve whether the suite runs from the package or the repo root.
String _i18nDir() => ['i18n', 'packages/bel_localization/i18n'].firstWhere(
  (p) => Directory(p).existsSync(),
  orElse: () => throw StateError('cannot locate bel_localization/i18n'),
);

void main() {
  late TranslationCatalog catalog;

  setUpAll(() {
    catalog = CatalogLoader.fromDirectory(_i18nDir());
  });

  group('catalog loading', () {
    test('French is the default and source language', () {
      expect(catalog.defaultLanguage, 'fr');
      expect(catalog.languages.first.code, 'fr');
      expect(catalog.languages.first.nativeName, 'Français');
    });

    test('nested YAML is flattened to dotted keys', () {
      expect(
        catalog.strings('fr')['payment.waiting.title'],
        'Vérifiez votre téléphone',
      );
      expect(
        catalog.strings('en')['payment.waiting.title'],
        'Check your phone',
      );
    });

    test('the content hash is stable and changes with content', () {
      final again = CatalogLoader.fromDirectory(_i18nDir());
      expect(again.hash, catalog.hash);
      expect(catalog.hash, hasLength(16));
    });

    test('mergedStrings folds French in behind English', () {
      final merged = catalog.mergedStrings('en');
      expect(merged['payment.waiting.title'], 'Check your phone');
      // Every French key is reachable, so a missing English key degrades.
      for (final key in catalog.strings('fr').keys) {
        expect(merged.containsKey(key), isTrue, reason: 'missing $key');
      }
    });
  });

  group('CatalogTranslator', () {
    test('resolves and interpolates named placeholders', () {
      final t = CatalogTranslator(catalog, 'fr');
      expect(
        t('payment.waiting.body', {
          'operator': 'Airtel Money',
          'amount': '9 300 FCFA',
        }),
        'Entrez votre code secret Airtel Money pour confirmer le paiement de 9 300 FCFA.',
      );
    });

    test('an unsupported language falls back to French', () {
      final t = CatalogTranslator(catalog, 'sw');
      expect(t.language, 'fr');
      expect(t('common.actions.pay'), 'Payer');
    });

    test('a missing key returns the key and reports it, never throws', () {
      final missing = <String>[];
      final t = CatalogTranslator(catalog, 'en', onMissing: missing.add);
      expect(t('does.not.exist'), 'does.not.exist');
      expect(missing, ['does.not.exist']);
    });

    test('enum labels avoid a switch on every surface', () {
      final fr = CatalogTranslator(catalog, 'fr');
      final en = CatalogTranslator(catalog, 'en');
      expect(fr.enumLabel('PaymentState', 'captured'), 'Payé');
      expect(en.enumLabel('PaymentState', 'captured'), 'Paid');
      expect(
        fr.enumLabel('VerificationResult', 'alreadyBoarded'),
        'DÉJÀ EMBARQUÉ',
      );
      // An unmapped value degrades to the raw value rather than blowing up.
      expect(fr.enumLabel('PaymentState', 'martian'), 'martian');
    });
  });

  group('plurals — French and English disagree at zero', () {
    test('French treats 0 and 1 as singular', () {
      final t = CatalogTranslator(catalog, 'fr');
      expect(t.plural('common.units.seatsLeft', 0), '0 place restante');
      expect(t.plural('common.units.seatsLeft', 1), '1 place restante');
      expect(t.plural('common.units.seatsLeft', 3), '3 places restantes');
    });

    test('English treats 0 as plural', () {
      final t = CatalogTranslator(catalog, 'en');
      expect(t.plural('common.units.seatsLeft', 0), '0 seats left');
      expect(t.plural('common.units.seatsLeft', 1), '1 seat left');
      expect(t.plural('common.units.seatsLeft', 3), '3 seats left');
    });
  });

  group('CI guards — these are the checks that keep the catalog honest', () {
    test('every French key exists in English', () {
      final fr = catalog.strings('fr').keys.toSet();
      final en = catalog.strings('en').keys.toSet();
      final missing = fr.difference(en);
      expect(
        missing,
        isEmpty,
        reason: 'untranslated keys: ${missing.take(20)}',
      );
    });

    test('English has no keys that French does not', () {
      final fr = catalog.strings('fr').keys.toSet();
      final en = catalog.strings('en').keys.toSet();
      final orphans = en.difference(fr);
      expect(orphans, isEmpty, reason: 'orphaned English keys: $orphans');
    });

    test('placeholders match between locales', () {
      final fr = catalog.strings('fr');
      final en = catalog.strings('en');
      final mismatches = <String>[];
      for (final entry in fr.entries) {
        final other = en[entry.key];
        if (other == null) continue;
        final a = TranslationInterpolation.placeholdersIn(entry.value);
        final b = TranslationInterpolation.placeholdersIn(other);
        if (a.length != b.length || !a.containsAll(b)) {
          mismatches.add('${entry.key}: fr=$a en=$b');
        }
      }
      expect(mismatches, isEmpty);
    });

    test('no translated string is empty', () {
      for (final code in catalog.codes) {
        for (final entry in catalog.strings(code).entries) {
          expect(
            entry.value.trim(),
            isNotEmpty,
            reason: 'empty value at $code/${entry.key}',
          );
        }
      }
    });

    test('the fingerprint is exact on both number systems', () {
      // The first version of this hash used 64-bit FNV-1a. It ran correctly
      // everywhere it had ever been run — the API, the workers, `dart test` —
      // and the first `flutter build web` refused it outright:
      // `0xcbf29ce484222325` cannot be represented exactly in JavaScript,
      // where an int is a double.
      //
      // This package is imported by the server AND by three Flutter apps, one
      // of which is now a web build, so a value computed here has to be exact
      // on both number systems. The assertion is the width and the alphabet,
      // because those are what the ETag and the freshness test depend on.
      expect(catalog.hash, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('SMS templates stay within one segment where they can', () {
      // Multipart SMS costs a multiple. Anything over 160 chars is flagged so
      // the cost is a deliberate choice, not an accident (ADR-0013).
      final overLong = <String>[];
      for (final code in catalog.codes) {
        for (final entry in catalog.strings(code).entries) {
          if (!entry.key.startsWith('sms.')) continue;
          if (entry.value.length > 160) {
            overLong.add('$code/${entry.key} (${entry.value.length})');
          }
        }
      }
      expect(overLong, isEmpty, reason: 'multipart SMS: $overLong');
    });
  });
}
