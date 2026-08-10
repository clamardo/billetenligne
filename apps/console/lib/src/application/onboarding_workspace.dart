import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/onboarding_gateway.dart';

/// The application an operator is filling in, and what it is doing.
///
/// The same shape as [ConsoleWorkspace] — a plain broadcast stream rather
/// than a `ChangeNotifier`, because the layer check refuses Flutter here —
/// and deliberately a *second* object rather than a mode of the first. They
/// share nothing: this one has no tenant, no capabilities, and no fleet.
///
/// **The facts are held locally and saved behind the applicant.** §2.2 asks
/// for "save on every field" over connections that drop, so typing is never
/// blocked on a request: [edit] updates the record in memory and marks it
/// dirty, and [saveNow] pushes the whole thing. A failed save leaves the
/// typing intact and says so.
final class OnboardingWorkspace {
  OnboardingWorkspace({required OnboardingGateway gateway, Clock? clock})
    : _gateway = gateway,
      _clock = clock ?? const SystemClock();

  final OnboardingGateway _gateway;
  final Clock _clock;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  OperatorApplicationDto? _application;
  OperatorApplicationDto? get application => _application;

  var _facts = const ApplicationFacts();
  ApplicationFacts get facts => _facts;

  var _step = ApplicationStep.entreprise;
  ApplicationStep get step => _step;

  var _busy = false;
  bool get busy => _busy;

  var _dirty = false;

  /// True when the screen holds edits the server has not been told about.
  /// Shown rather than hidden: an applicant who closes a tab is entitled to
  /// know whether their last two minutes are anywhere.
  bool get hasUnsavedChanges => _dirty;

  ApiFailure? _failure;
  ApiFailure? get failure => _failure;

  String? _notice;
  String? get notice => _notice;

  /// Everything still outstanding, judged against today — so an insurance
  /// certificate that expired last month reads as missing rather than as
  /// answered.
  List<String> get missing => _facts.missing(asOf: _clock.now());

  List<String> missingIn(ApplicationStep step) =>
      _facts.missingIn(step, asOf: _clock.now());

  bool isComplete(ApplicationStep step) => missingIn(step).isEmpty;

  bool get canSubmit =>
      _application != null &&
      _application!.isEditable &&
      _facts.isSubmittable(asOf: _clock.now());

  /// True once a reviewer has it. The wizard goes read-only rather than
  /// disappearing: somebody who has just applied wants to reread what they
  /// sent.
  bool get isUnderReview => _application != null && !_application!.isEditable;

  Future<void> load() => _run(() async {
    _application = await _gateway.mine();
    _facts = _application?.facts ?? const ApplicationFacts();
    _dirty = false;
  });

  Future<void> begin(String legalName) => _run(() async {
    _application = await _gateway.start(legalName);
    _facts = _application!.facts;
    _dirty = false;
    _notice = 'application.started';
  });

  void openStep(ApplicationStep step) {
    _step = step;
    _notice = null;
    _failure = null;
    _emit();
  }

  /// Local only. The applicant types; the server hears about it on the next
  /// [saveNow], which is what makes typing survive a dead connection.
  void edit(ApplicationFacts facts) {
    _facts = facts;
    _dirty = true;
    _notice = null;
    _emit();
  }

  Future<void> saveNow() => _run(() async {
    _application = await _gateway.save(_facts);
    _facts = _application!.facts;
    _dirty = false;
    _notice = 'application.saved';
  });

  /// Saves first, always. Submitting what the server holds rather than what
  /// the screen holds is how somebody submits an application missing the
  /// three fields they just typed.
  Future<void> submit() => _run(() async {
    if (_dirty) {
      _application = await _gateway.save(_facts);
      _facts = _application!.facts;
      _dirty = false;
    }
    _application = await _gateway.submit();
    _facts = _application!.facts;
    _notice = 'application.submitted';
  });

  Future<void> _run(Future<void> Function() work) async {
    _busy = true;
    _failure = null;
    _notice = null;
    _emit();
    try {
      await work();
    } on ApiFailure catch (e) {
      _failure = e;
    } finally {
      _busy = false;
      _emit();
    }
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() => _changes.close();
}
