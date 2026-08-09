import 'dart:convert';

import '../shared/failure.dart';
import '../shared/result.dart';

final class MalformedTicket extends DomainFailure {
  const MalformedTicket(this.reason);
  final String reason;
  @override
  String get code => 'ticket.malformed';
  @override
  Map<String, Object?> get params => {'reason': reason};
  @override
  String toString() => 'MalformedTicket($reason)';
}

/// What a ticket QR actually contains.
///
/// Self-contained and signed, so a conductor's device can verify it with **no
/// network at all** — a lookup-by-reference design fails the roadside test,
/// which is the one that matters (ADR-0007).
///
/// Every field earns its place: the conductor needs the passenger and seat to
/// read aloud, the departure to reject a wrong-day ticket, and the operator to
/// know whose coach this is. Nothing else travels — a QR is not a database.
final class TicketPayload {
  const TicketPayload({
    required this.bookingRef,
    required this.seatLabel,
    required this.departureId,
    required this.departsAt,
    required this.routeCode,
    required this.operatorCode,
    required this.passengerName,
    required this.keyId,
    this.version = currentVersion,
    this.issuer = defaultIssuer,
  });

  /// Bumped only on a breaking format change. Present so the format *can*
  /// change — a scanner in the field must be able to reject a payload it does
  /// not understand rather than misread it.
  static const currentVersion = 1;
  static const defaultIssuer = 'BEL';

  /// A QR above ~300 bytes gets dense enough that a cracked screen in daylight
  /// starts failing to scan. That is the real constraint, not storage.
  static const maxEncodedBytes = 300;

  final int version;
  final String issuer;
  final String bookingRef;
  final String seatLabel;
  final String departureId;
  final DateTime departsAt;
  final String routeCode;
  final String operatorCode;

  /// Truncated: enough for a conductor to match a face to a manifest, not a
  /// full identity record. A QR that leaks a passport number is a liability.
  final String passengerName;

  final int keyId;

  /// The exact bytes that get signed.
  ///
  /// Deterministic and canonical — the same payload must always produce the
  /// same bytes on the server that signs it and the device that verifies it,
  /// or every signature check fails for reasons nobody can reproduce.
  List<int> signingBytes() => utf8.encode(_canonical());

  String _canonical() => [
    '$version',
    issuer,
    bookingRef,
    seatLabel,
    departureId,
    '${departsAt.toUtc().millisecondsSinceEpoch ~/ 1000}',
    routeCode,
    operatorCode,
    _escape(passengerName),
    '$keyId',
  ].join('|');

  /// The string that goes into the QR: canonical payload, a dot, then the
  /// signature. Chosen over CBOR because it is trivially inspectable in a
  /// support conversation and already comfortably inside the size budget —
  /// `version` is what buys us the option to change it later.
  String encode(List<int> signature) =>
      '${_canonical()}.${base64Url.encode(signature)}';

  static Result<({TicketPayload payload, List<int> signature}), MalformedTicket>
  decode(String raw) {
    final dot = raw.lastIndexOf('.');
    if (dot <= 0 || dot == raw.length - 1) {
      return const Err(MalformedTicket('missing signature separator'));
    }

    final body = raw.substring(0, dot);
    final List<int> signature;
    try {
      signature = base64Url.decode(raw.substring(dot + 1));
    } on FormatException {
      return const Err(MalformedTicket('signature is not base64url'));
    }

    final parts = body.split('|');
    if (parts.length != 10) {
      return Err(MalformedTicket('expected 10 fields, got ${parts.length}'));
    }

    final version = int.tryParse(parts[0]);
    if (version == null) return const Err(MalformedTicket('bad version'));
    if (version != currentVersion) {
      // Refuse rather than guess. A scanner that misreads a future format is
      // worse than one that says "update me".
      return Err(MalformedTicket('unsupported version $version'));
    }

    final epoch = int.tryParse(parts[5]);
    final keyId = int.tryParse(parts[9]);
    if (epoch == null) return const Err(MalformedTicket('bad departure time'));
    if (keyId == null) return const Err(MalformedTicket('bad key id'));

    return Ok((
      payload: TicketPayload(
        version: version,
        issuer: parts[1],
        bookingRef: parts[2],
        seatLabel: parts[3],
        departureId: parts[4],
        departsAt: DateTime.fromMillisecondsSinceEpoch(
          epoch * 1000,
          isUtc: true,
        ),
        routeCode: parts[6],
        operatorCode: parts[7],
        passengerName: _unescape(parts[8]),
        keyId: keyId,
      ),
      signature: signature,
    ));
  }

  /// `|` is the field separator, so a passenger called "Jean|Marc" would
  /// otherwise shift every field after it and produce a confidently wrong
  /// ticket. Backslash first, or the escape itself can be forged.
  static String _escape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('|', r'\p');

  static String _unescape(String s) =>
      s.replaceAll(r'\p', '|').replaceAll(r'\\', r'\');

  @override
  String toString() => 'TicketPayload($bookingRef, $seatLabel, $routeCode)';
}
