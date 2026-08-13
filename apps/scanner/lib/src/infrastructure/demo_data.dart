import 'dart:convert';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/simulated_scan.dart';

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

  /// A coach on a road with a stop on it, because that is what this corridor
  /// is: Brazzaville to Pointe-Noire through Dolisie. Two of the eight bought
  /// a piece of it (ADR-0025) — one riding only as far as Dolisie, one
  /// boarding there — and everybody else has the whole road, which is what a
  /// leg being null means.
  static final _passengers =
      <({String ref, String seat, String name, String? from, String? to})>[
        (
          ref: '7QK4M2',
          seat: '14A',
          name: 'Aline Mabiala',
          from: null,
          to: null,
        ),
        (
          ref: '7QK4M2',
          seat: '14B',
          name: 'Pascal Nkouka',
          from: null,
          to: null,
        ),
        (
          ref: 'ZZ1188',
          seat: '2C',
          name: 'Marie Kimbembe',
          from: 'BZV',
          to: 'DOL',
        ),
        (
          ref: 'H4T9RB',
          seat: '5A',
          name: 'Jean-Marc Obami',
          from: null,
          to: null,
        ),
        (
          ref: 'H4T9RB',
          seat: '5B',
          name: 'Sylvie Loubaki',
          from: null,
          to: null,
        ),
        (
          ref: 'K2M8PQ',
          seat: '9D',
          name: 'Antoine Bikindou',
          from: 'DOL',
          to: 'PNR',
        ),
        (
          ref: 'R7V3XN',
          seat: '11C',
          name: 'Chantal Ngoma',
          from: null,
          to: null,
        ),
        (
          ref: 'T5W2YZ',
          seat: '3A',
          name: 'Firmin Massamba',
          from: null,
          to: null,
        ),
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
        // On the manifest, not in the QR: the payload is signed, so putting
        // the leg inside it would mean every ticket issued after the change
        // is refused by a scanner nobody has updated — for a fact the device
        // downloaded before the coach left the yard.
        boardsAt: p.from,
        alightsAt: p.to,
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
      // The QR a traveller's screen would be showing right now: payload,
      // signature, and the current freshness code. Their app regenerates it
      // every 30 seconds.
      tickets[key] = payload.encode(
        signature,
        freshnessCode: RotatingCode.current(
          secret: secret,
          now: DateTime.now().toUtc(),
          mac: const HmacSha256Authenticator(),
        ),
      );
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

  /// Canned scans for the debug simulator.
  ///
  /// Built here, in infrastructure, because this is where the signed tickets
  /// and the rotating secrets live. The presentation layer receives plain
  /// [SimulatedScan] values and never learns that a DemoDeparture exists —
  /// which is the dependency direction the layer check enforces.
  List<SimulatedScan> simulatedScans({DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    const mac = HmacSha256Authenticator();

    String ticket(String ref, String seat) =>
        tickets[BoardingManifest.keyFor(ref, seat)]!;

    String codeAt(String ref, String seat, DateTime when) =>
        RotatingCode.current(
          secret: secrets[BoardingManifest.keyFor(ref, seat)]!,
          now: when,
          mac: mac,
        );

    return [
      SimulatedScan(
        title: 'Billet valide',
        subtitle: 'Aline Mabiala · 14A · code à jour',
        payload: ticket('7QK4M2', '14A'),
        code: codeAt('7QK4M2', '14A', at),
        kind: SimulatedScanKind.genuine,
      ),
      SimulatedScan(
        title: 'Deuxième passager',
        subtitle: 'Pascal Nkouka · 14B · même réservation',
        payload: ticket('7QK4M2', '14B'),
        code: codeAt('7QK4M2', '14B', at),
        kind: SimulatedScanKind.genuine,
      ),
      SimulatedScan(
        title: "Capture d'écran",
        subtitle: 'Le QR est authentique, le code est figé',
        payload: ticket('ZZ1188', '2C'),
        // Frozen ten minutes ago — exactly what a screenshot looks like.
        code: codeAt('ZZ1188', '2C', at.subtract(const Duration(minutes: 10))),
        kind: SimulatedScanKind.screenshot,
      ),
      SimulatedScan(
        title: 'Autre départ',
        subtitle: 'Denis Bouiti · billet du 14:00',
        payload: tickets['WRONG_DEPARTURE']!,
        kind: SimulatedScanKind.otherDeparture,
      ),
      SimulatedScan(
        title: 'Billet remboursé',
        subtitle: 'Firmin Massamba · 3A · annulé',
        payload: ticket('T5W2YZ', '3A'),
        code: codeAt('T5W2YZ', '3A', at),
        kind: SimulatedScanKind.refunded,
      ),
      SimulatedScan(
        title: 'Billet falsifié',
        subtitle: 'Siège modifié après signature',
        payload: ticket('K2M8PQ', '9D').replaceFirst('9D', '1A'),
        kind: SimulatedScanKind.forged,
      ),
      SimulatedScan(
        title: 'Code-barres quelconque',
        subtitle: 'Étiquette de bouteille, affiche, autre app',
        payload: 'https://example.cg/promo',
        kind: SimulatedScanKind.foreign,
      ),
    ];
  }
}
