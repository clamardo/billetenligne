import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/booking_store.dart';
import 'ports/operator_directory.dart';
import 'ports/payment_gateway.dart';
import 'ports/payment_store.dart';
import 'ports/reschedule_desk.dart';

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
    RescheduleDesk reschedules = const NoReschedules(),
    this.market = Market.current,
    this.window = const Duration(minutes: 10),
  }) : _payments = payments,
       _bookings = bookings,
       _operators = operators,
       _gateways = gateways,
       _reschedules = reschedules;

  final PaymentStore _payments;
  final BookingStore _bookings;
  final OperatorDirectory _operators;
  final Map<String, PaymentGateway> _gateways;

  /// Where a captured change order goes. A null object by default, so a
  /// composition with no database behind it still pays for bookings.
  final RescheduleDesk _reschedules;
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
    required String? payerMsisdn,
    required String? accountMsisdn,
    required String idempotencyKey,

    /// Where the PSP sends the traveller back to when they are done on a
    /// hosted-checkout rail. Ignored by every push rail, and a hint rather
    /// than authority even here: the money is confirmed by re-querying.
    String? returnUrl,

    /// Set when this pays the difference on a change rather than the journey
    /// itself. Everything after the rail check is identical — the same
    /// prompt, the same window, the same recording — because from the rail's
    /// side it is the same transaction, and from ours the difference lives in
    /// one branch at settlement rather than in a second funnel to maintain.
    String? changeId,
  }) async {
    final gateway = _gateways[railId];
    if (gateway == null) return Err(RailNotAvailable(railId));

    // A card is entered on the PSP's page and this system never sees the
    // number, so there is nothing here to validate and nothing to push to.
    // Asked of the rail rather than switched on its id, so adding an
    // aggregator is a class rather than a string somebody has to remember.
    final checkout = !gateway.pushesToHandset;

    PhoneNumber? payer;
    if (!checkout) {
      final parsed = PhoneNumber.parse(payerMsisdn ?? '', table: market.msisdn);
      if (parsed case Err(:final failure)) {
        return Err(PayerNumberInvalid(failure.reason));
      }
      payer = parsed.valueOrNull!;

      // Checked BEFORE the prompt goes out, and only against rails this
      // market actually describes. A number on the wrong carrier otherwise
      // fails thirty seconds later as a generic decline, and the traveller
      // has no idea it was fixable by switching a toggle.
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
        return const Err(
          RailRefused(PaymentFailureCode.wrongOperatorForMsisdn),
        );
      }
    }

    // Recorded, never enforced. It is the difference between "paid from
    // their own wallet" and "a relative paid", which matters in a dispute and
    // matters not at all to whether the payment may proceed. False on a card,
    // where there is no wallet to compare against.
    final payerIsAccountHolder =
        payer != null && accountMsisdn != null && accountMsisdn == payer.e164;

    final intent = changeId == null
        ? await _payments.open(
            bookingId: bookingId,
            userId: userId,
            railId: railId,
            payerMsisdn: payer?.e164,
            payerIsAccountHolder: payerIsAccountHolder,
            idempotencyKey: idempotencyKey,
            window: window,
            hostedCheckout: checkout,
          )
        : await _payments.openForChange(
            changeId: changeId,
            userId: userId,
            railId: railId,
            payerMsisdn: payer?.e164,
            payerIsAccountHolder: payerIsAccountHolder,
            idempotencyKey: idempotencyKey,
            window: window,
            hostedCheckout: checkout,
          );

    if (intent == null) return const Err(BookingNotPayable());

    // Already in flight or already settled — a retry of the same attempt.
    // Pushing a second prompt would put two PIN requests on one handset.
    if (intent.state != PaymentState.created) return Ok(intent);

    final outcome = await gateway.requestPayment(
      PaymentRequest(
        intentId: intent.id,
        amount: intent.amount,
        payerMsisdn: payer?.e164,
        collectionMsisdn: checkout ? null : intent.collectionMsisdn,
        reference: intent.id.substring(0, 8).toUpperCase(),
        description: 'BilletEnLigne',
        returnUrl: checkout ? returnUrl : null,
      ),
    );

    final recorded = await _payments.recordOutcome(
      intentId: intent.id,
      state: outcome.state,
      source: 'poll',
      raw: outcome.raw,
      failureCode: outcome.failureCode,
      railTransactionId: outcome.railTransactionId,
      // Only a checkout rail answers with one, and only on the first answer.
      checkoutUrl: outcome.checkoutUrl,
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
      await _settleCapture(recorded);
    }

    return recorded;
  }

  /// A human resolves what the rail never did.
  ///
  /// The `indeterminate` queue's only exit, and it exists because these
  /// networks lose answers: after fifteen minutes of silence an intent stops
  /// being "pending" and becomes a thing somebody has to look at. That
  /// somebody has evidence we do not — the operator's merchant statement, a
  /// screenshot of the traveller's wallet, a phone call to the telco — and
  /// this is how their finding gets written down.
  ///
  /// Three properties, each of which is the reason it is not just an UPDATE:
  ///
  ///   * **only `captured` or `failed`.** The domain's transition table says
  ///     an indeterminate intent resolves one way or the other and nowhere
  ///     else, and this path is checked by exactly the same rule as a
  ///     callback;
  ///   * **capturing here settles for real** — ledger, ticket, outbox, the
  ///     operator's own commission — through the same code a rail's answer
  ///     takes. A booking confirmed by an admin and one confirmed by MTN must
  ///     be indistinguishable afterwards, because in the ledger they are;
  ///   * **the actor and the reason are written to `payment_events`**, which
  ///     is append-only and is the only thing that settles a dispute six
  ///     weeks later. The row's source is `manual`; the body names who.
  Future<PaymentIntentRecord?> resolve({
    required String intentId,
    required PaymentState to,
    required String actorUserId,
    required String reason,
    PaymentFailureCode? failureCode,
  }) async {
    if (to != PaymentState.captured && to != PaymentState.failed) return null;

    final recorded = await _payments.recordOutcome(
      intentId: intentId,
      state: to,
      // `manual` is the schema's word for it, and the vocabulary is a CHECK
      // constraint rather than free text on purpose: four sources are
      // greppable in a dispute, an actor id embedded in a source string is
      // not. Who decided goes in the body, where it is queryable as data.
      source: 'manual',
      raw: {'resolvedBy': actorUserId, 'reason': reason},
      failureCode: to == PaymentState.failed
          ? (failureCode ?? PaymentFailureCode.timeoutNoResponse)
          : null,
    );

    if (recorded == null) return null;
    if (recorded.state == PaymentState.captured) await _settleCapture(recorded);
    return recorded;
  }

  /// Which of two things a captured intent means.
  ///
  /// The discriminator is on the row rather than in a flag the caller passes:
  /// a poll, a callback and an admin's resolution all arrive here with
  /// nothing but an intent id, and each of them has to reach the same answer.
  Future<void> _settleCapture(PaymentIntentRecord intent) =>
      intent.isForAChange ? _settleChange(intent) : _settle(intent);

  /// A paid change: the difference has landed, so the booking moves.
  ///
  /// The ledger movement is computed here, beside the one that settles a
  /// booking, and for the same reason — commission is netted at source, at
  /// this operator's own rate, and money maths does not belong in an adapter.
  /// The difference carries no service fee: ours was charged once, on the
  /// sale, and charging it again for moving somebody along the same road
  /// would be a fee for our own convenience.
  Future<void> _settleChange(PaymentIntentRecord intent) async {
    final term =
        await _operators.commissionFor(intent.operatorId) ??
        CommissionTerm.none;

    final posting = Postings.railCapture(
      operatorId: intent.operatorId,
      rail: intent.railId,
      fare: intent.amount,
      serviceFee: Money(0, intent.amount.currency),
      commission: term.on(intent.amount),
    );
    if (posting case Err()) return;

    await _reschedules.applyPaidChange(
      changeId: intent.changeId!,
      intentId: intent.id,
      posting: posting.valueOrNull!,
    );
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
    final term =
        await _operators.commissionFor(intent.operatorId) ??
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
