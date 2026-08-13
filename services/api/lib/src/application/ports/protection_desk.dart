import 'package:bel_domain/bel_domain.dart';

/// A standing agreement, as one of the two parties sees it.
///
/// The counterparty's name is carried because every screen that shows one of
/// these is answering "who is this with?" — and the operator asking is not
/// always `operatorA`, so a caller cannot resolve it from the row alone.
final class ProtectionAgreementView {
  const ProtectionAgreementView({
    required this.agreement,
    required this.counterpartyId,
    required this.counterpartyName,
    required this.proposedAt,
    required this.weProposed,
    required this.seatsUsedThisMonth,
    this.acceptedAt,
    this.endedAt,
    this.endedReason,
  });

  final ProtectionAgreement agreement;

  /// The other company, from the point of view of whoever asked.
  final String counterpartyId;
  final String counterpartyName;

  final DateTime proposedAt;

  /// Whether the operator reading this wrote the terms. Decides whether the
  /// screen shows "waiting for them" or "they are waiting for you".
  final bool weProposed;

  /// Seats moved under this agreement in the current calendar month, so the
  /// ceiling can be shown as `31 / 40` rather than discovered on refusal.
  final int seatsUsedThisMonth;

  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final String? endedReason;

  bool get awaitingUs =>
      !weProposed && agreement.state == ProtectionAgreementState.proposed;
}

/// Why an agreement could not be proposed or decided.
sealed class AgreementRefusal {
  const AgreementRefusal();
  String get code;
  Map<String, Object?> get params => const {};
}

final class UnknownCounterparty extends AgreementRefusal {
  const UnknownCounterparty();
  @override
  String get code => 'agreement.unknown_counterparty';
}

final class UnknownAgreement extends AgreementRefusal {
  const UnknownAgreement();
  @override
  String get code => 'agreement.unknown';
}

/// These two already have one proposed or in force. A second would be two
/// rates for the same seat with no way to say which was meant.
final class AlreadyAgreed extends AgreementRefusal {
  const AlreadyAgreed();
  @override
  String get code => 'agreement.already_exists';
}

/// The agreement is not in a state that allows what was asked — accepting one
/// already active, ending one that ended.
final class WrongAgreementState extends AgreementRefusal {
  const WrongAgreementState(this.state);
  final String state;
  @override
  String get code => 'agreement.wrong_state';
  @override
  Map<String, Object?> get params => {'state': state};
}

/// A domain rule said no: a corridor that goes nowhere, the party that wrote
/// the terms trying to accept them.
final class AgreementRefused extends AgreementRefusal {
  const AgreementRefused(this.failure);
  final DomainFailure failure;
  @override
  String get code => failure.code;
  @override
  Map<String, Object?> get params => failure.params;
}

/// One company asking another for room (`08-disruption.md` §2.3).
/// An open call for room, and what the operator reading it needs to answer
/// (`08-disruption.md` §5).
///
/// The digital version of a dispatcher walking down the gare asking who has
/// space. It exists because an agreement is a relationship two companies
/// already have, and the coach that breaks down on a Tuesday belongs to
/// somebody who has none.
final class OpenCallView {
  const OpenCallView({
    required this.id,
    required this.sendingOperatorId,
    required this.sendingOperatorName,
    required this.weOpened,
    required this.fromDepartureId,
    required this.originCity,
    required this.destinationCity,
    required this.seatsRequested,
    required this.rebillPerSeat,
    required this.state,
    required this.openedAt,
    required this.expiresAt,
    this.note,
    this.departsAt,
    this.answeredByOperator,
    this.closedAt,
  });

  final String id;
  final String sendingOperatorId;

  /// Named, because an operator deciding whether to take forty-two strangers
  /// is deciding partly on who is asking.
  final String sendingOperatorName;

  /// Whether this is ours to chase or ours to answer.
  final bool weOpened;

  final String fromDepartureId;
  final String originCity;
  final String destinationCity;
  final int seatsRequested;

  /// Per seat, in the broken departure's own currency. Stated on the call
  /// rather than negotiated afterwards: ninety seconds is the whole decision
  /// window, and a price that arrives later is a price nobody priced against.
  final Money rebillPerSeat;

  /// `open` · `answered` · `withdrawn` · `expired`.
  final String state;

  final DateTime openedAt;
  final DateTime expiresAt;
  final String? note;
  final DateTime? departsAt;
  final String? answeredByOperator;
  final DateTime? closedAt;

  bool get isOpen => state == 'open';
}

/// No such call, or not one this operator was invited to answer.
final class UnknownCall extends AgreementRefusal {
  const UnknownCall();
  @override
  String get code => 'protection.unknown_call';
}

/// Somebody else answered first, or the sender withdrew it. The ordinary
/// outcome of a broadcast, and not an error — two dispatchers reaching for
/// the same forty-two passengers at 06:04 is the normal case.
final class CallAlreadyClosed extends AgreementRefusal {
  const CallAlreadyClosed(this.state);
  final String state;
  @override
  String get code => 'protection.call_closed';
  @override
  Map<String, Object?> get params => {'state': state};
}

