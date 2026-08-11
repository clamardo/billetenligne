import 'package:bel_domain/bel_domain.dart';

/// An operator, as our own back office lists them.
final class OperatorSummary {
  const OperatorSummary({
    required this.id,
    required this.code,
    required this.legalName,
    required this.status,
    required this.marketCode,
    required this.createdAt,
    required this.commission,
    this.tradingName,
    this.rccmNumber,
    this.taxId,
    this.documentCount = 0,
    this.expiringDocumentCount = 0,
    this.vehicleCount = 0,
    this.routeCount = 0,
    this.staffCount = 0,
  });

  final String id;
  final String code;
  final String legalName;

  /// `registered` … `active` … `offboarded`. The lifecycle in
  /// `03-operator-lifecycle.md` §1, as the column stores it.
  final String status;

  final String marketCode;
  final DateTime createdAt;

  /// What they signed. On the summary because it is the number a reviewer is
  /// deciding about, not a detail behind another tap.
  final CommissionTerm commission;

  final String? tradingName;
  final String? rccmNumber;
  final String? taxId;

  final int documentCount;

  /// Licences and insurance expiring within thirty days, or already expired.
  /// Selling seats on an uninsured coach is a liability we will not carry
  /// (§3.3), so this number belongs in the queue, not in a report.
  final int expiringDocumentCount;

  final int vehicleCount;
  final int routeCount;
  final int staffCount;

  /// How long this application has been waiting. The queue is sorted by it and
  /// coloured by it: 90% of complete applications decided within 48 hours is a
  /// published promise, and a queue that does not show the clock cannot keep
  /// one.
  Duration waitingAt(DateTime now) => now.difference(createdAt);

  bool get isPending =>
      status == 'registered' ||
      status == 'application_draft' ||
      status == 'under_review' ||
      status == 'kyb_verifying' ||
      status == 'info_requested';
}

/// One compliance document, as the reviewer sees it listed.
///
/// The file itself is not here. It lives in blob storage behind a
/// short-lived signed URL, and a list of expiry dates is what the *decision*
/// needs — the scan is what the eyes need, and they are fetched separately so
/// a queue screen does not drag ten megabytes of photographs behind it.
final class KybDocument {
  const KybDocument({
    required this.id,
    required this.docType,
    required this.storageKey,
    required this.createdAt,
    this.expiresAt,
    this.verifiedAt,
    this.rejectedReason,
  });

  final String id;
  final String docType;
  final String storageKey;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? verifiedAt;
  final String? rejectedReason;

  bool get isVerified => verifiedAt != null;

  bool expiresWithin(Duration window, DateTime now) =>
      expiresAt != null && expiresAt!.isBefore(now.add(window));
}

/// One line of the immutable trail.
final class AuditEntry {
  const AuditEntry({
    required this.action,
    required this.actorType,
    required this.createdAt,
    this.actorId,
    this.reason,
    this.subjectType,
    this.subjectId,
  });

  final String action;
  final String actorType;
  final DateTime createdAt;
  final String? actorId;
  final String? reason;
  final String? subjectType;
  final String? subjectId;
}

/// The wizard's answers, as the reviewer reads them.
///
/// Null for every operator that arrived before self-signup existed — which is
/// the first ten, by SQL, in a room. Nullable rather than empty on purpose: a
/// reviewer must be able to tell "applied and left step 4 blank" from "never
/// applied at all", and an empty record says the first about the second.
final class SubmittedApplication {
  const SubmittedApplication({
    required this.facts,
    this.submittedAt,
    this.settlementVerifiedAt,
  });

  final ApplicationFacts facts;
  final DateTime? submittedAt;

  /// Set when the name-check or micro-deposit came back. Nothing writes it
  /// yet: the verification is a third-party call this deployment does not
  /// make, so a reviewer compares the two names themselves — which is what
  /// [ApplicationFacts.settlementNameMatchesLegalName] is for.
  final DateTime? settlementVerifiedAt;

  bool get isSubmitted => submittedAt != null;
}

/// Everything about one operator on one page, because tab-hunting during a
/// review is how a missing insurance certificate gets approved.
final class OperatorDetail {
  const OperatorDetail({
    required this.summary,
    required this.documents,
    required this.trail,
    this.application,
  });

