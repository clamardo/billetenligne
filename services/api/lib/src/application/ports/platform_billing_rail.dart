import 'package:bel_domain/bel_domain.dart';

/// What an operator does next to pay their platform subscription.
///
/// Deliberately not "charge this card". Neither rail moves money on its own
/// today — there is no merchant account behind the card and a bank transfer
/// is a human wiring money outside this system entirely — so what a rail
/// answers with is an instruction, not an outcome. The shape is kept small on
/// purpose: `PaymentGateway` (`payment_gateway.dart`) earns its
/// request/query pair from a real state machine with a poller behind it, and
/// building one here for a rail that does not yet accept traffic would be a
/// state machine with nothing to drive it.
final class PlatformBillingInstruction {
  const PlatformBillingInstruction({
    required this.available,
    this.checkoutUrl,
    this.bankName,
    this.accountName,
    this.accountNumber,
    this.reference,
  });

  /// False when this rail cannot be used yet — a card rail with no Stripe key
  /// behind it, on this deployment, today. Said out loud rather than left to
  /// a null `checkoutUrl`: a screen that cannot tell "not configured" from
  /// "briefly failed" will invite a retry that can never succeed.
  final bool available;

  /// Where to send the operator to pay by card. Set only when [available].
  final String? checkoutUrl;

  /// Our settlement account, read out or wired to. Set only on the
  /// bank-transfer rail.
  final String? bankName;
  final String? accountName;
  final String? accountNumber;

  /// What the operator should put in the transfer's own reference field, so a
  /// human reconciling incoming wires later can tell which operator's month
  /// this one is.
  final String? reference;
}

/// One way to pay the platform. `cg.card`'s sibling for money moving the
/// other way — an operator paying us — rather than a mobile-money rail's,
/// because there is no handset on this side of the transaction at all.
abstract interface class PlatformBillingRail {
  /// `card` | `bank_transfer`. Matches
  /// `platform_billing_accounts.payment_type` and
  /// `platform_subscription_charges.payment_type`.
  String get paymentType;

  /// What the operator should do to pay [amountDue] for this month.
  ///
  /// Never throws for "not configured" — that is [PlatformBillingInstruction
  /// .available], because it is a real, expected state on a deployment with
  /// no Stripe account yet, not a fault.
  Future<PlatformBillingInstruction> instructionsFor({
    required String operatorId,
    required Money amountDue,
    required String reference,
  });
}
