import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/booking_store.dart';
import 'ports/operator_directory.dart';
import 'ports/payment_gateway.dart';
import 'ports/payment_store.dart';

sealed class PaymentFailure extends DomainFailure {
  const PaymentFailure();
}

/// The booking is not payable — not theirs, already paid, or the operator has
/// no verified collection account on this rail.
///
/// One failure for three causes. None is actionable by the client beyond
/// "choose again", and distinguishing them would say whose booking it is.
final class BookingNotPayable extends PaymentFailure {
  const BookingNotPayable();
  @override
  String get code => ErrorCode.notFound;
}

final class PayerNumberInvalid extends PaymentFailure {
  const PayerNumberInvalid(this.reason);
  final String reason;
  @override
  String get code => ErrorCode.phoneInvalid;
  @override
  Map<String, Object?> get params => {'reason': reason};
}

final class RailNotAvailable extends PaymentFailure {
  const RailNotAvailable(this.railId);
  final String railId;
  @override
  String get code => ErrorCode.paymentRailDisabled;
  @override
  Map<String, Object?> get params => {'rail': railId};
}

final class RailRefused extends PaymentFailure {
  const RailRefused(this.failureCode);
  final PaymentFailureCode failureCode;
  @override
  String get code => failureCode.wire;
}

/// Paying for a booking with mobile money.
///
/// The asynchrony lives here and stops here (ADR-0005). Above this line a
/// booking is `pending_payment` and then `confirmed`; below it, a prompt goes
/// to a handset, somebody types a PIN in a menu we do not control, and the
/// answer arrives by callback or by poll or not at all.
///
/// Four rules, and each of them is a thing that goes wrong in production:
///
///   * **The ticket is issued on `captured`, never on `pending`.** No
///     optimistic issuance, ever — a ticket that exists before the money
///     moved is a free journey.
///   * **The payer number need not be the traveller's.** Somebody whose
///     wallet is empty pays from a relative's, standing next to them. The
///     obvious validation breaks the most common way a ticket gets paid for
///     in this market.
///   * **The rail is chosen, then checked against the number.** A number that
///     does not belong to the chosen carrier is a specific, recoverable
///     failure with its own message — not a generic decline thirty seconds
///     later.
///   * **A lost answer is `pending`, not `failed`.** The money may have moved.
final class PayForBooking {
  const PayForBooking({
    required PaymentStore payments,
    required BookingStore bookings,
    required OperatorDirectory operators,
    required Map<String, PaymentGateway> gateways,
    this.market = Market.current,
    this.window = const Duration(minutes: 10),
  }) : _payments = payments,
       _bookings = bookings,
       _operators = operators,
       _gateways = gateways;

  final PaymentStore _payments;
  final BookingStore _bookings;
  final OperatorDirectory _operators;
  final Map<String, PaymentGateway> _gateways;
  final Market market;

  /// Ten minutes. **Strictly shorter than the seat hold's fifteen** (ADR-0005
  /// rule 5): the hold must expire *after* the payment window, never before,
  /// or a seat is sold out from under somebody who is entering their PIN.
  final Duration window;

  /// What this booking can be paid with.
  Future<List<CollectionAccount>> railsFor(String operatorId) =>
      _payments.collectionAccounts(operatorId);

