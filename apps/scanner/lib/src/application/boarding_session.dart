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
  }) : _clock = clock;

  final BoardingManifest manifest;
  final TicketVerifier verifier;
  final RedemptionLog log;
  final String deviceId;
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
