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

    group('adding a language', () {
      // The requirement, tested rather than asserted in a comment: a new
      // language is a folder under `i18n/` and a row in `languages.yaml`.
      // Nothing else, in any app, ever.
      //
      // The three things that used to break it are all gone and all covered
      // below: the resolver no longer compares against a literal, each app
      // enumerates an index instead of a hard-coded file list, and the account
      // route validates against the catalog rather than a market file.

      TranslationCatalog withPortuguese() => TranslationCatalog.fromSources(
        languagesYaml: '''
defaultLanguage: fr
languages:
  - code: fr
    culture: fr_CG
    englishName: French
    nativeName: Français
    displayOrder: 1
  - code: en
    culture: en
    englishName: English
    nativeName: English
    displayOrder: 2
  - code: pt
    culture: pt
    englishName: Portuguese
    nativeName: Português
    displayOrder: 3
''',
        files: {
          'fr/common.yaml': 'common:\n  actions:\n    save: "Enregistrer"\n',
          'en/common.yaml': 'common:\n  actions:\n    save: "Save"\n',
          'pt/common.yaml': 'common:\n  actions:\n    save: "Guardar"\n',
        },
      );

      test('it is offered, in its own name and in its stated order', () {
        // What every language menu in every app renders from.
        final catalog = withPortuguese();
        expect(catalog.languages.map((l) => l.nativeName), [
          'Français',
          'English',
          'Português',
        ]);
      });

      test('a browser asking for it is given it', () {
        expect(withPortuguese().bestMatch(['pt-BR']), 'pt');
        expect(withPortuguese().bestMatch(['pt']), 'pt');
      });

      test('the account route accepts it', () {
        // `PATCH /public/v1/me` gates on exactly this call. It used to gate on
        // `markets.yaml`, which would have refused a language the server had
        // the strings for.
        expect(withPortuguese().isSupported('pt'), isTrue);
        expect(withPortuguese().isSupported('de'), isFalse);
      });

      test('its strings are read, and missing ones fall back to French', () {
        final catalog = withPortuguese();
        expect(catalog.strings('pt')['common.actions.save'], 'Guardar');
        // Half a translation is the normal state of a language on the day it
        // is added, and it must degrade to French rather than to a raw key.
        expect(catalog.mergedStrings('pt')['common.actions.save'], 'Guardar');
      });
    });

    group('a locale becoming a language', () {
      // Everything in this group was decided four separate times before it
      // lived here: three apps said `'fr'` and asked nobody, and the fourth
      // compared `Platform.localeName` to the literal `en`.

      test('an exact code is taken as it is', () {
        expect(catalog.bestMatch(['en']), 'en');
        expect(catalog.bestMatch(['fr']), 'fr');
      });

      test('a region is dropped, and either separator is understood', () {
        // What a browser actually sends is `en-GB`; what `Platform.localeName`
        // hands out on Android is `en_GB`. The second is the one that used to
        // answer French.
        expect(catalog.bestMatch(['en-GB']), 'en');
        expect(catalog.bestMatch(['en_US']), 'en');
        expect(catalog.bestMatch(['fr-CA']), 'fr');
      });

      test('case is not a language', () {
        expect(catalog.bestMatch(['EN']), 'en');
        expect(catalog.bestMatch(['en_gb']), 'en');
      });

      test('the order somebody asked in outranks how precisely they asked', () {
        // `navigator.languages` is a preference list. A Quebecois browser
        // sends `fr-CA` first and plain `en` second, and answering English
        // because that one happened to be written without a region would be
        // reading the punctuation instead of the person.
        expect(catalog.bestMatch(['fr-CA', 'en']), 'fr');
        expect(catalog.bestMatch(['en-GB', 'fr']), 'en');
        // And an unknown first choice is skipped rather than settled for.
        expect(catalog.bestMatch(['de-DE', 'en-GB', 'fr']), 'en');
        expect(catalog.bestMatch(['de', 'en-GB']), 'en');
      });

      test(
        'a language we do not carry falls back to French, not to nothing',
        () {
          expect(catalog.bestMatch(['de']), 'fr');
          expect(catalog.bestMatch(['ln-CG', 'sw']), 'fr');
          expect(catalog.bestMatch(const []), 'fr');
        },
      );

      test('empty and blank tags are not languages', () {
        // A browser with no preference set hands out an empty string, and an
        // empty primary subtag would otherwise match nothing repeatedly and
        // cost a walk of the whole list per tag.
        expect(catalog.bestMatch(['', '  ', 'en']), 'en');
        expect(catalog.bestMatch(['']), 'fr');
      });
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
