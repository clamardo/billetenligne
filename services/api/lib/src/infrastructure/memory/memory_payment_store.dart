import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/payment_store.dart';
import 'memory_booking_store.dart';

/// Payments in a map, for the fakes composition and the unit suite.
///
/// One fake rail with one collection account, so a fresh clone can walk the
/// whole funnel — including the failure screens, which are the states that
/// otherwise ship untested because nobody sees them in development.
///
/// It is a faithful twin in the ways that decide behaviour: the same
/// idempotency key returns the same intent, an illegal transition is refused
/// rather than applied, and a transition that loses a race keeps the winner.
/// It is honestly not a twin in the way that matters most — there is no
/// transaction here, so "the ledger, the ticket and the confirmation together
/// or not at all" is proven against real Postgres and nowhere else.
final class MemoryPaymentStore implements PaymentStore {
  MemoryPaymentStore({
    required MemoryBookingStore bookings,
    Clock clock = const SystemClock(),
  }) : _bookings = bookings,
       _clock = clock;

  final MemoryBookingStore _bookings;
  final Clock _clock;

  final Map<String, PaymentIntentRecord> _byId = {};
  final Map<String, String> _byKey = {};

  /// Every raw payload, in order. The fake's `payment_events`.
  final List<({String intentId, String source, Map<String, Object?> raw})>
  events = [];

  var _next = 0;

  /// Verified accounts, one per rail. Overridable so a test can prove the
  /// "operator has no verified account" refusal.
  ///
  /// Orange Money is here as well as the fake wallet because it is the one
  /// rail that is mobile money **and** a hosted checkout, and a demo without
  /// it leaves that combination unexercised by every screen that runs on
  /// fakes — which is every screen on a fresh clone.
  List<CollectionAccount> accounts = const [
    CollectionAccount(
      railId: 'cg.fake_money',
      msisdn: '242060000001',
      displayName: 'Ocean du Nord',
      verified: true,
    ),
    CollectionAccount(
      railId: 'cg.orange_money',
      msisdn: '242060000002',
      displayName: 'Ocean du Nord',
      verified: true,
    ),
  ];

  @override
  Future<List<CollectionAccount>> collectionAccounts(String operatorId) async =>
      accounts;

  @override
  Future<PaymentIntentRecord?> open({
    required String bookingId,
    required String userId,
    required String railId,
    required String? payerMsisdn,
    required bool payerIsAccountHolder,
    required String idempotencyKey,
    required Duration window,
    bool hostedCheckout = false,
  }) async {
    // A retry of the same attempt returns the SAME intent. Two prompts on one
    // handset is the failure this prevents.
    final existingId = _byKey[idempotencyKey];
    if (existingId != null) return _byId[existingId];

    final booking = await _bookings.byIdUnscoped(bookingId);
    if (booking == null || booking.state != 'pending_payment') return null;

    // A card has no collection account: the money lands in the PSP's
    // merchant account rather than a wallet the operator holds, and requiring
    // a row here would mean no operator could ever be paid by card.
    final account = accounts
        .where((a) => a.railId == railId && a.verified)
        .firstOrNull;
    if (account == null && !hostedCheckout) return null;

    final intent = PaymentIntentRecord(
      id: 'pi-mem-${++_next}',
      bookingId: bookingId,
      operatorId: booking.operatorId,
      railId: railId,
      amount: booking.total,
      state: PaymentState.created,
      payerMsisdn: payerMsisdn ?? '',
      collectionMsisdn: account?.msisdn ?? '',
      createdAt: _clock.now(),
      expiresAt: _clock.now().add(window),
    );

    _byId[intent.id] = intent;
    _byKey[idempotencyKey] = intent.id;
    return intent;
  }

  /// Change orders this fake knows how to be paid for, by id.
  ///
  /// Empty by default, and deliberately: the fakes composition has no
  /// reschedule desk, so a change order cannot exist in it. A test that wants
  /// the paid-change path registers one here; the real thing is proven
  /// against Postgres, where the order and the seats it holds are rows.
  final Map<String, ({String bookingId, String operatorId, Money owed})>
  changeOrders = {};

