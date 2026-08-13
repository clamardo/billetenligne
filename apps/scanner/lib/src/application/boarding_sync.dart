import 'ports/boarding_gateway.dart';

/// Empties the device's boarding outbox.
///
/// A use case rather than a button handler, because the rule it encodes is
/// not obvious: **a boarding leaves the outbox whether the server recorded it
/// or refused it.** An unknown ticket will not start existing on the next
/// attempt, and a queue that retries a permanent failure forever is a handset
/// that is flat before the return leg.
///
/// Never called from the scanning path. The door works offline; this runs
/// when a conductor asks, or when the coach reaches somewhere with signal.
final class BoardingSync {
  const BoardingSync({
    required BoardingGateway gateway,
    required RedemptionOutbox outbox,
    required String departureId,
    CheckpointOutbox? road,
  }) : _gateway = gateway,
       _outbox = outbox,
       _departureId = departureId,
       _road = road;

  final BoardingGateway _gateway;
  final RedemptionOutbox _outbox;

  /// The waypoints this handset confirmed, drained in the same window as the
  /// boardings. Null on a coach whose road has no intermediate stops.
  final CheckpointOutbox? _road;

  final String _departureId;

  int get pendingCount =>
      _outbox.pending().length + (_road?.pending().length ?? 0);

  /// One attempt. Failure is reported, not thrown and not retried here — the
  /// conductor decides whether to try again, and the rows stay queued.
  ///
  /// The two queues are sent in **separate requests and reported together**.
  /// Separate, because a coach can have one without the other and a combined
  /// request would make an empty half a reason to skip the full one. Together,
  /// because the conductor tapped *send* once and one answer is what they
  /// asked for.
  Future<SyncReport> drain() async {
    final boardings = await _drainBoardings();
    final road = await _drainRoad();

    return SyncReport(
      settled: boardings.settled,
      checkpointsSettled: road.settled,
      stillPending: boardings.stillPending + road.stillPending,
      // The first failure, and there is rarely a second kind: both halves fail
      // for the same reason, which is that there is no network.
      failure: boardings.failure ?? road.failure,
    );
  }

  Future<SyncReport> _drainBoardings() async {
    final pending = _outbox.pending();
    if (pending.isEmpty) return const SyncReport(settled: 0, stillPending: 0);

    try {
      final settled = await _gateway.uploadBoardings(
        departureId: _departureId,
        boardings: pending,
      );
      _outbox.markSynced(settled);
      return SyncReport(
        settled: settled.length,
        stillPending: _outbox.pending().length,
      );
    } on Object catch (e) {
      return SyncReport(settled: 0, stillPending: pending.length, failure: e);
    }
  }

  Future<SyncReport> _drainRoad() async {
    final road = _road;
    if (road == null) return const SyncReport(settled: 0, stillPending: 0);

    final pending = road.pending();
    if (pending.isEmpty) return const SyncReport(settled: 0, stillPending: 0);

    try {
      final settled = await _gateway.uploadCheckpoints(
        departureId: _departureId,
        passages: pending,
      );
      road.markSynced(settled);
      return SyncReport(
        settled: settled.length,
        stillPending: road.pending().length,
      );
    } on Object catch (e) {
      return SyncReport(settled: 0, stillPending: pending.length, failure: e);
    }
  }
}

final class SyncReport {
  const SyncReport({
    required this.settled,
    required this.stillPending,
    this.checkpointsSettled = 0,
    this.failure,
  });

  /// Boardings. Named without qualification because it is what the conductor
  /// means by *sent* — sixty people went up, and the two waypoints that went
  /// with them are not what they were counting.
  final int settled;

  final int checkpointsSettled;
  final int stillPending;
  final Object? failure;

  bool get ok => failure == null;
}
