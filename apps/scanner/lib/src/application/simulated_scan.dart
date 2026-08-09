/// What kind of thing was presented at the door.
///
/// Semantic, not visual: the presentation layer decides what icon and colour
/// each one gets. That is what lets this type sit in the application layer,
/// where infrastructure can build it and a widget can render it without either
/// knowing about the other.
enum SimulatedScanKind {
  /// Genuine ticket, live code. Boards.
  genuine,

  /// Authentic QR, frozen code — a screenshot.
  screenshot,

  /// Real ticket, different coach.
  otherDeparture,

  /// Refunded since the manifest was pinned.
  refunded,

  /// Signature does not match the contents.
  forged,

  /// Not one of our tickets at all. A conductor will scan a bottle label
  /// eventually, and it must produce a verdict rather than a crash.
  foreign,
}

/// One canned scan, ready to be fed into the verifier.
///
/// Carries the *exact string a camera would decode*, so a simulated scan
/// cannot take a different code path from a real one. The moment it does, the
/// simulator stops proving anything.
final class SimulatedScan {
  const SimulatedScan({
    required this.title,
    required this.subtitle,
    required this.payload,
    required this.kind,
    this.code,
  });

  final String title;
  final String subtitle;

  /// The decoded QR contents.
  final String payload;

  /// Overrides the code carried inside [payload]. Normally null — a live QR
  /// already contains its own freshness code.
  final String? code;

  final SimulatedScanKind kind;
}
