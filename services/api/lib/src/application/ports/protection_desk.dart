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
}
