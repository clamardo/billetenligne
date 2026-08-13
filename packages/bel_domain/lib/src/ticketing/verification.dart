import 'crypto_ports.dart';
import 'rotating_code.dart';
import 'ticket_payload.dart';

/// What the conductor sees, full-screen, one word, readable at arm's length in
/// direct sun.
///
/// Five verdicts, not two. A generic "reject" tells a conductor nothing and
/// leaves a paying passenger arguing at the door — which is exactly where this
/// product either works or does not.
enum VerificationResult {
  /// Board them.
  valid,

  /// Scanned before. Shows the first scan time, because the usual cause is a
  /// double-tap by the conductor, not fraud.
  alreadyBoarded,

  /// A real ticket, for a different departure. The most common genuine error,
  /// and it deserves its own answer telling them which coach to find.
  wrongDeparture,

  /// Signature failed, malformed, or unknown key. Forged or corrupt.
  invalid,

  /// Signature is good but the freshness code is stale — most likely a
  /// screenshot. Amber, not red: it prompts a refresh rather than accusing
  /// someone at the door.
  staleCode,

  /// Refunded or cancelled. Voided at refund *approval*, so a ticket cannot
  /// board while the money is still in flight.
  voided,

  /// Signature is good but this ticket is not on this vehicle's manifest —
  /// issued after the manifest was pinned, or the conductor opened the wrong
  /// departure.
  notOnManifest;

  bool get boards => this == VerificationResult.valid;

  /// Amber rather than red: recoverable at the door, usually by the passenger
  /// refreshing their screen or the conductor picking the right departure.
  bool get isRecoverable =>
      this == VerificationResult.staleCode ||
      this == VerificationResult.wrongDeparture;

  String get labelKey => 'enum.VerificationResult.$name';
}

/// The verdict, plus what the conductor needs on screen to act on it.
final class VerificationOutcome {
  const VerificationOutcome({
    required this.result,
    this.payload,
    this.entry,
    this.firstScannedAt,
    this.expectedDepartureId,
    this.detail,
  });

  final VerificationResult result;

  /// Present whenever the signature verified — so even a wrong-departure or
  /// already-boarded verdict can name the passenger and seat.
  final TicketPayload? payload;

  /// The manifest's own row for this ticket, present once it has been found.
  /// It carries what the signed payload cannot: whether this passenger is
  /// riding a piece of the road, and where they get off.
  final ManifestEntry? entry;

  final DateTime? firstScannedAt;
  final String? expectedDepartureId;
  final String? detail;

  bool get boards => result.boards;

  @override
  String toString() => 'VerificationOutcome(${result.name}, $detail)';
}

/// One departure's worth of truth, pinned to the device before boarding.
///
/// A few KB. Downloaded when the conductor opens the departure, then the
/// network is irrelevant — which is the whole design (ADR-0007).
final class BoardingManifest {
  const BoardingManifest({
    required this.departureId,
    required this.operatorCode,
    required this.departsAt,
    required this.entries,
    this.routeCode,
    this.voidedTicketRefs = const {},
    this.pinnedAt,
  });

  final String departureId;
  final String operatorCode;
  final DateTime departsAt;

  /// `BZV>PNR`, for the one line of context the conductor gets at the top of
  /// the screen. Optional because the verdict never depends on it — a
  /// manifest with no route code still boards people.
  final String? routeCode;

  /// Booking ref + seat, so a passenger with two seats is two entries.
  final Map<String, ManifestEntry> entries;

  /// Refunded or cancelled since the manifest was pinned. Carried explicitly
  /// because a signature stays valid forever — only the manifest knows a
  /// ticket has been voided.
  final Set<String> voidedTicketRefs;

  final DateTime? pinnedAt;

  static String keyFor(String bookingRef, String seatLabel) =>
      '$bookingRef/$seatLabel';

  ManifestEntry? lookup(String bookingRef, String seatLabel) =>
      entries[keyFor(bookingRef, seatLabel)];

  int get expected => entries.length;

  /// How stale this manifest is. Surfaced to the conductor so they can decide
  /// whether to re-sync before departure rather than discovering a gap at the
  /// door.
  Duration? ageAt(DateTime now) =>
      pinnedAt == null ? null : now.difference(pinnedAt!);
}

final class ManifestEntry {
  const ManifestEntry({
    required this.bookingRef,
    required this.seatLabel,
    required this.passengerName,
    required this.rotatingSecret,
    this.boardsAt,
    this.alightsAt,
  });

  final String bookingRef;
  final String seatLabel;
  final String passengerName;

  /// Where this passenger gets on and off, when they bought a piece of the
  /// road rather than the whole of it (ADR-0025). Null is the ordinary
  /// whole-journey ticket, which is what the departure already says.
  ///
  /// It lives on the manifest rather than in the QR on purpose. The payload
  /// is signed, so putting the leg in it would mean a format change and a
  /// scanner in the field refusing every ticket issued after the day we
  /// shipped it — for a fact the device already downloaded before the coach
  /// left the yard.
  final String? boardsAt;
  final String? alightsAt;

  /// Per-ticket secret, so the device can compute the expected freshness code
  /// offline. Never leaves the manifest, and the manifest never leaves the
  /// operator's device.
  final List<int> rotatingSecret;
}

/// A record of who has already boarded, held locally on the scanning device.
abstract interface class RedemptionLog {
  /// When this ticket was first scanned, or null.
  DateTime? scannedAt(String bookingRef, String seatLabel);

