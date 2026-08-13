import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../simulated_scan.dart';

/// Everything the scanner needs from the outside world, and it is very little.
///
/// Three calls, and none of them happens at the door. A conductor picks a
/// coach in the yard, pins it, and the network stops mattering until the
/// outbox is emptied at the other end (ADR-0022). Anything that made boarding
/// wait on this port would be the wrong design, not a slow one.
abstract interface class BoardingGateway {
  /// The coaches this conductor could be boarding today.
  ///
  /// A date rather than "the next few": a conductor working an evening
  /// service on the far side of midnight is looking at a day, and a rolling
  /// window would quietly hide their coach.
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate);

  /// The one request before the door opens.
  Future<PinnedDeparture> pin(String departureId);

  /// Empties the device's outbox and returns the keys that are settled —
  /// recorded *and* unknown, because neither will change on a retry and an
  /// outbox that retries forever is a flat battery by eleven.
  Future<Set<String>> uploadBoardings({
    required String departureId,
    required List<BoardingUploadDto> boardings,
  });

  /// Sends the waypoints this coach has been confirmed past (ADR-0014 §1,
  /// tier 2), and returns the stop ids that are settled.
  ///
  /// A fourth call, and still none of them at the door. The tap happens on
  /// the road — which on the RN1 is four hours with no usable signal — so
  /// this queues exactly like a boarding and empties in the same window.
  Future<Set<String>> uploadCheckpoints({
    required String departureId,
    required List<PassageUploadDto> passages,
  });
}

/// A manifest, and the keys that make it verifiable.
///
/// The two travel together because they arrive together and are useless
/// apart: the manifest without the public keys cannot tell a genuine ticket
/// from a printed rectangle.
final class PinnedDeparture {
  const PinnedDeparture({
    required this.manifest,
    required this.signatures,
    required this.preparer,
    this.simulatedScans = const [],
    this.waypoints = const [],
  });

  final BoardingManifest manifest;
  final SignatureVerifier signatures;

  /// Usually the same object as [signatures]. Named separately because the
  /// domain draws the line between deciding and doing async work, and this is
  /// where an adapter honours it.
  final SignaturePreparer? preparer;

  /// Canned scans for the debug simulator, and empty against a real coach.
  ///
  /// There is no honest way to fill this from a server: a simulated scan
  /// needs a signed payload and a live secret, which only the demo departure
  /// holds. Empty renders no simulator, which is the correct behaviour in the
  /// yard anyway.
  final List<SimulatedScan> simulatedScans;

  /// The road this coach runs, in the order it runs it, with the waypoints
  /// somebody has already confirmed marked.
  ///
  /// Arrives with the manifest for the same reason the public keys do: what
  /// it is for happens where there is no network, and a list fetched on
  /// demand is a list that is never there.
  final List<WaypointDto> waypoints;
}

/// What is waiting to go up, and what has gone.
///
/// The redemption log's other face. Split out as a port so the drain is a
/// use case rather than something a widget knows how to do — and so a device
/// storing its log in SQLite tomorrow changes one adapter.
abstract interface class RedemptionOutbox {
  /// Boardings recorded on this device that the server has not acknowledged.
  List<BoardingUploadDto> pending();

  /// Everything this device recorded for the coach, settled or not.
  ///
  /// What a relaunch is rebuilt from. Without it the conductor's counter
  /// reads `0 / 60` on a handset that has already boarded forty people, and a
  /// number that is wrong at the door is worse than no number.
  List<BoardingUploadDto> recorded();

  /// Marks rows as settled. Idempotent, and safe to call with keys that were
  /// never pending.
  void markSynced(Iterable<String> keys);
}

/// Where the coach has been confirmed past, on the handset.
///
/// A second outbox rather than a column on the first, because the two are
/// about different things: one is a person at a door, the other is a place on
/// a road. Sharing a table would mean every query about who boarded had to
/// remember to exclude the checkpoints.
///
/// **First tap wins here too.** A conductor who taps Dolisie twice means the
/// same thing twice, and the time worth keeping is the first one — the same
/// rule the server enforces by primary key, so a device offline for six hours
/// behaves exactly as the server eventually will.
abstract interface class CheckpointOutbox {
  /// Records a confirmation, or leaves the earlier one alone.
  void confirm({
    required String stopId,
    required DateTime at,
    String? deviceId,
  });

  /// Every waypoint this device knows is behind the coach, settled or not, by
  /// stop id. What the list draws its ticks from, and what a handset killed
  /// mid-route is rebuilt from.
  Map<String, DateTime> confirmed();

  /// Confirmations the server has not acknowledged.
  List<PassageUploadDto> pending();

  void markSynced(Iterable<String> stopIds);
}
