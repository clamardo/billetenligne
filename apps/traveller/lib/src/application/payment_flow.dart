import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/travel_gateway.dart';

/// Where the traveller is in paying.
sealed class PaymentStep {
  const PaymentStep();
}

final class LoadingOptions extends PaymentStep {
  const LoadingOptions();
}

/// Choosing a wallet and the number to pull from.
///
/// One screen, not two. Choosing a carrier and typing a number are the same
/// decision — the number determines the carrier for most people — and
/// splitting them adds a tap to every single payment to serve the minority
/// who pay from somebody else's wallet.
final class ChoosingMethod extends PaymentStep {
  const ChoosingMethod({
    required this.options,
    required this.amount,
    required this.selected,
    required this.payerMsisdn,
    this.accountMsisdn,
    this.failure,
  });

  final List<PaymentOptionDto> options;
  final Money amount;
  final PaymentOptionDto? selected;
  final String payerMsisdn;

  /// The traveller's own number, prefilled. They can replace it — and the
  /// screen says so, because somebody paying from a relative's wallet needs
  /// to know it is allowed.
  final String? accountMsisdn;

  final ApiFailure? failure;

  bool get payingFromOwnNumber =>
      accountMsisdn != null && _digits(payerMsisdn) == _digits(accountMsisdn!);

  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');
}

/// The last screen before the money moves.
///
/// **A separate step on purpose.** Everything on it — the amount, the wallet,
/// the number the money leaves, the number it arrives at, and the operator's
/// name beside that number — is checkable before anything irreversible
/// happens. Skipping this screen saves a tap and costs the trust that makes
/// somebody pay by phone at all.
final class ConfirmingPayment extends PaymentStep {
  const ConfirmingPayment({
    required this.option,
    required this.payerMsisdn,
    required this.amount,
    this.busy = false,
  });

  final PaymentOptionDto option;
  final String payerMsisdn;
  final Money amount;
  final bool busy;
}

/// The prompt is on the handset. Nobody has typed a PIN yet.
final class AwaitingPin extends PaymentStep {
  const AwaitingPin({
    required this.intent,
    required this.option,
    required this.payerMsisdn,
  });

  final PaymentIntentDto intent;
  final PaymentOptionDto option;
  final String payerMsisdn;
}

final class PaymentSucceeded extends PaymentStep {
  const PaymentSucceeded({required this.intent, required this.booking});
  final PaymentIntentDto intent;
  final BookingDto booking;
}

/// The rail said no, and said why.
final class PaymentRefused extends PaymentStep {
  const PaymentRefused({required this.intent, required this.option});
  final PaymentIntentDto intent;
  final PaymentOptionDto option;

  /// Whether trying the same thing again could plausibly work. A wrong PIN
  /// can; a barred subscriber cannot, and offering "try again" there teaches
  /// people our buttons do nothing.
  bool get retryable =>
      PaymentFailureCode.values
          .where((c) => c.wire == intent.failureCode)
          .firstOrNull
          ?.retryable ??
      false;
}

/// We stopped being able to tell.
///
/// **Not a failure**, and the screen must not say it is. The money may have
/// left their wallet. Somebody is looking at it, and the traveller is told
/// exactly that (`04-payments.md` §7.5).
final class PaymentUnresolved extends PaymentStep {
  const PaymentUnresolved(this.intent);
  final PaymentIntentDto intent;
}

/// Paying for a booking with mobile money.
///
/// The asynchrony that ADR-0005 keeps out of the booking domain has to live
/// somewhere on the client too, and this is it. Everything above renders a
/// step; nothing above knows there is a poll.
final class PaymentFlow {
  PaymentFlow({
    required TravelGateway gateway,
    Clock clock = const SystemClock(),
  }) : _gateway = gateway,
       _clock = clock;

  final TravelGateway _gateway;
  final Clock _clock;

  final _steps = StreamController<PaymentStep>.broadcast();

  PaymentStep _step = const LoadingOptions();
  PaymentStep get step => _step;
  Stream<PaymentStep> get steps => _steps.stream;

  String? _bookingId;

  /// The change order being settled, when this attempt settles one.
  ///
  /// The funnel is otherwise identical — same rails, same prompt, same poll —
  /// because from the rail's side it is the same transaction. What differs is
  /// what the capture means, and that is the server's branch, not the app's.
  String? _changeId;
  String? _attemptKey;
  Timer? _poll;

  void _emit(PaymentStep next) {
    _step = next;
    if (!_steps.isClosed) _steps.add(next);
  }

  Future<void> start(String bookingId, {String? changeId}) async {
    _bookingId = bookingId;
    _changeId = changeId;
    // A fresh attempt, so a key from an earlier one cannot be replayed onto
    // it — the server would answer with the first attempt's intent, which for
    // a different amount entirely is the worst possible reply.
    _attemptKey = null;
    _emit(const LoadingOptions());

    try {
      final result = await _gateway.paymentOptions(
        bookingId,
        changeId: changeId,
      );
      _emit(
        ChoosingMethod(
          options: result.options,
          amount: result.amount,
          // Preselected from the traveller's own number when we can. The
          // majority case then costs no taps at all.
          selected:
              result.options.where((o) => o.recommended).firstOrNull ??
              result.options.firstOrNull,
          payerMsisdn: result.accountMsisdn ?? '',
          accountMsisdn: result.accountMsisdn,
        ),
      );
    } on ApiFailure catch (failure) {
      _emit(
        ChoosingMethod(
          options: const [],
          amount: const Money.xaf(0),
          selected: null,
          payerMsisdn: '',
          failure: failure,
        ),
      );
    }
  }

