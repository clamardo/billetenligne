import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// A payment rail as the server advertises it.
///
/// The client **never hardcodes a rail list** — it renders whatever this
/// returns. That is what lets us enable Orange Money, or fix a renumbered
/// carrier prefix, without an app release (ADR-0006), which matters because a
/// meaningful share of users in this market never update.
final class PaymentRailDto {
  const PaymentRailDto({
    required this.id,
    required this.kind,
    required this.labelKey,
    this.operatorId,
    this.ussdCode,
    this.minAmount,
    this.maxAmount,
    this.enabled = true,
    this.disabledReasonKey,
    this.logoAsset,
  });

  final String id;
  final String kind;
  final String labelKey;
  final String? operatorId;

  /// Shown on the waiting screen when the push prompt does not arrive.
  final String? ussdCode;

  final Money? minAmount;
  final Money? maxAmount;
  final bool enabled;

  /// A disabled tile always explains itself. A grey box with no reason is a
  /// support ticket.
  final String? disabledReasonKey;

  final String? logoAsset;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'kind': kind,
    'labelKey': labelKey,
    'operatorId': operatorId,
    'ussdCode': ussdCode,
    'minAmount': minAmount == null ? null : Wire.money(minAmount!),
    'maxAmount': maxAmount == null ? null : Wire.money(maxAmount!),
    'enabled': enabled,
    'disabledReasonKey': disabledReasonKey,
    'logoAsset': logoAsset,
  });

  factory PaymentRailDto.fromJson(Map<String, Object?> json) => PaymentRailDto(
    id: Wire.requireString(json['id'], 'id'),
    kind: Wire.requireString(json['kind'], 'kind'),
    labelKey: Wire.requireString(json['labelKey'], 'labelKey'),
    operatorId: json['operatorId'] as String?,
    ussdCode: json['ussdCode'] as String?,
    minAmount: json['minAmount'] == null
        ? null
        : Wire.readMoney(json['minAmount'], field: 'minAmount'),
    maxAmount: json['maxAmount'] == null
        ? null
        : Wire.readMoney(json['maxAmount'], field: 'maxAmount'),
    enabled: json['enabled'] as bool? ?? true,
    disabledReasonKey: json['disabledReasonKey'] as String?,
    logoAsset: json['logoAsset'] as String?,
  );

  factory PaymentRailDto.fromDomain(PaymentRail rail) => PaymentRailDto(
    id: rail.id,
    kind: rail.kind.name,
    labelKey: rail.labelKey,
    operatorId: rail.operator?.id,
    ussdCode: rail.ussdCode,
    minAmount: rail.minAmount,
    maxAmount: rail.maxAmount,
    enabled: rail.enabled,
    disabledReasonKey: rail.disabledReasonKey,
  );
}

/// The market the client is operating in, fetched at startup and cached.
///
/// Carries everything country-varying: currency, dialling code, carrier
/// prefixes, rails, service fee. Adding a country is a new row behind this
/// endpoint — the client needs no change at all.
final class MarketDto {
  const MarketDto({
    required this.code,
    required this.nameKey,
    required this.currency,
    required this.currencyExponent,
    required this.diallingCode,
    required this.nationalLength,
    required this.carrierPrefixes,
    required this.timeZone,
    required this.defaultLanguage,
    required this.languages,
    required this.serviceFee,
    required this.rails,
    this.signInChannels = const ['email'],
  });

  final String code;
  final String nameKey;
  final String currency;

  /// Sent explicitly so a client never has to know that XAF is zero-decimal.
  /// Hardcoding that assumption is how a 9 000 XAF fare becomes 90 XAF.
  final int currencyExponent;

  final String diallingCode;
  final int nationalLength;

  /// Prefix to carrier id. Data, so a renumbering is a config push.
  final Map<String, String> carrierPrefixes;

  final String timeZone;
  final String defaultLanguage;
  final List<String> languages;
  final Money serviceFee;
  final List<PaymentRailDto> rails;