  final OperatorSummary summary;
  final SubmittedApplication? application;
  final List<KybDocument> documents;

  /// Newest first, and capped: the point is what has happened to this
  /// operator lately, not an export.
  final List<AuditEntry> trail;
}

/// What a reviewer decided.
///
/// Named outcomes rather than a target status string, because three of these
/// five are the same status transition with completely different meanings —
/// and an audit log that cannot tell "rejected" from "offboarded" is not an
/// audit log.
enum OperatorDecision {
  approve('approved', 'operator.approve'),
  activate('active', 'operator.activate'),
  requestInfo('info_requested', 'operator.request_info'),
  reject('rejected', 'operator.reject'),
  suspend('suspended', 'operator.suspend'),
  reinstate('active', 'operator.reinstate');

  const OperatorDecision(this.status, this.action);

  /// The `operator_status` this moves the operator to.
  final String status;

  /// What lands in the audit log.
  final String action;

  static OperatorDecision? byName(String raw) {
    for (final d in OperatorDecision.values) {
      if (d.name == raw) return d;
    }
    return null;
  }
}

/// Why a decision was refused. Not a failure of the request — a fact about
/// the operator's current state.
enum DecisionRefusal {
  /// No such operator, or one this deployment cannot see.
  unknownOperator,

  /// `active` → `approve` and similar. The lifecycle is a state machine and
  /// this is the same guard the payment intent has, for the same reason.
  illegalTransition,
}

/// A payment nobody can resolve automatically.
///
/// Fifteen minutes of silence from a rail turns a `pending` intent into an
/// `indeterminate` one, and that is not a failure state — it is a state where
/// **the money may have moved and we do not know**. Somebody has to look:
/// the operator's merchant statement, a screenshot of the traveller's wallet,
/// a call to the telco. This row is what they look at.
///
/// It carries the traveller's own contact deliberately. The person in the
/// dark is the one whose PIN was typed, and a queue that cannot produce a
/// number to call is a queue that resolves by waiting.
final class UnresolvedPayment {
  const UnresolvedPayment({
    required this.intentId,
    required this.state,
    required this.railId,
    required this.amount,
    required this.payerMsisdn,
    required this.createdAt,
    required this.bookingId,
    required this.bookingRef,
    required this.bookingState,
    required this.operatorId,
    required this.operatorName,
    required this.pollAttempts,
    this.lastPolledAt,
    this.railTransactionId,
    this.travellerPhone,
    this.travellerEmail,
    this.departsAt,
    this.originCity,
    this.destinationCity,
  });

  final String intentId;

  /// `indeterminate`, and occasionally `pending` for an intent whose window
  /// has closed. Both mean the same thing to the person working the queue.
  final String state;

  final String railId;
  final Money amount;
  final String payerMsisdn;
  final DateTime createdAt;

  final String bookingId;
  final String bookingRef;
  final String bookingState;

  final String operatorId;
  final String operatorName;

  final int pollAttempts;
  final DateTime? lastPolledAt;
  final String? railTransactionId;

  final String? travellerPhone;
  final String? travellerEmail;

  final DateTime? departsAt;
  final String? originCity;
  final String? destinationCity;

  /// How long this person has been in the dark. The queue is sorted by it.
  Duration ageAt(DateTime now) => now.difference(createdAt);

  /// True when the coach leaves within the hour. These jump the queue: after
  /// it goes, resolving the payment is a refund conversation rather than a
  /// boarding one.
  bool isUrgentAt(DateTime now) =>
      departsAt != null &&
      departsAt!.difference(now) < const Duration(hours: 1);
}

/// The cross-tenant surface: our own back office.
///
/// Every method takes an **actor and a reason** rather than reading them from
/// an ambient scope, and both are written to `audit_log` in the same
/// transaction as the change. That is the whole design: a cross-tenant read
/// or write that is not attributable is one nobody can defend afterwards
/// (ADR-0011), and making the arguments mandatory is how "remember to audit
/// it" stops being discipline.
abstract interface class PlatformConsole {
  /// The review queue and the roster, in one query.
  ///
  /// [statuses] empty means every operator. Sorted oldest-application-first,
  /// because a queue worked newest-first is a queue with a permanently
  /// abandoned tail.
  /// [actorUserId] is not decoration: it becomes `app.user_id` on the
  /// connection, so a platform read is attributable at the database as well as
  /// in the audit row written beside it.
  Future<List<OperatorSummary>> operators({
    required String actorUserId,
    Set<String> statuses = const {},
  });

