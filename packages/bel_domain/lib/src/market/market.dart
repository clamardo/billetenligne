import '../identity/phone_number.dart';
import '../money/currency.dart';
import '../money/money.dart';
import 'payment_rail.dart';

/// Everything that varies by country, in one place.
///
/// **Launch market is Congo-Brazzaville.** Other countries come later, and
/// this type is the seam that makes "later" cheap.
///
/// The line it draws: we keep country as *configuration* without building
/// *multi-country machinery*. There is no market switcher, no per-market
/// pricing engine, no multi-currency ledger and no cross-border booking —
/// every one of those would be built on guesses about which market comes
/// second.
///
/// ## Adding a country
///
/// 1. Add a [Currency] entry if it is new.
/// 2. Add an [MsisdnPrefixTable] — dialling code, national length, carrier
///    prefixes.
/// 3. Add a [Market] with its [PaymentRail]s.
/// 4. Implement a `PaymentGateway` adapter for any carrier we have not
///    integrated before. Carriers we already speak (Airtel, MTN) reuse theirs.
/// 5. Add city and station catalogue rows, and translate any new strings.
///
/// That is the whole list. No change to booking, holds, the ledger, the
/// payment state machine, ticketing, IRROPS or any screen. `market_test.dart`
/// proves it by standing up a complete second market in test code alone.
final class Market {
  const Market({
    required this.code,
    required this.nameFr,
    required this.nameEn,
    required this.currency,
    required this.msisdn,
    required this.timeZone,
    required this.defaultLanguage,
    required this.languages,
    required this.rails,
    required this.serviceFee,
    this.commissionRate = 0.05,
  });

  /// ISO 3166-1 alpha-2.
  final String code;

  final String nameFr;
  final String nameEn;

  /// XAF here — and it is zero-decimal, which is the most consequential fact
  /// about money in this market.
  final Currency currency;

  /// Dialling code, national length and the carrier-prefix table.
  final MsisdnPrefixTable msisdn;

  final String timeZone;

  /// Falls back to this when the device locale is unsupported. Note this is
  /// deliberately *not* the device locale: a phone shipped with an English
  /// ROM does not mean its owner reads English (ADR-0008).
  final String defaultLanguage;

  final List<String> languages;

  /// Ways to pay, in display order. The compiled-in default; the server sends
  /// the authoritative list at runtime so a rail can be enabled without an app
  /// release (ADR-0006).
  final List<PaymentRail> rails;

  /// Flat booking fee per seat, in this market's currency. Flat, never a
  /// percentage — percentages feel like a tax and are harder to trust.
  final Money serviceFee;

  /// Our cut of the fare on a digital sale, netted at source.
  ///
  /// A market default rather than a per-operator term, and that is a **known
  /// simplification**: an anchor operator will negotiate, and when they do
  /// this moves onto the operator row. It lives here today because one rate
  /// for one operator is not worth a column, and because putting it here
  /// keeps it beside the service fee where anybody costing a booking will
  /// find both.
  ///
  /// A rate, unlike the service fee, because that is how commercial terms in
  /// this industry are actually written — and because it is invisible to the
  /// traveller, who only ever sees a fare and a flat fee. Cash sales carry
  /// none of it at all (product brief D-04).
  final double commissionRate;

  String get diallingCode => msisdn.countryCode;

  Iterable<PaymentRail> get mobileMoneyRails =>
      rails.where((r) => r.kind == PaymentRailKind.mobileMoney);

  PaymentRail? railById(String id) {
    for (final r in rails) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The rail to pre-select for a given number, so the payment screen opens on
  /// the user's own wallet rather than asking them to choose (D-02).
  PaymentRail? railForOperator(MobileOperator operator) {
    for (final r in rails) {
      if (r.enabled && r.operator == operator) return r;
    }
    return null;
  }

  // ── The Republic of Congo ────────────────────────────────────────────────

  static const congoBrazzaville = Market(
    code: 'CG',
    nameFr: 'République du Congo',
    nameEn: 'Republic of the Congo',
    currency: Currency.xaf,
    msisdn: MsisdnPrefixTable.congoBrazzaville,
    timeZone: 'Africa/Brazzaville',
    defaultLanguage: 'fr',
    languages: ['fr', 'en'],
    serviceFee: Money.xaf(300),
    rails: [
      PaymentRail(
        id: 'cg.airtel_money',
        kind: PaymentRailKind.mobileMoney,
        operator: MobileOperator.airtel,
        ussdCode: '*128#',
        minAmount: Money.xaf(100),
        maxAmount: Money.xaf(1000000),
      ),
      PaymentRail(
        id: 'cg.mtn_momo',
        kind: PaymentRailKind.mobileMoney,
        operator: MobileOperator.mtn,
        ussdCode: '*105#',
        minAmount: Money.xaf(100),
        maxAmount: Money.xaf(1000000),
      ),
      // Orange Money is the largest single wallet (~45%) and is a
      // fast-follow, not a launch rail (ADR-0006). Present and disabled, so
      // switching it on is a configuration change rather than a code change —
      // which is the whole point of this file.
      PaymentRail(
        id: 'cg.orange_money',
        kind: PaymentRailKind.mobileMoney,
        operator: MobileOperator.orange,
        ussdCode: '#150#',
        enabled: false,
        disabledReasonKey: 'payment.rail.comingSoon',
      ),
      PaymentRail(id: 'cg.card', kind: PaymentRailKind.card),
      PaymentRail(id: 'cg.cash', kind: PaymentRailKind.cash),
    ],
  );

  /// Every market the platform serves. Exactly one, on purpose.
  static const all = <Market>[congoBrazzaville];

  /// There is no market picker. Until a second country exists, resolution is a
  /// constant — and saying so in code is more honest than a lookup that can
  /// only ever return one answer.
  static const current = congoBrazzaville;

  static Market? byCode(String code) {
    for (final m in all) {
      if (m.code == code.toUpperCase()) return m;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is Market && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => '$code (${currency.code})';
}
