import 'package:bel_contracts/bel_contracts.dart';

/// Where a ticket lives between one launch of the app and the next.
///
/// The app has always kept the last list it loaded **in memory**, which
/// survives a lost connection but not a killed process — and the moment this
/// matters most is a passenger boarding at six in the morning in a place with
/// no signal, on a handset that swapped the app out overnight. A QR that
/// needs the network to render is a QR that fails exactly where it is needed.
///
/// A port rather than a class, for the layer rule this repository keeps: the
/// application layer holds no Flutter and no SQL, so the flow talks to this
/// and the storage lives outside it. It also makes the offline behaviour
/// testable in milliseconds against a map.
///
/// **Scoped by traveller.** A handset is shared here — one telephone, several
/// people's journeys bought on it — and a vault keyed on nothing would hand
/// the next person to sign in somebody else's ticket.
abstract interface class TicketVault {
  /// What was stored for [userId], oldest departure first is not promised —
  /// the flow sorts what it gets, and a store that promised an order would be
  /// a second place for that rule to live.
  ///
  /// Returns empty rather than throwing when the store is unreadable: a
  /// corrupt cache must degrade to "no cached tickets", never to a crash on
  /// launch.
  Future<List<BookingDto>> read(String userId);

  /// Replaces everything held for [userId].
  ///
  /// Replaces rather than merges: the list the server just answered with is
  /// the whole truth about what this traveller holds, and a booking that
  /// vanished from it is one that was cancelled or refunded. Merging would
  /// keep a refunded ticket renderable forever.
  Future<void> write(String userId, List<BookingDto> bookings);

  /// Forgets everything, for every traveller. Called on sign-out.
  Future<void> clear();
}

/// The null vault, for a build with no storage behind it.
///
/// Not a silent no-op by accident: the web console and every widget test run
/// against this, and "the tickets do not persist" is the honest behaviour
/// there rather than a failure.
final class NoTicketVault implements TicketVault {
  const NoTicketVault();

  @override
  Future<List<BookingDto>> read(String userId) async => const [];

  @override
  Future<void> write(String userId, List<BookingDto> bookings) async {}

  @override
  Future<void> clear() async {}
}
