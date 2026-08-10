import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/admin_gateway.dart';

/// Which part of the back office is open.
///
/// Ordered the way a reviewer's day is: the applications waiting on a
/// decision first, the roster second (that is where a commission gets
/// changed, months after onboarding), and the payments nobody could settle
/// automatically third — a queue that is empty on a good day and is the only
/// thing that matters on a bad one.
enum AdminSection { queue, operators, payments, payouts }

/// Everything the back office has loaded, and what it is doing.
///
/// One object rather than a state class per screen, exactly like
/// `ConsoleWorkspace`. And a plain broadcast stream rather than a
/// `ChangeNotifier`, for the reason the layer check enforces: `ChangeNotifier`
/// lives in `package:flutter/foundation`, and the application layer may not
/// import Flutter.
///
/// **The reason is held here, not in a screen.** Every call this class makes
/// carries it: the server refuses a write without one and records it against
/// the actor on every read (ADR-0011). Holding it on the workspace is what
/// makes it survive moving between an operator's file and the payment queue,
/// which is the same half-hour of the same investigation.
final class AdminWorkspace {
  AdminWorkspace({required AdminGateway gateway}) : _gateway = gateway;

  final AdminGateway _gateway;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  AdminIdentityDto? _identity;
  AdminIdentityDto? get identity => _identity;

  var _section = AdminSection.queue;
  AdminSection get section => _section;

  var _busy = false;
  bool get busy => _busy;

  ApiFailure? _failure;
  ApiFailure? get failure => _failure;

  /// Encoded as `key|arg|arg`, never as prose. The same rule the server
  /// follows (ADR-0008): the layer that knows what happened emits a key, the
  /// layer that knows the reader renders the sentence.
  String? _notice;
  String? get notice => _notice;

  /// Why this person is here. Blank is allowed for reads — the server falls
  /// back to a stated default and still records the actor — and refused for
  /// writes, here as well as there.
  var _reason = '';
  String get reason => _reason;
  bool get hasReason => _reason.trim().isNotEmpty;

  void setReason(String value) {
    _reason = value;
    _emit();
  }

  /// Which statuses the roster is filtered to. Empty means everybody.
  var _filter = <String>{};
  Set<String> get filter => _filter;

  List<AdminOperatorDto> operators = const [];
  List<UnresolvedPaymentDto> payments = const [];

  /// Everything prepared and not yet paid, across every operator.
  List<PayoutRunDto> payouts = const [];

  /// The file that is open on top of the current section, if any.
  AdminOperatorDetailDto? _openOperator;
  AdminOperatorDetailDto? get openOperator => _openOperator;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  bool can(String capability) => _identity?.can(capability) ?? false;

  void openSection(AdminSection section) {
    _section = section;
    _openOperator = null;
    _notice = null;
    _failure = null;
    _emit();
    unawaited(refresh());
  }

  void showFilter(Set<String> statuses) {
    _filter = statuses;
    _emit();
    unawaited(refresh());
  }

  /// Loads who we are, then the current section.
  ///
  /// Identity first and always: the navigation is drawn from capabilities, so
  /// a `viewer` who can read neither queue would otherwise see two tabs for
  /// one frame — and a tab that appears and vanishes reads as a bug.
  Future<void> start() => _run(() async {
    _identity = await _gateway.identity();
    await _load();
  });

  Future<void> refresh() => _run(_load);

  Future<void> _load() async {
    switch (_section) {
      // Oldest first is the server's doing, and the filter is the DTO's own
      // list rather than one spelled out here: a screen that enumerates the
      // pending states is a screen that disagrees with the contract the first
      // time one is added.
      case AdminSection.queue:
        operators = await _gateway.operators(
          statuses: AdminOperatorDto.pendingStatuses,
          reason: _reason,
        );
      case AdminSection.operators:
        operators = await _gateway.operators(
          statuses: _filter,
          reason: _reason,
        );
      case AdminSection.payments:
        payments = await _gateway.unresolvedPayments(reason: _reason);
      case AdminSection.payouts:
        payouts = await _gateway.payouts(reason: _reason);
    }

    // A file left open across a refresh is re-read, so a decision taken in
    // another tab does not leave this one showing a status that has moved.
    final open = _openOperator;
    if (open != null) {
      _openOperator = await _gateway.operatorDetail(
        open.operator.id,
        reason: _reason,
      );
    }
  }

  Future<void> open(String id) => _run(() async {
    _openOperator = await _gateway.operatorDetail(id, reason: _reason);
  });

