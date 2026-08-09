import 'dart:convert';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';

/// A signed, verifiable departure to run the scanner against with no server.
///
/// Real tickets, real Ed25519 signatures, real rotating codes — so the demo
/// exercises the same code path production does. A demo that fakes the verdict
/// proves nothing.
final class DemoDeparture {
  const DemoDeparture({
    required this.manifest,
    required this.verifier,
    required this.tickets,
    required this.secrets,
  });

  final BoardingManifest manifest;
  final Ed25519TicketVerifier verifier;

  /// The QR string each passenger's phone would display.
  final Map<String, String> tickets;

  /// Per-ticket rotating secrets, so the demo can render a live code.
  final Map<String, List<int>> secrets;

  static const departureId = 'dep-bzv-pnr-0600';
  static const _seed = 'bel-dev-ticket-signing-seed-0000';

  static final _passengers = <({String ref, String seat, String name})>[
    (ref: '7QK4M2', seat: '14A', name: 'Aline Mabiala'),
    (ref: '7QK4M2', seat: '14B', name: 'Pascal Nkouka'),
    (ref: 'ZZ1188', seat: '2C', name: 'Marie Kimbembe'),
    (ref: 'H4T9RB', seat: '5A', name: 'Jean-Marc Obami'),
    (ref: 'H4T9RB', seat: '5B', name: 'Sylvie Loubaki'),
    (ref: 'K2M8PQ', seat: '9D', name: 'Antoine Bikindou'),
    (ref: 'R7V3XN', seat: '11C', name: 'Chantal Ngoma'),
    (ref: 'T5W2YZ', seat: '3A', name: 'Firmin Massamba'),
  ];

  static Future<DemoDeparture> build({DateTime? departsAt}) async {
    final departure =
        departsAt ?? DateTime.now().toUtc().add(const Duration(minutes: 25));

    final signer = await Ed25519TicketSigner.fromSeed(
      utf8.encode(_seed).sublist(0, 32),
    );
    final verifier = Ed25519TicketVerifier({1: await signer.publicKeyBytes()});

    final entries = <String, ManifestEntry>{};
    final tickets = <String, String>{};
    final secrets = <String, List<int>>{};

    for (final p in _passengers) {
      final key = BoardingManifest.keyFor(p.ref, p.seat);
      final secret = utf8.encode('secret:$key');
      secrets[key] = secret;

      entries[key] = ManifestEntry(
        bookingRef: p.ref,
        seatLabel: p.seat,
        passengerName: p.name,
        rotatingSecret: secret,
      );

      final payload = TicketPayload(
        bookingRef: p.ref,
        seatLabel: p.seat,
        departureId: departureId,
        departsAt: departure,
        routeCode: 'BZV>PNR',
        operatorCode: 'ODN',
        passengerName: p.name,
        keyId: 1,
      );
      final signature = await signer.sign(payload.signingBytes());
      // Prepared up front, exactly as the scanner does after decoding a scan.
      await verifier.prepare(
        message: payload.signingBytes(),
        signature: signature,
        keyId: 1,
      );
      tickets[key] = payload.encode(signature);
    }

    // A ticket for a different coach, so MAUVAIS DÉPART is demonstrable.
    final wrong = TicketPayload(
      bookingRef: 'W1R0NG',
      seatLabel: '1A',
      departureId: 'dep-bzv-pnr-1400',
      departsAt: departure.add(const Duration(hours: 8)),
      routeCode: 'BZV>PNR',
      operatorCode: 'ODN',
      passengerName: 'Denis Bouiti',
      keyId: 1,
    );
    final wrongSig = await signer.sign(wrong.signingBytes());
    await verifier.prepare(
      message: wrong.signingBytes(),
      signature: wrongSig,
      keyId: 1,
    );
    tickets['WRONG_DEPARTURE'] = wrong.encode(wrongSig);

    // A ticket refunded after the manifest was pinned.
    final voidedKey = BoardingManifest.keyFor('T5W2YZ', '3A');

    return DemoDeparture(
      manifest: BoardingManifest(
        departureId: departureId,
        operatorCode: 'ODN',
        departsAt: departure,
        pinnedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 12)),
        entries: entries,
        voidedTicketRefs: {voidedKey},
      ),
      verifier: verifier,
      tickets: tickets,
      secrets: secrets,
    );
  }
}