  void chooseRail(PaymentOptionDto option) {
    final current = _step;
    if (current is! ChoosingMethod) return;
    _emit(
      ChoosingMethod(
        options: current.options,
        amount: current.amount,
        selected: option,
        payerMsisdn: current.payerMsisdn,
        accountMsisdn: current.accountMsisdn,
      ),
    );
  }

  void setPayerNumber(String msisdn) {
    final current = _step;
    if (current is! ChoosingMethod) return;

    // Re-selects the rail the number belongs to, so somebody who types an
    // Airtel number after Airtel was preselected for MTN does not get a
    // wrong-carrier refusal they could have been spared.
    final carrier = PhoneNumber.parse(msisdn).valueOrNull?.operator;
    final matching = carrier == null
        ? null
        : current.options.where((o) => o.operatorId == carrier.id).firstOrNull;

    _emit(
      ChoosingMethod(
        options: current.options,
        amount: current.amount,
        selected: matching ?? current.selected,
        payerMsisdn: msisdn,
        accountMsisdn: current.accountMsisdn,
      ),
    );
  }

  /// Moves to the confirmation screen. Nothing has been sent.
  void review() {
    final current = _step;
    if (current is! ChoosingMethod) return;

    final option = current.selected;
    if (option == null) return;
    if (PhoneNumber.parse(current.payerMsisdn).isErr) return;

    _emit(
      ConfirmingPayment(
        option: option,
        payerMsisdn: current.payerMsisdn,
        amount: current.amount,
      ),
    );
  }

  /// The only method that moves money.
  Future<void> pay() async {
    final current = _step;
    if (current is! ConfirmingPayment || current.busy) return;

    final bookingId = _bookingId;
    if (bookingId == null) return;

    // Minted at the start of the attempt and reused across retries, like the
    // hold's. Sharper here: a second prompt on one handset is a person being
    // asked for their PIN twice for one journey.
    _attemptKey ??= IdempotencyKey.generate();

    _emit(
      ConfirmingPayment(
        option: current.option,
        payerMsisdn: current.payerMsisdn,
        amount: current.amount,
        busy: true,
      ),
    );

    try {
      final intent = await _gateway.startPayment(
        bookingId: bookingId,
        railId: current.option.railId,
        payerMsisdn: current.payerMsisdn,
        idempotencyKey: _attemptKey!,
        changeId: _changeId,
      );

      _emit(
        AwaitingPin(
          intent: intent,
          option: current.option,
          payerMsisdn: current.payerMsisdn,
        ),
      );
      _schedulePoll(intent);
    } on ApiFailure catch (failure) {
      // The rail answered. The next attempt is a genuinely new request and
      // must not reuse a key the server has already answered.
      if (failure is ServerRefused) _attemptKey = null;
      _emit(
        ConfirmingPayment(
          option: current.option,
          payerMsisdn: current.payerMsisdn,
          amount: current.amount,
        ),
      );
      _emitRefusal(failure, current.option);
    }
  }

  void _emitRefusal(ApiFailure failure, PaymentOptionDto option) {
    if (failure is! ServerRefused) return;
    _emit(
      PaymentRefused(
        intent: PaymentIntentDto(
          id: '',
          state: 'failed',
          railId: option.railId,
          amount: const Money.xaf(0),
          createdAt: _clock.now(),
          failureCode: failure.code,
        ),
        option: option,
      ),
    );
  }

  void _schedulePoll(PaymentIntentDto intent) {
    _poll?.cancel();
    _poll = Timer(
      Duration(seconds: intent.pollAfterSeconds ?? 5),
      () => unawaited(_pollOnce()),
    );
  }

  Future<void> _pollOnce() async {
    final current = _step;
    if (current is! AwaitingPin) return;

    try {
      final intent = await _gateway.paymentStatus(current.intent.id);

      switch (intent.state) {
        case 'captured':
          _attemptKey = null;
          final booking = await _gateway.booking(_bookingId!);
          _emit(PaymentSucceeded(intent: intent, booking: booking));
        case 'failed' || 'expired' || 'cancelled':
          _attemptKey = null;
          _emit(PaymentRefused(intent: intent, option: current.option));
        case 'indeterminate':
          // NOT a failure, and the screen must not say it is: the money may
          // have left their wallet, and somebody is looking at it.
          _emit(PaymentUnresolved(intent));
        default:
          _emit(
            AwaitingPin(
              intent: intent,
              option: current.option,
              payerMsisdn: current.payerMsisdn,
            ),
          );
          _schedulePoll(intent);
      }
    } on ApiFailure catch (_) {
      // Losing signal while waiting is not a failed payment. Keep waiting;
      // the worker keeps asking even after this app has gone to sleep.
      _schedulePoll(current.intent);
    }
  }

  /// Back to the method screen after a recoverable refusal.
  Future<void> tryAgain() async {
    _poll?.cancel();
    final bookingId = _bookingId;
    if (bookingId != null) await start(bookingId);
  }

  Future<void> dispose() async {
    _poll?.cancel();
    await _steps.close();
  }
}
