/// Keys for requests that move money or inventory.
///
/// One key per *attempt*, reused across every retry of that attempt. That
/// single rule is what makes a dropped connection safe: the retry carries the
/// same key, the server recognises it, and the traveller gets the hold they
/// already have rather than a second one on different seats.
///
/// Generated client-side because only the client knows where an attempt
/// begins — the server cannot tell a retry from a fresh request without being
/// told.
abstract final class IdempotencyKey {
  /// Not a UUID library, deliberately: this needs to be unique among *this
  /// device's* in-flight requests, not globally unique across the universe.
  /// Time plus a counter plus a per-process seed is comfortably enough, and it
  /// is one fewer dependency in a package four surfaces compile into.
  static String generate() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final n = (_counter = (_counter + 1) & 0xFFFFFF);
    return '${now.toRadixString(36)}-${n.toRadixString(36)}-'
        '${_seed.toRadixString(36)}';
  }

  static var _counter = 0;

  /// Fixed per process. Two handsets starting in the same microsecond still
  /// differ, and a single app restart cannot collide with its own past.
  static final int _seed =
      DateTime.now().microsecondsSinceEpoch & 0xFFFFFFF ^
      identityHashCode(Object());
}
