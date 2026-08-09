import 'package:bel_domain/bel_domain.dart';

/// Local record of who has boarded.
///
/// On device this is backed by SQLite and drained through the outbox when a
/// network appears; the in-memory form here is the same contract, and it is
/// what the tests and the demo run against.
///
/// The important property is that **the first scan wins**. A conductor who
/// double-taps must see the original time, because that is the one a dispute
/// is settled with.
final class MemoryRedemptionLog implements RedemptionLog {
  final Map<String, _Scan> _scans = {};

  @override
  DateTime? scannedAt(String bookingRef, String seatLabel) =>
      _scans[BoardingManifest.keyFor(bookingRef, seatLabel)]?.at;

  @override
  void record({
    required String bookingRef,
    required String seatLabel,
    required DateTime at,
    required String deviceId,
    bool codeWasStale = false,
    bool manual = false,
  }) {
    _scans.putIfAbsent(
      BoardingManifest.keyFor(bookingRef, seatLabel),
      () => _Scan(at, deviceId, manual, codeWasStale),
    );
  }

  /// Rows waiting to sync. Queued through the outbox, never sent inline —
  /// boarding must not pause for the network.
  List<Map<String, Object?>> pending() => [
    for (final e in _scans.entries)
      if (!e.value.synced)
        {
          'key': e.key,
          'scannedAt': e.value.at.toUtc().toIso8601String(),
          'deviceId': e.value.deviceId,
          'mode': e.value.manual ? 'manual' : 'scan',
          'codeWasStale': e.value.codeWasStale,
        },
  ];

  void markSynced(Iterable<String> keys) {
    for (final k in keys) {
      _scans[k]?.synced = true;
    }
  }

  int get count => _scans.length;
}

final class _Scan {
  _Scan(this.at, this.deviceId, this.manual, this.codeWasStale);
  final DateTime at;
  final String deviceId;
  final bool manual;
  final bool codeWasStale;
  bool synced = false;
}
