import 'dart:io';

import 'package:bel_api/src/infrastructure/config/market_catalog.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The loader that makes `config/markets.yaml` mean something (ADR-0006).
///
/// The first group reads the **real file**, not a copy. A test against a
/// fixture would pass on the day somebody edits the real one into something
/// the parser refuses — and the whole promise of this file is that editing it
/// is safe to do without touching Dart.
void main() {
  final repoRoot = _repoRoot();

  group('the shipped config/markets.yaml', () {
    late MarketCatalog catalog;

    setUp(() {
      catalog = MarketCatalog.load(path: '$repoRoot/config/markets.yaml');
    });

    test('parses, and Congo-Brazzaville is the default', () {
      expect(catalog.defaultMarket.code, 'CG');
      expect(catalog.byCode('cg'), isNotNull);
    });

    test('says the same thing as the compiled-in fallback', () {
      // The one that matters. `Market.congoBrazzaville` is what runs when the
      // file is absent, so the day the two disagree is the day a fresh clone
      // and a deployment price the same seat differently.
      final loaded = catalog.defaultMarket;
      const compiled = Market.congoBrazzaville;

      expect(loaded.currency, compiled.currency);
      expect(loaded.timeZone, compiled.timeZone);
      expect(loaded.nameKey, compiled.nameKey);
      expect(loaded.defaultLanguage, compiled.defaultLanguage);
      expect(loaded.languages, compiled.languages);
      expect(loaded.serviceFee, compiled.serviceFee);
      expect(loaded.msisdn.countryCode, compiled.msisdn.countryCode);
      expect(loaded.msisdn.nationalLength, compiled.msisdn.nationalLength);
      expect(
        loaded.msisdn.prefixes.map((k, v) => MapEntry(k, v.id)),
        compiled.msisdn.prefixes.map((k, v) => MapEntry(k, v.id)),
      );
      expect(
        loaded.rails.map((r) => r.id),
        compiled.rails.map((r) => r.id),
        reason: 'the rails, in display order',
      );
      for (final rail in loaded.rails) {
        final same = compiled.railById(rail.id)!;
        expect(rail.enabled, same.enabled, reason: rail.id);
        expect(rail.kind, same.kind, reason: rail.id);
        expect(rail.operator?.id, same.operator?.id, reason: rail.id);
        expect(rail.ussdCode, same.ussdCode, reason: rail.id);
        expect(rail.minAmount, same.minAmount, reason: rail.id);
        expect(rail.maxAmount, same.maxAmount, reason: rail.id);
      }
    });

    test('Orange Money is present and switched off, with a reason', () {
      final orange = catalog.defaultMarket.railById('cg.orange_money')!;
      expect(orange.enabled, isFalse);
      expect(orange.disabledReasonKey, 'payment.rail.comingSoon');
    });

    test('a disabled rail is not offered for a number on that carrier', () {
      expect(
        catalog.defaultMarket.railForOperator(MobileOperator.orange),
        isNull,
      );
    });
  });

  group('enabling a rail', () {
    test('is one line, and needs no code change', () {
      // The claim ADR-0006 makes, tested rather than asserted in a comment.
      final off = MarketCatalog.parse(_congo);
      expect(off.defaultMarket.railById('cg.orange_money')!.enabled, isFalse);

      final on = MarketCatalog.parse(
        _congo.replaceAll(
          '''
      - id: cg.orange_money
        kind: mobileMoney
        operator: orange
        enabled: false''',
          '''
      - id: cg.orange_money
        kind: mobileMoney
        operator: orange
        enabled: true''',
        ),
      );
      expect(on.defaultMarket.railById('cg.orange_money')!.enabled, isTrue);
      expect(
        on.defaultMarket.railForOperator(MobileOperator.orange)?.id,
        'cg.orange_money',
      );
    });

    test('a renumbered carrier prefix moves with the file', () {
      final table = MarketCatalog.parse(
        _congo.replaceAll('"04": airtel', '"04": mtn'),
      ).defaultMarket.msisdn;

      expect(table.lookup('041234567').id, 'mtn');
      expect(
        PhoneNumber.parse(
          '+242 04 123 45 67',
          table: table,
        ).valueOrNull!.operator.id,
        'mtn',
      );
    });

    test('a carrier we have never integrated still parses', () {
      // `MobileOperator` is deliberately not an enum, and this is the reason:
      // a second country names carriers we have never heard of, and naming one
      // must not be a code change.
      final rails = MarketCatalog.parse(
        _congo.replaceAll('operator: orange', 'operator: vodacom_mpesa'),
      ).defaultMarket.rails;
      expect(
        rails.where((r) => r.operator?.id == 'vodacom_mpesa'),
        hasLength(1),
      );
    });
  });

  group('a malformed file', () {
    void refuses(String yaml, Matcher message) => expect(
      () => MarketCatalog.parse(yaml),
      throwsA(
        isA<MarketConfigError>().having((e) => e.message, 'message', message),
      ),
    );

    test('with a currency we do not know the exponent of', () {
      // The one mistake we must never guess past: the exponent is what decides
      // whether 9 000 is nine thousand or ninety.
      refuses(
        _congo.replaceAll('currency: XAF', 'currency: ZWL'),
        contains('unknown currency ZWL'),
      );
    });

    test('with a rail kind that is not a kind', () {
      refuses(
        _congo.replaceAll('kind: mobileMoney', 'kind: crypto'),
        contains('unknown kind crypto'),
      );
    });

    test('with a mobile money rail and no carrier', () {
      refuses(
        _congo.replaceAll('        operator: airtel\n', ''),
        contains('needs an operator'),
      );
    });

    test('with the same rail listed twice', () {
      refuses(
        _congo.replaceAll('id: cg.card', 'id: cg.cash'),
        contains('cg.cash appears twice'),
      );
    });

    test('whose default market is not one of its markets', () {
      refuses(
        _congo.replaceAll('defaultMarket: CG', 'defaultMarket: CD'),
        contains('defaultMarket CD is not one of CG'),
      );
    });

    test('with no markets at all', () {
      refuses('defaultMarket: CG\nmarkets: []\n', contains('lists no markets'));
    });

    test('with a market missing its phone block', () {
      refuses(
        _congo.replaceAll('    phone:', '    phoneNumbers:'),
        contains('needs a phone block'),
      );
    });

    test('that is not YAML at all', () {
      refuses('markets: [\n  - id: "unclosed\n', contains('not valid YAML'));
    });
  });

  group('finding the file', () {
    test('a missing one falls back to the compiled-in market', () {
      // Every unit test and every fresh clone. Nothing is ever rail-less.
      final catalog = MarketCatalog.load(path: null, environment: const {});
      expect(catalog.defaultMarket.code, 'CG');
    });

    test('one named explicitly and absent is an error, not a fallback', () {
      // Somebody set the variable and expected it to be read. Falling back
      // here would serve last release's rails under a green deploy.
      expect(
        () => MarketCatalog.load(
          environment: const {'BEL_MARKETS_FILE': '/nowhere/markets.yaml'},
        ),
        throwsA(isA<MarketConfigError>()),
      );
    });

    test('BEL_MARKETS_FILE wins over the walk up the tree', () {
      final catalog = MarketCatalog.load(
        environment: {'BEL_MARKETS_FILE': '$repoRoot/config/markets.yaml'},
      );
      expect(catalog.defaultMarket.code, 'CG');
    });
  });

  group('a second country', () {
    test('is a block in the file and nothing else', () {
      // The DRC, exactly as `config/markets.yaml` documents it in comments —
      // three carriers, a ten-digit national number, its own currency.
      final catalog = MarketCatalog.parse('$_congo$_drc');

      expect(catalog.markets, hasLength(2));
      expect(catalog.defaultMarket.code, 'CG', reason: 'still Congo');

      final cd = catalog.byCode('CD')!;
      expect(cd.currency, Currency.cdf);
      expect(cd.msisdn.nationalLength, 10);
      expect(cd.serviceFee, const Money(1500, Currency.cdf));
      expect(cd.rails.map((r) => r.id), [
        'cd.airtel_money',
        'cd.orange_money',
        'cd.mpesa',
      ]);
      expect(
        cd.railForOperator(const MobileOperator('vodacom_mpesa'))?.id,
        'cd.mpesa',
      );
      // Amounts carry the market's currency, never the platform's.
      expect(cd.rails.first.minAmount, const Money(100, Currency.cdf));
    });
  });
}

