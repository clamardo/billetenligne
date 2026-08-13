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
}

/// What is waiting to go up, and what has gone.
///
/// The redemption log's other face. Split out as a port so the drain is a
/// use case rather than something a widget knows how to do — and so a device
/// storing its log in SQLite tomorrow changes one adapter.
abstract interface class RedemptionOutbox {
  /// Boardings recorded on this device that the server has not acknowledged.
  List<BoardingUploadDto> pending();

  /// Marks rows as settled. Idempotent, and safe to call with keys that were
  /// never pending.
  void markSynced(Iterable<String> keys);
}
