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
  /// The coaches this conductor could be boarding, over a span of local days.
  ///
  /// **Calendar days rather than "the next few hours".** A conductor working
  /// an evening service on the far side of midnight is looking at a day, and
  /// a rolling window would quietly hide their coach.
  ///
  /// The span is what makes a plan: one call for a day, a week or a month,
  /// because the signal this is fetched on is a yard's and a week assembled
  /// from seven requests finishes only if all seven do. Each row says whether
  /// this person is rostered on it, and as what.
  Future<List<BoardingDepartureDto>> coachesBetween(
    DateTime from,
    DateTime to,
  );

  /// Whose handset this is: the name and the matricule the company wrote down.
  ///
  /// Asked once, after sign-in. A conductor's handset is issued by an agency
  /// and passed between people, and a screen that lists coaches without
  /// saying whose they are cannot be checked by the person holding it.
  ///
  /// Failure is a blank identity and never an error: this is a header, and a
  /// yard with no signal must still reach the door.
  Future<ScannerIdentity> whoAmI();

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

  /// Says the coach has left, or has arrived (J4).
  ///
  /// The one call here that is **not** queued, and deliberately. Everything
  /// else on this port is a record of something that already happened at the
  /// door or at the roadside, so it can wait for signal without becoming
  /// untrue. Closing a departure is different: what it does is stop new sales
  /// on the server, and a close that syncs three hours later has not stopped
  /// anything — it has let a counter sell seats on a coach that is halfway to
  /// Pointe-Noire. So it fails honestly when there is no signal, and the
  /// conductor tries again.
  ///
  /// It does not touch the outbox. Boardings queued behind it upload
  /// afterwards and are still accepted: the door happened while the coach was
  /// there, and closing takes nothing away from a passenger already sitting
  /// down.
  Future<DepartureStateDto> setDepartureState({
    required String departureId,
    required String state,
  });
}

/// Who is signed in on this handset.
///
/// Every field is nullable, and blank renders nothing. A company that has not
/// written somebody's name down gets a header with no name on it — never a
/// UUID, which is what the back office used to show and what everybody who
/// saw it read as a bug.
final class ScannerIdentity {
  const ScannerIdentity({this.fullName, this.staffRef, this.operatorName});

  final String? fullName;

  /// The matricule. An identifier on the roster, printed on the manifest and
  /// stuck to the dashboard of the coach — and deliberately **not** a
  /// credential (ADR-0024).
  final String? staffRef;

  final String? operatorName;

  bool get isBlank =>
      fullName == null && staffRef == null && operatorName == null;

  static const blank = ScannerIdentity();
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
