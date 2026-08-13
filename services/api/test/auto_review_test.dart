import 'package:bel_api/src/application/auto_review_applications.dart';
import 'package:bel_api/src/application/ports/review_queue.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 3, 1);

ApplicationFacts small({int fleet = 3}) => ApplicationFacts(
  legalName: 'Sotrapo SARL',
  rccmNumber: 'CG-DLS-01-2019-B12-00108',
  taxId: 'M2019110000108',
  legalForm: 'sarl',
  registeredAddress: '4 rue de la Gare, Dolisie',
  ownerName: 'Serge Loubaki',
  ownerIdType: 'passport',
  ownerIdNumber: '19CD98765',
  ownerPhone: '+242060192286',
  ownerEmail: 'serge@sotrapo.cg',
  transportLicenceNumber: 'TR-2025-0114',
  transportLicenceExpires: DateTime.utc(2027, 6, 1),
  insurerName: 'NSIA Congo',
  fleetInsuranceExpires: DateTime.utc(2027, 6, 1),
  routesServed: 'Dolisie - Pointe-Noire',
  fleetSize: fleet,
  stationCount: 1,
  dailyDepartures: 4,
  settlementKind: 'momo',
  settlementAccountName: 'Sotrapo',
  settlementAccountRef: '+242060192286',
  agreementAccepted: true,
);

final class _Queue implements ReviewQueue {
  _Queue(this.pending);

  List<PendingApplication> pending;
  final recorded = <String, (RiskBand, List<String>)>{};
  final approved = <String>[];

  /// A reviewer who got there first: the conditional UPDATE finds nothing.
  Set<String> alreadyDecided = {};

  @override
  Future<List<PendingApplication>> awaitingAssessment({int limit = 50}) async =>
      pending.take(limit).toList();

  @override
  Future<void> record({
    required String operatorId,
    required RiskBand band,
    required List<String> reasons,
  }) async => recorded[operatorId] = (band, reasons);

  @override
  Future<bool> approve({required String operatorId}) async {
    if (alreadyDecided.contains(operatorId)) return false;
    approved.add(operatorId);
    return true;
  }
}

final class _Screen implements ApplicantScreening {
  _Screen(this.outcome);
  ScreeningOutcome outcome;
  final asked = <String>[];

  @override
  Future<ScreeningOutcome> screen({
    required String operatorId,
    required String code,
    String? ownerName,
    String? ownerIdNumber,
  }) async {
    asked.add(operatorId);
    return outcome;
  }
}

void main() {
  AutoReviewApplications reviewer(
    _Queue queue, {
    ScreeningOutcome screening = ScreeningOutcome.clear,
    _Screen? screen,
  }) => AutoReviewApplications(
    queue: queue,
    screening: screen ?? _Screen(screening),
    clock: FixedClock(now),
  );

  PendingApplication pending(
    String id, {
    int fleet = 3,
    bool duplicate = false,
  }) => PendingApplication(
    operatorId: id,
    code: 'SOT',
    legalName: 'Sotrapo SARL',
    facts: small(fleet: fleet),
    duplicate: duplicate,
  );

  test(
    'a small complete application is activated with nobody in the loop',
    () async {
      final queue = _Queue([pending('op-1')]);

      final result = await reviewer(queue).run();

      expect(result.assessed, 1);
      expect(result.approved, 1);
      expect(queue.approved, ['op-1']);
      expect(queue.recorded['op-1']?.$1, RiskBand.low);
    },
  );

  test('an approval is recorded before it is taken', () async {
    // An approval whose grounds were never written down is an approval nobody
    // can explain afterwards, which is worse than a slow queue.
    final queue = _Queue([pending('op-1')]);

    await reviewer(queue).run();

    expect(queue.recorded.containsKey('op-1'), isTrue);
    expect(queue.recorded['op-1']?.$2, isEmpty);
  });

  test('everything else is sorted, not approved', () async {
    final queue = _Queue([pending('op-big', fleet: 40)]);

    final result = await reviewer(queue).run();

    expect(result.approved, 0);
    expect(queue.approved, isEmpty);
    // Still assessed: a reviewer opening the queue on Monday sees the reasons
    // already written down.
    expect(queue.recorded['op-big']?.$1, RiskBand.standard);
    expect(queue.recorded['op-big']?.$2, [RiskReason.fleetTooLarge]);
  });

  test('with no screening vendor, nobody is approved at all', () async {
    final queue = _Queue([pending('op-1'), pending('op-2')]);

    final result = await reviewer(
      queue,
      screening: ScreeningOutcome.notRun,
    ).run();

    // The state of the world today, and a correct answer rather than a broken
    // one: every application still gets sorted.
    expect(result.assessed, 2);
    expect(result.approved, 0);
    expect(queue.recorded, hasLength(2));
  });

  test('a reviewer who got there first wins the race', () async {
    final queue = _Queue([pending('op-1')])..alreadyDecided = {'op-1'};

    final result = await reviewer(queue).run();

    // The UPDATE is conditional on `under_review`, so a decision already
    // taken is never overwritten — the safe direction for the race to go.
    expect(result.approved, 0);
  });

  test('one screening call per application, not one per pass', () async {
    final screen = _Screen(ScreeningOutcome.clear);
    final queue = _Queue([pending('op-1'), pending('op-2')]);

    await reviewer(queue, screen: screen).run();

    // A paid third-party call. Asking about every row in the table on every
    // run is a bill nobody budgeted.
    expect(screen.asked, ['op-1', 'op-2']);
  });

  test('an elevated application is never approved, however small', () async {
    final queue = _Queue([pending('op-dup', duplicate: true)]);

    final result = await reviewer(queue).run();

    expect(result.approved, 0);
    expect(queue.recorded['op-dup']?.$1, RiskBand.elevated);
  });

  test('an empty queue is a pass that did nothing, not a failure', () async {
    final result = await reviewer(_Queue([])).run();

    expect(result.assessed, 0);
    expect(result.approved, 0);
  });
}
