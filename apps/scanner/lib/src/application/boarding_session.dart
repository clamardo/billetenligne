import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// Everything the scanner knows about the departure being boarded.
///
/// Held entirely in memory and on disk. Once a manifest is pinned, boarding
/// works with the radio switched off — which is the whole point (ADR-0022).
final class BoardingSession {
  BoardingSession({
    required this.manifest,
    required this.verifier,
    required this.log,
    required this.deviceId,
    required Clock clock,
    this.preparer,
    List<BoardingUploadDto> resumed = const [],
  }) : _clock = clock {
    // A handset that was killed mid-boarding comes back knowing who is
    // already on. The log survived; this is what turns it back into the
    // number the conductor is watching.
    for (final row in resumed) {
      final at = row.key.indexOf('/');
      if (at <= 0) continue;
      final ref = row.key.substring(0, at);
      final seat = row.key.substring(at + 1);
      _boarded.add(
        BoardedPassenger(
          bookingRef: ref,
          seatLabel: seat,
          passengerName: manifest.lookup(ref, seat)?.passengerName ?? '',
          at: row.scannedAt,
          manual: row.mode == 'manual',
          codeWasStale: row.codeWasStale,
        ),
      );
    }
  }

  final BoardingManifest manifest;
  final TicketVerifier verifier;
  final RedemptionLog log;
  final String deviceId;

  /// Does the async half of the signature check, one payload at a time.
  ///
  /// Null in a test or a demo whose payloads were prepared when they were
  /// built. Never null against a real coach: the device has never seen the
  /// traveller's signature until the camera reads it, so without this every
  /// genuine ticket in the field would come back `invalid`.
  final SignaturePreparer? preparer;

  final Clock _clock;

  final List<BoardedPassenger> _boarded = [];

  List<BoardedPassenger> get boarded => List.unmodifiable(_boarded);
  int get boardedCount => _boarded.length;
  int get expected => manifest.expected;

  /// The count the conductor watches: `47 / 60 embarqués`.
  String get progress => '$boardedCount / $expected';

  bool get isComplete => boardedCount >= expected;

  /// Everyone sold a seat who has not scanned. Shown before departure so the
  /// conductor can call names rather than leave someone behind.
  List<ManifestEntry> get noShows => [
    for (final entry in manifest.entries.values)
      if (log.scannedAt(entry.bookingRef, entry.seatLabel) == null) entry,
  ];

  /// Prepares a raw scan so [scan] can answer synchronously.
  ///
  /// Awaited by the one place that receives a scan, immediately before the
  /// decision. A payload that will not decode is left alone — [scan] refuses
  /// it a microsecond later, and this is not the place to say so twice.
  Future<void> warm(String raw) async {
    final preparer = this.preparer;
    if (preparer == null) return;

    final data = TicketPayload.decode(raw).valueOrNull;
    if (data == null) return;

    await preparer.prepare(
      message: data.payload.signingBytes(),
      signature: data.signature,
      keyId: data.payload.keyId,
    );
  }

  /// Scan a QR. The verdict is a pure local decision; recording it is the only
  /// side effect, and only when it boards.
  VerificationOutcome scan(String raw, {String? presentedCode}) {
    final now = _clock.now();
    final outcome = verifier.verify(
      scanned: raw,
      manifest: manifest,
      now: now,
      presentedCode: presentedCode,
    );

    if (outcome.boards && outcome.payload != null) {
      _record(
        outcome.payload!.bookingRef,
        outcome.payload!.seatLabel,
        outcome.payload!.passengerName,
        now,
        manual: false,
      );
    }
    return outcome;
  }

  /// Board by reference against the offline manifest, for a dead or broken
  /// passenger phone.
  ///
  /// Never leave a paying passenger at the roadside because of our technology.
  /// Flagged as manual so an operator can see how often it happens — a spike
  /// usually means a real problem somewhere else.
  VerificationOutcome boardManually({
    required String bookingRef,
    required String seatLabel,
  }) {
    final now = _clock.now();
    final outcome = verifier.verifyManual(
      bookingRef: bookingRef,
      seatLabel: seatLabel,
      manifest: manifest,
      now: now,
    );

    if (outcome.boards) {
      final entry = manifest.lookup(bookingRef, seatLabel);
      _record(
        bookingRef,
        seatLabel,
        entry?.passengerName ?? '',
        now,
        manual: true,
      );
    }
    return outcome;
  }

  /// Conductor override after a stale code — the passenger is standing there
  /// with ID and a genuine, signed ticket.
  ///
  /// Deliberately possible, and deliberately recorded: refusing a real
  /// passenger over a clock or a slow screen is a worse outcome than a logged
  /// override an operator can review.
  VerificationOutcome overrideStaleCode(VerificationOutcome staleOutcome) {
    final payload = staleOutcome.payload;
    if (payload == null ||
        staleOutcome.result != VerificationResult.staleCode) {
      return staleOutcome;
    }

    final now = _clock.now();
    _record(
      payload.bookingRef,
      payload.seatLabel,
      payload.passengerName,
      now,
      manual: false,
      codeWasStale: true,
    );

    return VerificationOutcome(
      result: VerificationResult.valid,
      payload: payload,
      detail: 'override',
    );
  }

  /// Search the manifest by name or reference, for manual boarding.
  List<ManifestEntry> search(String query) {
    final q = query.trim().toUpperCase();
    if (q.isEmpty) return const [];
    return [
      for (final e in manifest.entries.values)
        if (e.bookingRef.toUpperCase().contains(q) ||
            e.passengerName.toUpperCase().contains(q) ||
            e.seatLabel.toUpperCase() == q)
          e,
    ];
  }

  void _record(
    String bookingRef,
    String seatLabel,
    String passengerName,
    DateTime at, {
    required bool manual,
    bool codeWasStale = false,
  }) {
    log.record(
      bookingRef: bookingRef,
      seatLabel: seatLabel,
      at: at,
      deviceId: deviceId,
      manual: manual,
      codeWasStale: codeWasStale,
    );
    _boarded.add(
      BoardedPassenger(
        bookingRef: bookingRef,
        seatLabel: seatLabel,
        passengerName: passengerName,
        at: at,
        manual: manual,
        codeWasStale: codeWasStale,
      ),
    );
  }
}

final class BoardedPassenger {
  const BoardedPassenger({
    required this.bookingRef,
    required this.seatLabel,
    required this.passengerName,
    required this.at,
    required this.manual,
    required this.codeWasStale,
  });

  final String bookingRef;
  final String seatLabel;
  final String passengerName;
  final DateTime at;
  final bool manual;
  final bool codeWasStale;
}
