import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/boarding_gateway.dart';

/// Where the coach is on its road, as the conductor's handset knows it.
///
/// A use case rather than widget state, because the rules are not obvious and
/// two of them are about honesty rather than about drawing:
///
///   * **A waypoint is confirmed once.** Tapping Dolisie a second time is not
///     a correction and not a toggle — it is a double tap on a moving coach.
///     The first time stands, which is the same rule the server enforces by
///     primary key.
///   * **The list is the road, not a history.** It is shown in the order the
///     road runs, with what is behind marked, so a conductor reads it the way
///     they are living it. A reverse-chronological feed of taps would be a
///     developer's view of the same facts.
///
/// The device's clock is what gets recorded. It is the only clock that was at
/// the roadside — the server's will not see this for another four hours, and
/// a checkpoint stamped with the hour it happened to sync would report the
/// coach an hour behind itself.
final class RoadProgress {
  RoadProgress({
    required List<WaypointDto> road,
    required CheckpointOutbox outbox,
    required Clock clock,
    String? deviceId,
  }) : _road = road,
       _outbox = outbox,
       _clock = clock,
       _deviceId = deviceId {
    // Seeded from the manifest: a conductor who confirmed Dolisie this morning
    // and whose handset was killed at lunch must not be offered Dolisie again.
    for (final w in road) {
      final at = w.passedAt;
      if (at != null) {
        _outbox.confirm(stopId: w.stopId, at: at, deviceId: _deviceId);
      }
    }
    // Those came *from* the server, so they are not news to it.
    _outbox.markSynced([
      for (final w in road)
        if (w.passedAt != null) w.stopId,
    ]);
  }

  final List<WaypointDto> _road;
  final CheckpointOutbox _outbox;
  final Clock _clock;
  final String? _deviceId;

  /// Whether there is anything to show at all. A road with no intermediate
  /// stops is a real road — Brazzaville to Pointe-Noire direct — and offering
  /// an empty list on one is offering a dead end.
  bool get hasRoad => _road.isNotEmpty;

  int get pendingCount => _outbox.pending().length;

  /// The road in order, each waypoint carrying when it was confirmed.
  List<RoadPoint> points() {
    final confirmed = _outbox.confirmed();
    return [
      for (final w in _road)
        RoadPoint(
          stopId: w.stopId,
          name: w.name,
          offsetMinutes: w.offsetMinutes,
          passedAt: confirmed[w.stopId],
        ),
    ];
  }

  /// The furthest place the coach is confirmed past, or null before the first
  /// tap. What the conductor's screen says without opening the list.
  RoadPoint? get lastConfirmed {
    RoadPoint? last;
    for (final p in points()) {
      if (p.passedAt != null) last = p;
    }
    return last;
  }

  /// One tap. Returns false when this waypoint was already behind the coach,
  /// so the screen can stay quiet rather than claiming it recorded something.
  bool confirm(String stopId) {
    if (_outbox.confirmed().containsKey(stopId)) return false;
    _outbox.confirm(stopId: stopId, at: _clock.now(), deviceId: _deviceId);
    return true;
  }
}

/// One place on the road, and whether the coach is past it.
final class RoadPoint {
  const RoadPoint({
    required this.stopId,
    required this.name,
    required this.offsetMinutes,
    this.passedAt,
  });

  final String stopId;
  final String name;
  final int offsetMinutes;
  final DateTime? passedAt;

  bool get isBehind => passedAt != null;
}
