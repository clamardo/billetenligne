import 'dart:math';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/ticket_issuer.dart';
import '../infrastructure/config/ticket_signing_key.dart';

/// The real issuer: Ed25519 over the canonical payload.
///
/// Ed25519 rather than ECDSA for the reasons ADR-0007 gives — 64-byte
/// signatures, which is what keeps the whole QR under 300 bytes and therefore
/// low-density enough to scan off a cracked screen in direct sun, plus fast
/// verification on the weak ARM cores conductors actually carry.
final class Ed25519TicketIssuer implements TicketIssuer {
  Ed25519TicketIssuer({required Ed25519TicketSigner signer, Random? random})
    : _signer = signer,
      // Random.secure() and nothing else: the rotating secret is what makes a
      // screenshot detectably stale, and a predictable one makes it not.
      _random = random ?? Random.secure();

  final Ed25519TicketSigner _signer;
  final Random _random;

  /// Signs with [seed] — 32 bytes, from `TICKETS__SIGNINGSEED` by way of
  /// `TicketSigningKey`, which is the only thing that decides which seed a
  /// process gets and refuses the ones that must not be used.
  static Future<Ed25519TicketIssuer> fromSeed(
    List<int> seed, {
    Random? random,
  }) async => Ed25519TicketIssuer(
    signer: await Ed25519TicketSigner.fromSeed(seed),
    random: random,
  );

  /// A fixed seed for local development, so a ticket signed by yesterday's run
  /// still verifies today (ADR-0020).
  ///
  /// **Not a fallback.** It is in the source, so a ticket signed with it is
  /// forgeable by anybody who can read this file — which is fine for a stack
  /// serving departures that do not exist and is why `TicketSigningKey`
  /// refuses to let a process reach it while talking to a real database.
  /// Tests and the demo seeder call it directly, on purpose.
  static Future<Ed25519TicketIssuer> development({Random? random}) async =>
      fromSeed(TicketSigningKey.development, random: random);

  @override
  Future<Map<int, List<int>>> verificationKeys() async => {
    _signer.activeKeyId: await _signer.publicKeyBytes(),
  };

  @override
  Future<List<SignedTicket>> issue({
    required BookingRef bookingRef,
    required String departureId,
    required DateTime departsAt,
    required String routeCode,
    required String operatorCode,
    required List<({String seatLabel, String passengerName})> seats,
  }) async {
    final issued = <SignedTicket>[];

    for (final seat in seats) {
      final payload = TicketPayload(
        bookingRef: bookingRef.value,
        seatLabel: seat.seatLabel,
        departureId: departureId,
        departsAt: departsAt,
        routeCode: routeCode,
        operatorCode: operatorCode,
        passengerName: seat.passengerName,
        keyId: _signer.activeKeyId,
      );

      final signature = await _signer.sign(payload.signingBytes());

      issued.add(
        SignedTicket(
          seatLabel: seat.seatLabel,
          // Encoded WITHOUT a freshness code. The code is a function of the
          // secret and the current 30-second window, so storing one would
          // store an answer that is wrong within half a minute — the device
          // computes it, every time it redraws.
          payload: payload.encode(signature),
          signature: signature,
          keyId: _signer.activeKeyId,
          rotatingSecret: List<int>.generate(32, (_) => _random.nextInt(256)),
        ),
      );
    }

    return issued;
  }
}
