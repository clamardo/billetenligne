import 'dart:io';

import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Market — Congo-Brazzaville is the launch market', () {
    test('exactly one market is served', () {
      expect(Market.all, hasLength(1));
      expect(Market.current, Market.congoBrazzaville);
    });

    test('carries the facts that actually vary by country', () {
      const m = Market.congoBrazzaville;
      expect(m.code, 'CG');
      expect(m.currency, Currency.xaf);
      expect(m.currency.exponent, 0, reason: 'XAF is zero-decimal');
      expect(m.diallingCode, '242');
      expect(m.msisdn.nationalLength, 9);
      expect(m.defaultLanguage, 'fr');
      expect(m.languages, ['fr', 'en']);
      expect(m.timeZone, 'Africa/Brazzaville');
      expect(m.serviceFee, const Money.xaf(300));
    });

    test('launch rails are Airtel and MTN; Orange is present but disabled', () {
      const m = Market.congoBrazzaville;
      final live = m.mobileMoneyRails.where((r) => r.enabled).toList();

      expect(live.map((r) => r.operator), [
        MobileOperator.airtel,
        MobileOperator.mtn,
      ]);

      // Orange ships in wave 2 (ADR-0006). It exists as data so enabling it is
      // configuration, not a code change and not an app release.
      final orange = m.railById('cg.orange_money')!;
      expect(orange.enabled, isFalse);
      expect(
        orange.disabledReasonKey,
        isNotNull,
        reason: 'a disabled rail always explains itself',
      );
    });

    test('every mobile money rail offers a USSD fallback', () {
      // Push prompts genuinely fail to arrive. A user with a manual path
      // beats a user watching a spinner.
      for (final rail in Market.congoBrazzaville.mobileMoneyRails) {
        expect(rail.ussdCode, isNotNull, reason: rail.id);
      }
    });

    test('a number pre-selects its own wallet on the payment screen', () {
      const m = Market.congoBrazzaville;
      final phone = PhoneNumber.parse(
        '061234567',
        table: m.msisdn,
      ).valueOrNull!;

      expect(phone.operator, MobileOperator.mtn);
      expect(m.railForOperator(phone.operator)?.id, 'cg.mtn_momo');
    });

    test('a disabled rail is never pre-selected', () {
      expect(
        Market.congoBrazzaville.railForOperator(MobileOperator.orange),
        isNull,
      );
    });

    test('rails enforce their own amount limits', () {
      final airtel = Market.congoBrazzaville.railById('cg.airtel_money')!;
      expect(airtel.accepts(const Money.xaf(9300)), isTrue);
      expect(airtel.accepts(const Money.xaf(50)), isFalse);
      expect(airtel.accepts(const Money.xaf(2000000)), isFalse);
    });
  });

  group('adding a country is data plus an adapter', () {
    // This is the proof, not a promise. A complete second market is defined
    // here in test code alone — no production file is touched — and every
    // country-dependent behaviour keeps working against it.
    //
    // The DRC is the realistic next market: different currency (CDF), a
    // different carrier mix, and Airtel in common with Congo-Brazzaville so
    // that adapter is reused rather than rewritten.
    // DRC national numbers are 10 digits with the leading zero (0XX XXX XXXX),
    // where Congo-Brazzaville's are 9. Exactly the kind of fact that has to be
    // data rather than a constant buried in a parser.
    const drcPrefixes = MsisdnPrefixTable('243', 10, {
      '099': MobileOperator.airtel,
      '097': MobileOperator.orange,
      '081': MobileOperator.vodacomMpesa,
    });

    const drc = Market(
      code: 'CD',
      nameFr: 'République démocratique du Congo',
      nameEn: 'Democratic Republic of the Congo',
      currency: Currency.cdf,
      msisdn: drcPrefixes,
      timeZone: 'Africa/Kinshasa',
      defaultLanguage: 'fr',
      languages: ['fr', 'en'],
      serviceFee: Money(1500, Currency.cdf),
      rails: [
        // Airtel is already integrated — same adapter, new credentials.
        PaymentRail(
          id: 'cd.airtel_money',
          kind: PaymentRailKind.mobileMoney,
          operator: MobileOperator.airtel,
          ussdCode: '*501#',
        ),
        // These two would each need one new adapter. Nothing else changes.
        PaymentRail(
          id: 'cd.orange_money',
          kind: PaymentRailKind.mobileMoney,
          operator: MobileOperator.orange,
          ussdCode: '*144#',
        ),
        PaymentRail(
          id: 'cd.mpesa',
          kind: PaymentRailKind.mobileMoney,
          operator: MobileOperator.vodacomMpesa,
          ussdCode: '*1122#',
        ),
        PaymentRail(id: 'cd.cash', kind: PaymentRailKind.cash),
      ],
    );

    test('phone parsing works with no change to PhoneNumber', () {
      final phone = PhoneNumber.parse('0991234567', table: drc.msisdn);
      expect(phone.isOk, isTrue, reason: '${phone.failureOrNull}');
      expect(phone.valueOrNull!.operator, MobileOperator.airtel);
      expect(phone.valueOrNull!.format(), startsWith('+243'));
    });

    test('carrier detection resolves the right rail', () {
      final mpesaUser = PhoneNumber.parse(
        '0811234567',
        table: drc.msisdn,
      ).valueOrNull!;
      expect(mpesaUser.operator, MobileOperator.vodacomMpesa);
      expect(drc.railForOperator(mpesaUser.operator)?.id, 'cd.mpesa');
    });

    test('money formats in the new currency with no change to Money', () {
      const fare = Money(45000, Currency.cdf);
      expect(fare.format(locale: 'fr'), contains('FC'));
      expect(fare.format(locale: 'en'), 'CDF 45,000');
      expect(fare.currency.exponent, 0, reason: 'CDF is also zero-decimal');
    });

    test('policy quoting is market-agnostic', () {
      // The refund engine never asks which country it is in — it only ever
      // sees Money, and Money already knows its currency.
      final departure = DateTime.utc(2026, 9, 1, 8);
      final quote = quoteRefund(
        faceValue: const Money(45000, Currency.cdf),
        serviceFee: drc.serviceFee,
        departsAt: departure,
        now: departure.subtract(const Duration(days: 2)),
        policy: RefundPolicy.souple(),
      ).valueOrNull!;

      expect(quote.refundable, const Money(45000, Currency.cdf));
      expect(quote.refundable.currency, Currency.cdf);
    });

    test('seat layouts, refs and holds carry no country assumption', () {
      final layout = SeatLayout.busStandard49();
      expect(layout.capacity, 49);

      final ref = BookingRef.parse('7QK4M2');
      expect(ref.isOk, isTrue);

      const policy = HoldPolicy.standard;
      expect(policy.isValid, isTrue);
    });

    test('a shared carrier reuses its adapter across markets', () {
      final cg = Market.congoBrazzaville.railForOperator(
        MobileOperator.airtel,
      )!;
      final cd = drc.railForOperator(MobileOperator.airtel)!;

      expect(cg.operator, cd.operator, reason: 'same carrier');
      expect(
        cg.id,
        isNot(cd.id),
        reason: 'namespaced per market — separate credentials and limits',
      );
    });
  });

  group('carriers are an open set', () {
    test('an unlisted carrier degrades rather than throwing', () {
      // A closed enum here would mean every new country edits a type that
      // switch statements depend on being exhaustive.
      expect(MobileOperator.byId('safaricom_mpesa'), MobileOperator.unknown);
      expect(MobileOperator.byId('airtel'), MobileOperator.airtel);
    });

    test('a carrier label is a catalog key, never prose', () {
      expect(MobileOperator.mtn.labelKey, 'enum.MobileOperator.mtn');
    });

    test('an unknown prefix does not guess', () {
      final phone = PhoneNumber.parse('091234567').valueOrNull!;
      expect(phone.operator, MobileOperator.unknown);
      expect(phone.operator.isKnown, isFalse);
    });
  });

  group('nothing outside Market hardcodes country facts', () {
    // The guard that keeps the seam real. It fails the moment someone types a
    // dialling code or a currency literal into a domain file.
    late List<File> domainFiles;

    setUpAll(() {
      final root =
          [
            Directory('lib/src'),
            Directory('packages/bel_domain/lib/src'),
          ].firstWhere(
            (d) => d.existsSync(),
            orElse: () => throw StateError('cannot locate bel_domain/lib/src'),
          );

      domainFiles = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.contains('/market/'))
          // Currency and the prefix table are where these facts are DEFINED.
          .where((f) => !f.path.endsWith('currency.dart'))
          .where((f) => !f.path.endsWith('phone_number.dart'))
          .toList();
    });

    bool _isComment(String line) {
      final t = line.trimLeft();
      return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
    }

    test('no bare dialling code', () {
      final offenders = <String>[];
      for (final f in domainFiles) {
        for (final line in f.readAsStringSync().split('\n')) {
          if (_isComment(line)) continue;
          if (RegExp(r"'\+?24[23]'").hasMatch(line)) {
            offenders.add('${f.path}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'dialling codes belong in Market: $offenders',
      );
    });

    test('no currency code literal', () {
      final offenders = <String>[];
      for (final f in domainFiles) {
        for (final line in f.readAsStringSync().split('\n')) {
          if (_isComment(line)) continue;
          if (RegExp(r"'(XAF|CDF|FCFA)'").hasMatch(line)) {
            offenders.add('${f.path}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'currency belongs in Currency/Market: $offenders',
      );
    });

    test('no carrier name spelled out as prose', () {
      final offenders = <String>[];
      for (final f in domainFiles) {
        for (final line in f.readAsStringSync().split('\n')) {
          if (_isComment(line)) continue;
          if (RegExp(
            r"'(Airtel Money|MTN MoMo|Orange Money)'",
          ).hasMatch(line)) {
            offenders.add('${f.path}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'carrier names come from the catalog: $offenders',
      );
    });
  });
}
