import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// What an operator owes the platform this month, and how to pay it
/// (`04-payments.md` §6.2 note).
///
/// One flat tier at launch, so there is no plan to choose between — only an
/// amount, a payment type, and whatever that rail needs shown: a checkout
/// link, or our own settlement account.
final class PlatformBillingDto {
  const PlatformBillingDto({
    required this.operatorId,
    required this.periodStart,
    required this.periodEnd,
    required this.amountDue,
    required this.status,
    required this.paymentType,
    required this.available,
    this.checkoutUrl,
    this.bankName,
    this.bankAccountName,
    this.bankAccountNumber,
    this.reference,
  });

  final String operatorId;

  /// Half-open, `[periodStart, periodEnd)`.
  final DateTime periodStart;
  final DateTime periodEnd;

  final Money amountDue;

  /// `due` | `paid`.
  final String status;

  /// `card` | `bank_transfer` — a live preference, not a fact recorded on
  /// the charge: there is no automatic capture behind either rail yet, so
  /// this is simply whichever one the operator most recently chose.
  final String paymentType;

  /// False when [paymentType] cannot be used yet — a card rail with no
  /// Stripe key behind it on this deployment, today. The console shows a
  /// sentence rather than a broken button when this is false.
  final bool available;

  /// Set only when [paymentType] is `card` and [available].
  final String? checkoutUrl;

  /// Set only when [paymentType] is `bank_transfer`.
  final String? bankName;
  final String? bankAccountName;
  final String? bankAccountNumber;

  /// What to put in the transfer's own reference field, or to quote when
  /// paying by card.
  final String? reference;

  Map<String, Object?> toJson() => Wire.compact({
    'operatorId': operatorId,
    'periodStart': Wire.instant(periodStart),
    'periodEnd': Wire.instant(periodEnd),
    'amountDue': Wire.money(amountDue),
    'status': status,
    'paymentType': paymentType,
    'available': available,
    'checkoutUrl': checkoutUrl,
    'bankName': bankName,
    'bankAccountName': bankAccountName,
    'bankAccountNumber': bankAccountNumber,
    'reference': reference,
  });

  factory PlatformBillingDto.fromJson(Map<String, Object?> json) =>
      PlatformBillingDto(
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        periodStart: Wire.readInstant(
          json['periodStart'],
          field: 'periodStart',
        ),
        periodEnd: Wire.readInstant(json['periodEnd'], field: 'periodEnd'),
        amountDue: Wire.readMoney(json['amountDue'], field: 'amountDue'),
        status: Wire.requireString(json['status'], 'status'),
        paymentType: Wire.requireString(json['paymentType'], 'paymentType'),
        available: json['available'] as bool? ?? false,
        checkoutUrl: json['checkoutUrl'] as String?,
        bankName: json['bankName'] as String?,
        bankAccountName: json['bankAccountName'] as String?,
        bankAccountNumber: json['bankAccountNumber'] as String?,
        reference: json['reference'] as String?,
      );
}

/// Changing which rail an operator intends to pay their platform fee with.
final class SetBillingPaymentTypeRequest {
  const SetBillingPaymentTypeRequest({required this.paymentType});

  /// `card` | `bank_transfer`.
  final String paymentType;

  Map<String, Object?> toJson() => {'paymentType': paymentType};

  factory SetBillingPaymentTypeRequest.fromJson(Map<String, Object?> json) =>
      SetBillingPaymentTypeRequest(
        paymentType: Wire.requireString(json['paymentType'], 'paymentType'),
      );
}