/// This operator has not opted in to receive open calls, is not selling, or
/// does not run the road. All three are the same answer to the console: there
/// is nothing here for you.
final class NotInvited extends AgreementRefusal {
  const NotInvited();
  @override
  String get code => 'protection.not_invited';
}

final class ProtectionRequestView {
  const ProtectionRequestView({
    required this.id,
    this.agreementId,
    this.callId,
    required this.sendingOperatorId,
    required this.receivingOperatorId,
    required this.counterpartyName,
    required this.weAsked,
    required this.fromDepartureId,
    required this.toDepartureId,
    required this.seatsRequested,
    required this.state,
    required this.requestedAt,
    this.note,
    this.routeCode,
    this.departsAt,
    this.replacementDepartsAt,
    this.seatsFree = 0,
    this.rebill,
    this.autoAccepted = false,
    this.seatsMoved,
    this.declineReason,
  });

  final String id;

  /// The authority this movement runs under. **Exactly one is set** — the
  /// schema enforces it (0034) — and which one decides where the rebill price
  /// comes from: an agreement carries a negotiated discount, a call carries
  /// the price it was broadcast at.
  final String? agreementId;
  final String? callId;

  final String sendingOperatorId;
  final String receivingOperatorId;

  /// The other company, from the point of view of whoever asked for this.
  final String counterpartyName;

  /// Whether this is ours to chase or ours to answer.
  final bool weAsked;

  final String fromDepartureId;
  final String toDepartureId;
  final int seatsRequested;

  /// `pending` · `accepted` · `declined` · `applied` · `expired` · `failed`.
  final String state;

  final DateTime requestedAt;
  final String? note;

  /// Enough of the journey to decide without opening anything else. §2.3 asks
  /// for a live seat count on the receiving console, and a receiving operator
  /// deciding blind is one who says no.
  final String? routeCode;
  final DateTime? departsAt;
  final DateTime? replacementDepartsAt;
  final int seatsFree;

  /// What the receiving operator would be paid, at the agreed discount, for
  /// the seats being asked for. Shown before the decision, not after.
  final Money? rebill;

  final bool autoAccepted;
  final int? seatsMoved;
  final String? declineReason;

  bool get isPending => state == 'pending';
  bool get awaitingUs => isPending && !weAsked;
}

/// No such request, or not one of ours.
final class UnknownRequest extends AgreementRefusal {
  const UnknownRequest();
  @override
  String get code => 'protection.unknown_request';
}

/// The request is not in a state that allows what was asked.
final class WrongRequestState extends AgreementRefusal {
  const WrongRequestState(this.state);
  final String state;
  @override
  String get code => 'protection.wrong_request_state';
  @override
  Map<String, Object?> get params => {'state': state};
}

/// The seats were gone by the time somebody accepted. A real outcome and not
/// an error: the receiving operator kept selling while the request sat in
/// their queue, which is exactly what they should have been doing.
final class NobodyCouldBeMoved extends AgreementRefusal {
  const NobodyCouldBeMoved();
  @override
  String get code => 'protection.nobody_fits';
}

/// Inter-operator protection agreements (`08-disruption.md` §5).
///
/// Separate from `DisruptionDesk` because the two are used on different days
/// by different people. An agreement is a commercial term, negotiated once,
/// in an office; a disruption is a roadside emergency. Putting them behind
/// one port would mean the screen a dispatcher opens at 05:00 shares its
/// error vocabulary with a contract page.
abstract interface class ProtectionDesk {
  /// Every agreement this operator is a party to, in either role, most
  /// recently proposed first.
  Future<List<ProtectionAgreementView>> agreementsFor(String operatorId);

  /// Write the terms and send them to the other company.
  ///
  /// The proposal binds nobody until they accept: this returns an agreement
  /// in [ProtectionAgreementState.proposed], and no protection request can be
  /// made against it.
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  propose({
    required String operatorId,
    required String counterpartyCode,
    required List<Corridor> corridors,
    required String actorUserId,
    bool reciprocal,
    int rebillDiscountBps,
    int? monthlyCapSeats,
    int? autoAcceptWhenSpareAbove,
  });

  /// `accept` · `decline` · `suspend` · `resume` · `end`.
  ///
  /// One method rather than five, because the rule they share is the one that
  /// matters: the party that wrote the terms cannot be the party that agrees
  /// to them.
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  decide({
    required String operatorId,
    required String agreementId,
    required String decision,
    required String actorUserId,
    String? reason,
  });

  /// Requests this operator is a party to, in either direction, newest first.
  Future<List<ProtectionRequestView>> requestsFor(String operatorId);