  Future<Result<PaymentIntentRecord, PaymentFailure>> start({
    required String bookingId,
    required String userId,
    required String railId,
    required String payerMsisdn,
    required String? accountMsisdn,
    required String idempotencyKey,
  }) async {
    final gateway = _gateways[railId];
    if (gateway == null) return Err(RailNotAvailable(railId));

    final parsed = PhoneNumber.parse(payerMsisdn, table: market.msisdn);
    if (parsed case Err(:final failure)) {
      return Err(PayerNumberInvalid(failure.reason));
    }
    final payer = parsed.valueOrNull!;

    // Checked BEFORE the prompt goes out, and only against rails this market
    // actually describes. A number on the wrong carrier otherwise fails
    // thirty seconds later as a generic decline, and the traveller has no
    // idea it was fixable by switching a toggle.
    //
    // Scoped to known rails because the market's prefix table is what makes
    // the claim: for a rail it has never heard of — the fake one, or an
    // aggregator added by configuration — we cannot say a number is on the
    // wrong carrier, and guessing would refuse payments that would have
    // worked. That rail decides for itself.
    final requested = market.rails.where((r) => r.id == railId).firstOrNull;
    if (requested?.operator != null &&
        payer.operator != MobileOperator.unknown &&
        requested!.operator != payer.operator) {
      return const Err(RailRefused(PaymentFailureCode.wrongOperatorForMsisdn));
    }

    final intent = await _payments.open(
      bookingId: bookingId,
      userId: userId,
      railId: railId,
      payerMsisdn: payer.e164,
      // Recorded, never enforced. It is the difference between "paid from
      // their own wallet" and "a relative paid", which matters in a dispute
      // and matters not at all to whether the payment may proceed.
      payerIsAccountHolder: accountMsisdn != null && accountMsisdn == payer.e164,
      idempotencyKey: idempotencyKey,
      window: window,
    );

    if (intent == null) return const Err(BookingNotPayable());

    // Already in flight or already settled — a retry of the same attempt.
    // Pushing a second prompt would put two PIN requests on one handset.
    if (intent.state != PaymentState.created) return Ok(intent);

    final outcome = await gateway.requestPayment(
      PaymentRequest(
        intentId: intent.id,
        amount: intent.amount,
        payerMsisdn: payer.e164,
        collectionMsisdn: intent.collectionMsisdn,
        reference: intent.id.substring(0, 8).toUpperCase(),
        description: 'BilletEnLigne',
      ),
    );

    final recorded = await _payments.recordOutcome(
      intentId: intent.id,
      state: outcome.state,
      source: 'poll',
      raw: outcome.raw,
      failureCode: outcome.failureCode,
      railTransactionId: outcome.railTransactionId,
    );

    final settled = recorded ?? intent;

    if (settled.state == PaymentState.failed && settled.failureCode != null) {
      return Err(RailRefused(settled.failureCode!));
    }

    return Ok(settled);
  }

  /// Asks the rail, records what it said, and confirms the booking if the
  /// money moved.
  ///
  /// Called by the poller, and by the callback handler **after** it has
  /// verified the callback — a callback is untrusted input, so we re-query for
  /// authoritative status rather than mutating state from its body (ADR-0005
  /// rule 4).
  Future<PaymentIntentRecord?> reconcile({
    required String intentId,
    required String railId,
    String? railTransactionId,
    String source = 'poll',
  }) async {
    final gateway = _gateways[railId];
    if (gateway == null) return null;

    final outcome = await gateway.queryStatus(
      intentId: intentId,
      railTransactionId: railTransactionId,
    );

    final recorded = await _payments.recordOutcome(
      intentId: intentId,
      state: outcome.state,
      source: source,
      raw: outcome.raw,
      failureCode: outcome.failureCode,
      railTransactionId: outcome.railTransactionId,
    );

    if (recorded == null) return null;

    // The one place a booking becomes confirmed by mobile money. Idempotent:
    // `captureRail` is conditional on `pending_payment`, so a duplicate
    // callback and a poll arriving together produce one confirmation, one set
    // of ledger rows and one ticket.
    if (recorded.state == PaymentState.captured) {
      await _settle(recorded);
    }

    return recorded;
  }

  Future<void> _settle(PaymentIntentRecord intent) async {
    final booking = await _bookings.byId(
      bookingId: intent.bookingId,
      operatorId: intent.operatorId,
    );
    if (booking == null || booking.isConfirmed) return;

    // Commission netted at source: the operator is credited the fare less our
    // cut rather than credited in full and invoiced later. An operator who has
    // to be invoiced is one who eventually does not pay.
    //
    // **The rate is this operator's, not the market's.** It is a term of the
    // contract we signed with them, read from their row at the moment the
    // money moves.
    //
    // If we cannot read it, we keep nothing. The money has already moved by
    // the time this runs, so refusing to settle would leave a traveller who
    // paid without a ticket — never an option. Crediting the operator the
    // whole fare costs us our cut on one sale and is visible in the ledger;
    // inventing a rate would take money from somebody under an agreement they
    // never made, and would be invisible.
    final term = await _operators.commissionFor(intent.operatorId) ??
        CommissionTerm.none;
    final commission = term.on(booking.fare);

    final posting = Postings.railCapture(
      operatorId: intent.operatorId,
      rail: intent.railId,
      fare: booking.fare,
      serviceFee: booking.serviceFee,
      commission: commission,
    );

    if (posting case Err()) return;

    await _bookings.captureRail(
      bookingId: intent.bookingId,
      operatorId: intent.operatorId,
      railId: intent.railId,
      intentId: intent.id,
      posting: posting.valueOrNull!,
    );
  }
}
