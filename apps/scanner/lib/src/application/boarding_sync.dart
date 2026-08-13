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
  }) : _gateway = gateway,
       _outbox = outbox,
       _departureId = departureId;

  final BoardingGateway _gateway;
  final RedemptionOutbox _outbox;
  final String _departureId;

  int get pendingCount => _outbox.pending().length;

  /// One attempt. Failure is reported, not thrown and not retried here — the
  /// conductor decides whether to try again, and the rows stay queued.
  Future<SyncReport> drain() async {
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
}

final class SyncReport {
  const SyncReport({
    required this.settled,
    required this.stillPending,
    this.failure,
  });

  final int settled;
  final int stillPending;
  final Object? failure;

  bool get ok => failure == null;
}