  void closeOperator() {
    _openOperator = null;
    _notice = null;
    _emit();
  }

  // ── Decisions ─────────────────────────────────────────────────────────────

  /// approve · activate · requestInfo · reject · suspend · reinstate.
  ///
  /// Refused here without a reason as well as at the server, and that
  /// duplication is deliberate: the server's 400 is the control, and this one
  /// is what stops a reviewer typing a paragraph into a dialog and losing it
  /// to a refusal they could have been told about before pressing anything.
  Future<void> decide({
    required String operatorId,
    required String decision,
    String? detail,
  }) => _run(() async {
    if (!hasReason) return;
    final updated = await _gateway.decide(
      operatorId: operatorId,
      decision: decision,
      reason: _reason.trim(),
      detail: detail,
    );
    _notice = 'decision|${updated.legalName}';
    await _load();
  });

  Future<void> setCommission({
    required String operatorId,
    required int commissionBps,
  }) => _run(() async {
    if (!hasReason) return;
    final updated = await _gateway.setCommission(
      operatorId: operatorId,
      commissionBps: commissionBps,
      reason: _reason.trim(),
    );
    // Says the rate back rather than "saved". This is the number an operator
    // will argue about, and a confirmation that repeats it is a confirmation
    // somebody can catch a typo in.
    _notice = 'commission|${CommissionTerm(updated.commissionBps).display}';
    await _load();
  });

  // ── The payout run ────────────────────────────────────────────────────────

  /// Prepares one operator's week (`04-payments.md` §6.2).
  ///
  /// The window is passed in whole rather than derived from "last week" here:
  /// a run for a period nobody chose is a run nobody can check, and the two
  /// dates are what the statement is headed with.
  Future<void> preparePayout({
    required String operatorId,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) => _run(() async {
    if (!hasReason) return;
    final run = await _gateway.preparePayout(
      operatorId: operatorId,
      periodStart: periodStart,
      periodEnd: periodEnd,
      reason: _reason.trim(),
    );
    // Says the number back rather than "prepared". This is the amount a
    // second person is about to agree to, and a confirmation that repeats it
    // is a confirmation somebody can catch a wrong window in.
    _notice = 'payout.prepared|${run.net.format()}';
    await _load();
  });

  /// `approve` — a second person agreeing — or `release`, which is the only
  /// one that moves money.
  Future<void> decidePayout({
    required String runId,
    required String decision,
    String? paymentReference,
  }) => _run(() async {
    if (!hasReason) return;
    // Refused here as well as at the server. A transfer with no reference is
    // one nobody can find in a bank statement afterwards, and finding that
    // out from a 400 is finding it out after the money is gone.
    if (decision == 'release' && (paymentReference ?? '').trim().isEmpty) {
      _notice = 'payout.needsReference';
      _emit();
      return;
    }
    final run = await _gateway.decidePayout(
      runId: runId,
      decision: decision,
      reason: _reason.trim(),
      paymentReference: paymentReference?.trim(),
    );
    _notice = run.state == 'paid'
        ? 'payout.released|${run.net.format()}|${run.reference ?? ''}'
        : 'payout.approved|${run.net.format()}';
    await _load();
  });

  // ── The reconciliation queue's three exits ────────────────────────────────

  /// `reask` · `captured` · `failed` (ADR-0005).
  ///
  /// [evidence] is what was seen about *this* payment, distinct from the
  /// standing reason, and it is what the `payment_events` row will carry.
  Future<void> resolve({
    required String intentId,
    required String outcome,
    String? evidence,
    String? failureCode,
  }) => _run(() async {
    if (!hasReason) return;
    await _gateway.resolvePayment(
      intentId: intentId,
      outcome: outcome,
      reason: _reason.trim(),
      evidence: evidence,
      failureCode: failureCode,
    );
    _notice = switch (outcome) {
      'reask' => 'reasked',
      'captured' => 'captured',
      _ => 'failed',
    };
    await _load();
  });

  /// Runs work with one busy flag and one failure slot.
  ///
  /// The failure is cleared at the start rather than at the end: a screen
  /// showing yesterday's error beside today's spinner is a screen nobody
  /// believes.
  Future<void> _run(Future<void> Function() work) async {
    _busy = true;
    _failure = null;
    _emit();
    try {
      await work();
    } on ApiFailure catch (failure) {
      _failure = failure;
      _notice = null;
    } finally {
      _busy = false;
      _emit();
    }
  }

  Future<void> dispose() => _changes.close();
}