  /// Which sign-in channels this deployment can actually deliver on —
  /// `email`, `phone`, or both.
  ///
  /// Announced rather than compiled in, for the same reason the rails are
  /// (ADR-0006): switching SMS on is a provisioned sender number and a config
  /// push, and an app that decided for itself would need a release on the day
  /// the number arrives — in a market where many users never update.
  ///
  /// It is also the honest version of the current state. Phone is plumbed end
  /// to end and switched off for want of a sender; the app says so because
  /// the server said so, rather than because somebody hardcoded a sentence
  /// that will be wrong the week it changes.
  final List<String> signInChannels;

  bool get canSignInByPhone => signInChannels.contains('phone');

  /// Which rail to pre-select for a number, so the payment screen opens on
  /// the user's own wallet (D-02).
  PaymentRailDto? railForNational(String nationalNumber) {
    for (var len = 3; len >= 2; len--) {
      if (nationalNumber.length < len) continue;
      final carrier = carrierPrefixes[nationalNumber.substring(0, len)];
      if (carrier == null) continue;
      for (final r in rails) {
        if (r.enabled && r.operatorId == carrier) return r;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'code': code,
    'nameKey': nameKey,
    'currency': currency,
    'currencyExponent': currencyExponent,
    'diallingCode': diallingCode,
    'nationalLength': nationalLength,
    'carrierPrefixes': carrierPrefixes,
    'timeZone': timeZone,
    'defaultLanguage': defaultLanguage,
    'languages': languages,
    'serviceFee': Wire.money(serviceFee),
    'rails': [for (final r in rails) r.toJson()],
    'signInChannels': signInChannels,
  };

  factory MarketDto.fromJson(Map<String, Object?> json) => MarketDto(
    code: Wire.requireString(json['code'], 'code'),
    nameKey: Wire.requireString(json['nameKey'], 'nameKey'),
    currency: Wire.requireString(json['currency'], 'currency'),
    currencyExponent: Wire.requireInt(
      json['currencyExponent'],
      'currencyExponent',
    ),
    diallingCode: Wire.requireString(json['diallingCode'], 'diallingCode'),
    nationalLength: Wire.requireInt(json['nationalLength'], 'nationalLength'),
    carrierPrefixes:
        (json['carrierPrefixes'] as Map?)?.cast<String, String>() ?? const {},
    timeZone: Wire.requireString(json['timeZone'], 'timeZone'),
    defaultLanguage: Wire.requireString(
      json['defaultLanguage'],
      'defaultLanguage',
    ),
    languages: (json['languages'] as List?)?.cast<String>() ?? const ['fr'],
    serviceFee: Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
    rails: Wire.readList(
      json['rails'],
      PaymentRailDto.fromJson,
      field: 'rails',
    ),
    // Defaulted rather than required, so a client built against a newer
    // contract still reads an older server's answer. Email is the channel
    // that has always worked.
    signInChannels:
        (json['signInChannels'] as List?)?.cast<String>() ?? const ['email'],
  );

  factory MarketDto.fromDomain(Market m, {List<String>? signInChannels}) =>
      MarketDto(
        code: m.code,
        nameKey: m.nameKey,
        currency: m.currency.code,
        currencyExponent: m.currency.exponent,
        diallingCode: m.diallingCode,
        nationalLength: m.msisdn.nationalLength,
        carrierPrefixes: {
          for (final e in m.msisdn.prefixes.entries) e.key: e.value.id,
        },
        timeZone: m.timeZone,
        defaultLanguage: m.defaultLanguage,
        languages: m.languages,
        serviceFee: m.serviceFee,
        rails: [for (final r in m.rails) PaymentRailDto.fromDomain(r)],
        // Not a property of the market — a property of this deployment. The
        // domain knows Congo-Brazzaville prefers SMS; only composition knows
        // whether we have a sender number today.
        signInChannels: signInChannels ?? const ['email'],
      );
}
