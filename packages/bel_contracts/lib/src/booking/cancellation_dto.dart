import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// What cancelling this booking will do, before anybody taps (§8.2).
///
/// Deliberately *not* [RefundOfferDto], which is the counter's question about
/// somebody else's booking. This is the traveller's own screen, and the two
/// differ in the fact that matters most: the common case here is a
/// reservation nobody ever paid for, where "refund" is the wrong word and a
/// quote of zero is the wrong shape.
final class CancellationOfferDto {
  const CancellationOfferDto({
    required this.bookingRef,
    required this.kind,
    required this.departsAt,
    required this.originCity,
    required this.destinationCity,
    required this.seatCount,
    required this.fare,
    required this.serviceFee,
    this.refundable,
    this.retained,
    this.rateBps,
    this.processingHours,
    this.givesNothingBack = false,
    this.policyName,
    this.policyLines = const [],
    this.refusalCode,
  });

  final String bookingRef;

  /// `release` · `claimAtCounter` · `toSource`, from the domain. Null when
  /// [refusalCode] is set, because a cancellation that cannot happen has no
  /// kind.
  final String? kind;

  final DateTime departsAt;
  final String originCity;
  final String destinationCity;

  /// How many people. Cancelling a family of four is one tap and four seats,
  /// and the screen has to say four.
  final int seatCount;

  final Money fare;
  final Money serviceFee;

  /// What comes back. Zero is a real answer here, not a missing one — the
  /// bands may all have elapsed — and [givesNothingBack] is what the screen
  /// reads rather than comparing to zero itself.
  final Money? refundable;
  final Money? retained;
  final int? rateBps;

  /// The window the money arrives in, for a refund that is sent rather than
  /// collected. `sous 72 heures` and never an instant (§8.2).
  final int? processingHours;

  final bool givesNothingBack;

  final String? policyName;

  /// The terms as `key|arg` lines, the same sentences shown before purchase.
  final List<String> policyLines;

  /// Set when cancelling is refused outright. The screen renders the reason
  /// and no button.
  final String? refusalCode;

  bool get isPossible => refusalCode == null && kind != null;

  /// Whether anything is owed at all. False for a reservation nobody paid
  /// for, which is the case that must not say "remboursement".
  bool get owesMoney => kind == 'claimAtCounter' || kind == 'toSource';

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'kind': kind,
    'departsAt': Wire.instant(departsAt),
    'originCity': originCity,
    'destinationCity': destinationCity,
    'seatCount': seatCount,
    'fare': Wire.money(fare),
    'serviceFee': Wire.money(serviceFee),
    'refundable': refundable == null ? null : Wire.money(refundable!),
    'retained': retained == null ? null : Wire.money(retained!),
    'rateBps': rateBps,
    'processingHours': processingHours,
    'givesNothingBack': givesNothingBack,
    'policyName': policyName,
    'policyLines': policyLines,
    'refusalCode': refusalCode,
  });

  factory CancellationOfferDto.fromJson(Map<String, Object?> json) =>
      CancellationOfferDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        kind: json['kind'] as String?,
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        seatCount: json['seatCount'] as int? ?? 1,
        fare: Wire.readMoney(json['fare'], field: 'fare'),
        serviceFee: Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
        refundable: json['refundable'] == null
            ? null
            : Wire.readMoney(json['refundable'], field: 'refundable'),
        retained: json['retained'] == null
            ? null
            : Wire.readMoney(json['retained'], field: 'retained'),
        rateBps: json['rateBps'] as int?,
        processingHours: json['processingHours'] as int?,
        givesNothingBack: json['givesNothingBack'] as bool? ?? false,
        policyName: json['policyName'] as String?,
        policyLines: [
          for (final line in (json['policyLines'] as List? ?? const []))
            '$line',
        ],
        refusalCode: json['refusalCode'] as String?,
      );
}

/// The receipt. What happened, and what the traveller has to do next.
final class CancellationDoneDto {
  const CancellationDoneDto({
    required this.bookingRef,
    required this.kind,
    this.refunded,
    this.claimCode,
    this.claimExpiresAt,
    this.processingHours,
  });

  final String bookingRef;
  final String kind;

  /// Null on a release: nothing was paid, so nothing comes back.
  final Money? refunded;

  /// The six characters shown at a counter. Sent by SMS as well, because a
  /// code that only ever existed on one screen is a code somebody loses.
  final String? claimCode;
  final DateTime? claimExpiresAt;

  final int? processingHours;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'kind': kind,
    'refunded': refunded == null ? null : Wire.money(refunded!),
    'claimCode': claimCode,
    'claimExpiresAt': claimExpiresAt == null
        ? null
        : Wire.instant(claimExpiresAt!),
    'processingHours': processingHours,
  });

  factory CancellationDoneDto.fromJson(Map<String, Object?> json) =>
      CancellationDoneDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        kind: Wire.requireString(json['kind'], 'kind'),
        refunded: json['refunded'] == null
            ? null
            : Wire.readMoney(json['refunded'], field: 'refunded'),
        claimCode: json['claimCode'] as String?,
        claimExpiresAt: json['claimExpiresAt'] == null
            ? null
            : Wire.readInstant(json['claimExpiresAt'], field: 'claimExpiresAt'),
        processingHours: json['processingHours'] as int?,
      );
}