  @override
  Future<PaymentIntentRecord?> openForChange({
    required String changeId,
    required String userId,
    required String railId,
    required String? payerMsisdn,
    required bool payerIsAccountHolder,
    required String idempotencyKey,
    required Duration window,
    bool hostedCheckout = false,
  }) async {
    final existingId = _byKey[idempotencyKey];
    if (existingId != null) return _byId[existingId];

    final order = changeOrders[changeId];
    if (order == null) return null;

    final account = accounts
        .where((a) => a.railId == railId && a.verified)
        .firstOrNull;
    if (account == null && !hostedCheckout) return null;

    final intent = PaymentIntentRecord(
      id: 'pi-mem-${++_next}',
      bookingId: order.bookingId,
      operatorId: order.operatorId,
      railId: railId,
      amount: order.owed,
      state: PaymentState.created,
      payerMsisdn: payerMsisdn ?? '',
      collectionMsisdn: account?.msisdn ?? '',
      createdAt: _clock.now(),
      expiresAt: _clock.now().add(window),
      changeId: changeId,
    );

    _byId[intent.id] = intent;
    _byKey[idempotencyKey] = intent.id;
    return intent;
  }

  @override
  Future<PaymentIntentRecord?> byId({
    required String intentId,
    required String userId,
  }) async => _byId[intentId];

  @override
  Future<PaymentIntentRecord?> recordOutcome({
    required String intentId,
    required PaymentState state,
    required String source,
    required Map<String, Object?> raw,
    PaymentFailureCode? failureCode,
    String? railTransactionId,
    String? checkoutUrl,
  }) async {
    // Written first and unconditionally, like the real store: whether the
    // transition is legal is a separate question, and an illegal one is
    // exactly the event a dispute turns on.
    events.add((intentId: intentId, source: source, raw: raw));

    final current = _byId[intentId];
    if (current == null) return null;

    final intent = PaymentIntent(
      id: current.id,
      bookingId: current.bookingId,
      railId: current.railId,
      amount: current.amount,
      state: current.state,
      createdAt: current.createdAt,
      idempotencyKey: current.id,
    );

    // An out-of-order callback arriving after a capture is a NORMAL event on
    // these rails. Keep the capture and say so.
    // Kept from the first answer, like the real store: a second URL for one
    // intent is a second transaction at the PSP.
    final url = current.checkoutUrl ?? checkoutUrl;

    if (intent.transitionTo(state, now: _clock.now(), failureCode: failureCode)
        case Err()) {
      return _byId[intentId] = _withUrl(current, url);
    }

    final updated = PaymentIntentRecord(
      id: current.id,
      bookingId: current.bookingId,
      operatorId: current.operatorId,
      railId: current.railId,
      amount: current.amount,
      state: state,
      payerMsisdn: current.payerMsisdn,
      collectionMsisdn: current.collectionMsisdn,
      createdAt: current.createdAt,
      expiresAt: current.expiresAt,
      failureCode: failureCode ?? current.failureCode,
      railTransactionId: railTransactionId ?? current.railTransactionId,
      changeId: current.changeId,
      checkoutUrl: url,
    );

    _byId[intentId] = updated;
    return updated;
  }

  /// The same record with a checkout URL on it. There is no `copyWith` on
  /// `PaymentIntentRecord` and one field does not earn one.
  static PaymentIntentRecord _withUrl(PaymentIntentRecord r, String? url) =>
      PaymentIntentRecord(
        id: r.id,
        bookingId: r.bookingId,
        operatorId: r.operatorId,
        railId: r.railId,
        amount: r.amount,
        state: r.state,
        payerMsisdn: r.payerMsisdn,
        collectionMsisdn: r.collectionMsisdn,
        createdAt: r.createdAt,
        expiresAt: r.expiresAt,
        failureCode: r.failureCode,
        railTransactionId: r.railTransactionId,
        changeId: r.changeId,
        checkoutUrl: url,
      );

  @override
  Future<List<PaymentIntentRecord>> inFlight({int limit = 100}) async =>
      _byId.values.where((i) => i.state.isInFlight).take(limit).toList();

  @override
  Future<void> markPolled(String intentId) async {}
}