  /// Records a boarding. Must be idempotent: the first scan time wins, because
  /// that is the one a dispute is settled with.
  void record({
    required String bookingRef,
    required String seatLabel,
    required DateTime at,
    required String deviceId,
    bool codeWasStale,
    bool manual,
  });
}

/// Decides whether a scanned ticket boards.
///
/// Everything here is a local decision: a signature check, a manifest lookup
/// and a redemption log. **No network, ever.** Target is under two seconds on
/// the cheapest handset an operator owns.
final class TicketVerifier {
  const TicketVerifier({
    required SignatureVerifier signatures,
    required MessageAuthenticator mac,
    required RedemptionLog log,
  }) : _signatures = signatures,
       _mac = mac,
       _log = log;

  final SignatureVerifier _signatures;
  final MessageAuthenticator _mac;
  final RedemptionLog _log;

  /// [presentedCode] overrides the code carried inside the scanned QR. Normally
  /// left null: a live ticket's QR regenerates every 30 seconds and carries its
  /// own freshness code, because a camera reads one thing and a conductor
  /// cannot be asked to type six digits per passenger.
  ///
  /// A **printed** ticket has no live code. It is not rejected — its defence
  /// against replay is the redemption log, which makes it single-use.
  VerificationOutcome verify({
    required String scanned,
    required BoardingManifest manifest,
    required DateTime now,
    String? presentedCode,
    bool requireFreshCode = true,
  }) {
    // 1. Decode. A malformed or future-version payload is refused rather than
    //    guessed at.
    final decoded = TicketPayload.decode(scanned);
    final data = decoded.valueOrNull;
    if (data == null) {
      return VerificationOutcome(
        result: VerificationResult.invalid,
        detail: decoded.failureOrNull?.toString(),
      );
    }

    final payload = data.payload;

    // 2. Signature. Everything after this can trust the contents; nothing
    //    before it can.
    final authentic = _signatures.verify(
      message: payload.signingBytes(),
      signature: data.signature,
      keyId: payload.keyId,
    );
    if (!authentic) {
      return const VerificationOutcome(
        result: VerificationResult.invalid,
        detail: 'signature',
      );
    }

    // 3. Right coach? Checked before anything else about the passenger,
    //    because this is the most common real error and the answer the
    //    conductor needs is "which departure", not "no".
    if (payload.departureId != manifest.departureId) {
      return VerificationOutcome(
        result: VerificationResult.wrongDeparture,
        payload: payload,
        expectedDepartureId: manifest.departureId,
        detail: payload.departureId,
      );
    }

    // 4. Refunded since the manifest was pinned. A signature stays valid
    //    forever; only the manifest knows the money went back.
    if (manifest.voidedTicketRefs.contains(
      BoardingManifest.keyFor(payload.bookingRef, payload.seatLabel),
    )) {
      return VerificationOutcome(
        result: VerificationResult.voided,
        payload: payload,
      );
    }

    final entry = manifest.lookup(payload.bookingRef, payload.seatLabel);
    if (entry == null) {
      return VerificationOutcome(
        result: VerificationResult.notOnManifest,
        payload: payload,
        detail: 'issued after this manifest was pinned',
      );
    }

    // 5. Already boarded. Ranked above the freshness check on purpose: if the
    //    same ticket is presented twice, that fact matters more than whether
    //    the second attempt's code was fresh.
    final already = _log.scannedAt(payload.bookingRef, payload.seatLabel);
    if (already != null) {
      return VerificationOutcome(
        result: VerificationResult.alreadyBoarded,
        payload: payload,
        entry: entry,
        firstScannedAt: already,
      );
    }

    // 6. Freshness — the screenshot check.
    final code = presentedCode ?? data.freshnessCode;
    if (requireFreshCode) {
      if (code == null) {
        // A printed ticket. Signed, on the manifest, not yet redeemed — board
        // them. Single use is enforced by the redemption log above, which is
        // the right defence for paper.
        return VerificationOutcome(
          result: VerificationResult.valid,
          payload: payload,
          entry: entry,
          detail: 'printed',
        );
      }
      final fresh = RotatingCode.isFresh(
        presented: code,
        secret: entry.rotatingSecret,
        now: now,
        mac: _mac,
      );
      if (!fresh) {
        return VerificationOutcome(
          result: VerificationResult.staleCode,
          payload: payload,
          entry: entry,
        );
      }
    }

    return VerificationOutcome(
      result: VerificationResult.valid,
      payload: payload,
      entry: entry,
    );
  }

  /// Boarding by booking reference against the offline manifest, for a dead
  /// or broken passenger phone.
  ///
  /// Never leave a paying passenger at the roadside because of our technology.
  /// Recorded as manual so the operator can see how often it happens.
  VerificationOutcome verifyManual({
    required String bookingRef,
    required String seatLabel,
    required BoardingManifest manifest,
    required DateTime now,
  }) {
    if (manifest.voidedTicketRefs.contains(
      BoardingManifest.keyFor(bookingRef, seatLabel),
    )) {
      return const VerificationOutcome(result: VerificationResult.voided);
    }

    final entry = manifest.lookup(bookingRef, seatLabel);
    if (entry == null) {
      return const VerificationOutcome(
        result: VerificationResult.notOnManifest,
      );
    }

    final already = _log.scannedAt(bookingRef, seatLabel);
    if (already != null) {
      return VerificationOutcome(
        result: VerificationResult.alreadyBoarded,
        entry: entry,
        firstScannedAt: already,
      );
    }

    return VerificationOutcome(
      result: VerificationResult.valid,
      entry: entry,
      detail: 'manual',
    );
  }
}
