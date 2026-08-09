import 'package:bel_domain/bel_domain.dart';

/// A ticket, signed and ready to travel.
final class SignedTicket {
  const SignedTicket({
    required this.seatLabel,
    required this.payload,
    required this.signature,
    required this.keyId,
    required this.rotatingSecret,
  });

  final String seatLabel;

  /// The canonical body plus the signature. What goes in the QR, minus the
  /// freshness code — that is regenerated on the traveller's device every
  /// thirty seconds and never stored.
  final String payload;

  final List<int> signature;
  final int keyId;

  /// Seeds the rotating code. A screenshot still scans; its code is frozen,
  /// which is exactly what fails the freshness check (ADR-0007).
  final List<int> rotatingSecret;
}

/// Signs tickets. **Server-side only** — the private key never leaves us, and
/// devices carry public keys so they can verify offline at the roadside.
abstract interface class TicketIssuer {
  Future<List<SignedTicket>> issue({
    required BookingRef bookingRef,
    required String departureId,
    required DateTime departsAt,
    required String routeCode,
    required String operatorCode,
    required List<({String seatLabel, String passengerName})> seats,
  });
}