String _repoRoot() {
  var dir = Directory.current;
  for (var up = 0; up < 5; up++) {
    if (File('${dir.path}/config/markets.yaml').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('config/markets.yaml not found from ${Directory.current}');
}

const _congo = '''
defaultMarket: CG

markets:
  - code: CG
    nameKey: reference.countries.CG
    currency: XAF
    timeZone: Africa/Brazzaville
    defaultLanguage: fr
    languages: [fr, en]
    serviceFeeMinor: 300
    defaultCommissionBps: 500
    phone:
      diallingCode: "242"
      nationalLength: 9
      prefixes:
        "06": mtn
        "05": airtel
        "04": airtel
    rails:
      - id: cg.airtel_money
        kind: mobileMoney
        operator: airtel
        ussdCode: "*128#"
        minAmountMinor: 100
        maxAmountMinor: 1000000
        enabled: true

      - id: cg.orange_money
        kind: mobileMoney
        operator: orange
        enabled: false
        disabledReasonKey: payment.rail.comingSoon

      - id: cg.card
        kind: card
        enabled: false

      - id: cg.cash
        kind: cash
        enabled: true
''';

const _drc = '''
  - code: CD
    nameKey: reference.countries.CD
    currency: CDF
    timeZone: Africa/Kinshasa
    defaultLanguage: fr
    languages: [fr, en]
    serviceFeeMinor: 1500
    phone:
      diallingCode: "243"
      nationalLength: 10
      prefixes:
        "099": airtel
        "097": orange
        "081": vodacom_mpesa
    rails:
      - id: cd.airtel_money
        kind: mobileMoney
        operator: airtel
        ussdCode: "*501#"
        minAmountMinor: 100
        enabled: true
      - id: cd.orange_money
        kind: mobileMoney
        operator: orange
        ussdCode: "*144#"
        enabled: true
      - id: cd.mpesa
        kind: mobileMoney
        operator: vodacom_mpesa
        ussdCode: "*1122#"
        enabled: true
''';
