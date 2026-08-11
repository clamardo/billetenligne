import '../policy/refund_policy.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

/// Where a booking stands when somebody presses *Annuler*.
///
/// Three cases rather than the five the schema has, because only three lead
/// anywhere different: nothing has been paid, something has, or there is
/// nothing left to cancel.
enum BookingStanding {
  /// Reserved, with a payment code, and the money never arrived.
  awaitingPayment,

  /// Paid for. There is a ticket, and cancelling owes somebody money.
  paid,

  /// Already cancelled, refunded or expired. Pressing the button again must
  /// be a sentence, not a second refund.
  gone,
}

/// What cancelling will actually do, decided before the screen draws a button.
enum CancellationKind {
  /// Nothing was paid, so nothing comes back. The seats go on sale again and
  /// the reservation ends. This is the common case and it is not a refund.
  release,

  /// A code the traveller shows at one of the operator's counters.
  claimAtCounter,

  /// Back down the rail the money arrived on, inside the policy's window.
  toSource,
}

sealed class CancellationRefusal extends DomainFailure {
  const CancellationRefusal();
}

/// The booking is cancelled, refunded or expired already.
final class NothingToCancel extends CancellationRefusal {
  const NothingToCancel();
  @override
  String get code => 'cancel.nothing_to_cancel';
}

/// The coach has left. Whatever is owed after that is a conversation with the
/// agency, not a button — and a no-show is not a cancellation.
final class CoachHasLeft extends CancellationRefusal {
  const CoachHasLeft();
  @override
  String get code => 'cancel.coach_has_left';
}

/// Money is moving right now.
///
/// A wallet payment sits `pending` while somebody types a PIN on a handset we
/// cannot see. Cancelling underneath it would release the seats a second
/// before the capture arrives, and the traveller would have paid for a
/// booking that no longer exists. The spec's thirty-second rule (§6.2) is the
/// same instinct at the other end of the same window.
final class PaymentInFlight extends CancellationRefusal {
  const PaymentInFlight();
  @override
  String get code => 'cancel.payment_in_flight';
}

/// The operator settles refunds as credit towards a future journey, and a
/// credit note is not something this system issues yet. Refused rather than
/// silently converted to cash the operator never agreed to give.
final class CancellationNeedsTheAgency extends CancellationRefusal {
  const CancellationNeedsTheAgency();
  @override
  String get code => 'cancel.needs_the_agency';
}

/// Which of the three a cancellation is.
///
/// **Cash is the rule worth spelling out.** A booking paid in notes at a
/// counter has no source to send anything back to, whatever the policy's
/// destination field says — so it ends at a counter, and the screen says so
/// before anybody taps. A policy field that describes card and wallet
/// journeys is not evidence about a journey that never had one.
Result<CancellationKind, CancellationRefusal> cancellationKind({
  required BookingStanding standing,
  required bool paidInCash,
  required RefundDestination destination,
  required DateTime departsAt,
  required DateTime now,
  bool paymentInFlight = false,
}) {
  if (standing == BookingStanding.gone) return const Err(NothingToCancel());

  // Before the payment question, because a departed coach is the same answer
  // whether or not anybody paid, and it is the more useful sentence.
  if (!departsAt.isAfter(now)) return const Err(CoachHasLeft());

  if (paymentInFlight) return const Err(PaymentInFlight());

  if (standing == BookingStanding.awaitingPayment) {
    return const Ok(CancellationKind.release);
  }

  if (destination == RefundDestination.creditNote) {
    return const Err(CancellationNeedsTheAgency());
  }

  if (paidInCash ||
      destination == RefundDestination.agencyCash ||
      destination == RefundDestination.travellerChoice) {
    return const Ok(CancellationKind.claimAtCounter);
  }

  return const Ok(CancellationKind.toSource);
}

/// Whether the traveller should be warned that cancelling costs them
/// everything.
///
/// A policy whose bands have all elapsed does not refuse the cancellation —
/// somebody who knows they cannot travel would rather free the seat than
/// no-show, and hiding the button does not give them their money back. What
/// it changes is the sentence above it, which has to say *nothing comes back*
/// in those words rather than showing `0 FCFA` and hoping it is read.
bool cancellingCostsEverything(Result<RefundQuote, RefundFailure> quote) =>
    switch (quote) {
      Err() => true,
      Ok(:final value) => value.refundable.minor == 0,
    };