  Future<OperatorDetail?> operatorDetail(
    String operatorId, {
    required String actorUserId,
  });

  /// Approve · request info · reject · suspend · reinstate.
  ///
  /// Returns the refreshed operator, or the reason it was refused.
  Future<Result<OperatorSummary, DecisionRefusal>> decide({
    required String operatorId,
    required OperatorDecision decision,
    required String actorUserId,
    required String reason,
    String? detail,
  });

  /// Sets what this operator negotiated. Its own method rather than a field on
  /// a decision, because changing the commission of an operator who is already
  /// selling is a different act from approving an application — and it is the
  /// one an operator will argue about six months later, so it is audited with
  /// the old rate and the new one in the same row.
  Future<Result<OperatorSummary, DecisionRefusal>> setCommission({
    required String operatorId,
    required CommissionTerm term,
    required String actorUserId,
    required String reason,
  });

  // ── Reconciliation (ADR-0005) ─────────────────────────────────────────────

  /// Every payment in limbo, longest-waiting first.
  ///
  /// Deliberately on this port rather than on `PaymentStore`: that one serves
  /// a traveller watching their own attempt, and this one crosses every
  /// tenant to serve the person who has to make it right. Same table, two
  /// completely different authorities.
  Future<List<UnresolvedPayment>> unresolvedPayments({
    required String actorUserId,
    int limit = 100,
  });

  Future<UnresolvedPayment?> unresolvedPayment(
    String intentId, {
    required String actorUserId,
  });

  /// Where people leave, by day (`04-payments.md` §8).
  ///
  /// Cross-tenant by nature — the platform's own health, not one operator's —
  /// with [operatorId] narrowing it when somebody is looking into a single
  /// company. Newest day first, because the question is nearly always about
  /// this week.
  Future<List<FunnelDay>> funnel({
    required String actorUserId,
    int days = 14,
    String? operatorId,
    String channel = 'app',
  });

  /// Records that somebody looked. Cross-tenant *reads* are audited too, and
  /// this is the call that does it — deliberately separate, so the read path
  /// stays a plain query and the audit cannot be forgotten inside it.
  Future<void> recordRead({
    required String actorUserId,
    required String reason,
    required String action,
    String? subjectType,
    String? subjectId,
    String? operatorId,
    String? traceId,
  });
}

/// One day of the funnel we can actually count.
///
/// **The top of the funnel is missing, and deliberately.** A search leaves no
/// row anywhere: recording one means a telemetry path, a consent question and
/// a table that grows faster than the sales it describes. What this counts
/// starts where the traveller first takes something from the inventory — a
/// seat held — and every step after that is a row we already store for its
/// own reasons. The screen says so rather than letting somebody read
/// "conversion" as search-to-ticket.
final class FunnelDay {
  const FunnelDay({
    required this.day,
    required this.held,
    required this.reserved,
    required this.paid,
    required this.holdsLapsed,
    required this.paymentsFailed,
  });

  /// The local calendar day in the market's timezone. A funnel bucketed by
  /// UTC splits an evening's sales across two rows in this market.
  final DateTime day;

  /// Seats claimed. The cohort every other figure on this row is about — so
  /// a booking made today from yesterday's hold counts on yesterday's row,
  /// which is the only way "of the people who started, how many finished"
  /// means anything.
  final int held;

  /// Holds that became a booking.
  final int reserved;

  /// Bookings that were paid for, whenever they were paid.
  final int paid;

  /// Holds nobody came back to.
  final int holdsLapsed;

  /// Attempts the rail refused. Counted from the cohort's bookings rather
  /// than from all intents, because an intent belongs to a journey somebody
  /// started on a particular day.
  final int paymentsFailed;

  /// Percentages, rounded, and null when the denominator is zero rather than
  /// zero: nought out of nought is not a bad day, it is a quiet one.
  int? get holdToReservation => _rate(reserved, held);
  int? get reservationToPaid => _rate(paid, reserved);
  int? get holdToPaid => _rate(paid, held);

  static int? _rate(int part, int whole) =>
      whole == 0 ? null : (100 * part / whole).round();
}