  /// Ask the other company for room (`08-disruption.md` §2.2 option ③).
  ///
  /// Refused before it is written if the agreement does not cover the road,
  /// is not in force, or the month's ceiling has no room — the same domain
  /// function the console calls before it draws the option.
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  request({
    required String operatorId,
    required String departureId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  });

  /// `accept` or `decline`, by the receiving operator.
  ///
  /// Accepting **applies the movement in the same transaction**: the seats
  /// are taken on the receiving departure, the bookings and their tickets
  /// move to the receiving operator, and the rebill posts against the two
  /// payables. A request that is accepted and applied later is a window in
  /// which a receiving operator sells the seats they just promised.
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  decideRequest({
    required String operatorId,
    required String requestId,
    required String decision,
    required String actorUserId,
    required DateTime now,
    String? reason,
  });

  // ── Open protection (§5) ──────────────────────────────────────────────────

  /// Whether this operator receives open calls, and the calls they can see:
  /// their own, and every live one on a road they run.
  ///
  /// One method rather than two lists, because the console draws them on one
  /// screen and a second round trip to learn "and am I opted in?" is a screen
  /// that renders an empty inbox before it knows whether empty means *nobody
  /// needs help* or *you never said yes*.
  Future<({bool receiving, List<OpenCallView> calls})> openCalls(
    String operatorId,
  );

  /// Opt in or out of receiving open calls.
  ///
  /// Opting out does not withdraw calls already answered, and does not stop
  /// this operator asking: broadcasting for help and agreeing to answer are
  /// two different decisions, and a company with one coach may honestly want
  /// only the first.
  Future<bool> receiveOpenCalls({
    required String operatorId,
    required bool receiving,
    required String actorUserId,
  });

  /// Broadcast a request for room to every opted-in operator on the road.
  ///
  /// The price is decided here and stated on the call. No discount by
  /// default: a discount is what a relationship earns, and there is no
  /// relationship here.
  Future<({OpenCallView? call, AgreementRefusal? refusal})> openCall({
    required String operatorId,
    required String departureId,
    required String actorUserId,
    required DateTime now,
    Duration window,
    String? note,
  });

  /// Take it back. Only the sender can, and only while it is open.
  Future<({OpenCallView? call, AgreementRefusal? refusal})> withdrawCall({
    required String operatorId,
    required String callId,
    required String actorUserId,
  });

  /// Answer a call with one of our own departures. **First to accept wins.**
  ///
  /// Closing the call and moving the passengers are the same transaction, or
  /// the winner is decided twice: two consoles that both saw `open` would
  /// both move people onto two different coaches, and the passengers would be
  /// the ones to find out.
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  answerCall({
    required String operatorId,
    required String callId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  });
}

/// What the fakes composition answers with. Protection is a commercial
/// arrangement between two real companies; there is nothing useful to fake.
final class UnavailableProtection implements ProtectionDesk {
  const UnavailableProtection();

  @override
  Future<List<ProtectionAgreementView>> agreementsFor(
    String operatorId,
  ) async => const [];

  @override
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  propose({
    required String operatorId,
    required String counterpartyCode,
    required List<Corridor> corridors,
    required String actorUserId,
    bool reciprocal = true,
    int rebillDiscountBps = 0,
    int? monthlyCapSeats,
    int? autoAcceptWhenSpareAbove,
  }) async => (agreement: null, refusal: const UnknownCounterparty());

  @override
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  decide({
    required String operatorId,
    required String agreementId,
    required String decision,
    required String actorUserId,
    String? reason,
  }) async => (agreement: null, refusal: const UnknownAgreement());

  @override
  Future<List<ProtectionRequestView>> requestsFor(String operatorId) async =>
      const [];

  @override
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  request({
    required String operatorId,
    required String departureId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) async => (request: null, refusal: const AgreementRefused(NoAgreement()));

  @override
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  decideRequest({
    required String operatorId,
    required String requestId,
    required String decision,
    required String actorUserId,
    required DateTime now,
    String? reason,
  }) async => (request: null, refusal: const UnknownRequest());

  @override
  Future<({bool receiving, List<OpenCallView> calls})> openCalls(
    String operatorId,
  ) async => (receiving: false, calls: const <OpenCallView>[]);

  @override
  Future<bool> receiveOpenCalls({
    required String operatorId,
    required bool receiving,
    required String actorUserId,
  }) async => false;

  @override
  Future<({OpenCallView? call, AgreementRefusal? refusal})> openCall({
    required String operatorId,
    required String departureId,
    required String actorUserId,
    required DateTime now,
    Duration window = const Duration(hours: 2),
    String? note,
  }) async => (call: null, refusal: const UnknownCall());

  @override
  Future<({OpenCallView? call, AgreementRefusal? refusal})> withdrawCall({
    required String operatorId,
    required String callId,
    required String actorUserId,
  }) async => (call: null, refusal: const UnknownCall());

  @override
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  answerCall({
    required String operatorId,
    required String callId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) async => (request: null, refusal: const UnknownCall());
}
