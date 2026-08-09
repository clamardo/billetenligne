import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

final class PassengerDto {
  const PassengerDto({
    required this.fullName,
    this.phone,
    this.idNumber,
    this.seatLabel,
  });

  final String fullName;

  /// Distinct from the purchaser's account. This one field is what makes
  /// "buy a ticket for my mother" a first-class flow rather than a hack —
  /// the ticket is delivered to her by SMS and she needs no account.
  final String? phone;

  final String? idNumber;
  final String? seatLabel;

  Map<String, Object?> toJson() => Wire.compact({
    'fullName': fullName,
    'phone': phone,
    'idNumber': idNumber,
    'seatLabel': seatLabel,
  });

  factory PassengerDto.fromJson(Map<String, Object?> json) => PassengerDto(
    fullName: Wire.requireString(json['fullName'], 'fullName'),
    phone: json['phone'] as String?,
    idNumber: json['idNumber'] as String?,
    seatLabel: json['seatLabel'] as String?,
  );
}

/// Claim seats on a departure.
///
/// The `Idempotency-Key` header — not a body field — makes a retry safe. A
/// repeat with the same key returns the *existing* hold, never a second one,
/// so a user on a flaky connection cannot accumulate holds on seats they
/// cannot pay for (ADR-0012 rule 7).
final class CreateHoldRequest {
  const CreateHoldRequest({
    required this.departureId,
    required this.seatLabels,
    this.quantity,
  });

  final String departureId;

  /// Empty for operators selling unnumbered inventory — then [quantity]
  /// carries the ask instead.
  final List<String> seatLabels;

  final int? quantity;

  int get seatCount =>
      seatLabels.isNotEmpty ? seatLabels.length : (quantity ?? 1);

  Map<String, Object?> toJson() => Wire.compact({
    'departureId': departureId,
    'seatLabels': seatLabels.isEmpty ? null : seatLabels,
    'quantity': quantity,
  });

  factory CreateHoldRequest.fromJson(Map<String, Object?> json) =>
      CreateHoldRequest(
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        seatLabels: (json['seatLabels'] as List?)?.cast<String>() ?? const [],
        quantity: json['quantity'] as int?,
      );
}

final class HoldDto {
  const HoldDto({
    required this.id,
    required this.departureId,
    required this.seatLabels,
    required this.expiresAt,
    required this.total,
    required this.fare,
    required this.serviceFee,
    required this.state,
  });

  final String id;
  final String departureId;
  final List<String> seatLabels;

  /// The countdown the payment screen renders. Sent as an instant rather than
  /// a remaining duration, so a slow response cannot make the timer lie.
  final DateTime expiresAt;

  final Money total;
  final Money fare;
  final Money serviceFee;
  final String state;

  Duration remaining(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'departureId': departureId,
    'seatLabels': seatLabels,
    'expiresAt': Wire.instant(expiresAt),
    'total': Wire.money(total),
    'fare': Wire.money(fare),
    'serviceFee': Wire.money(serviceFee),
    'state': state,
  };

  factory HoldDto.fromJson(Map<String, Object?> json) => HoldDto(
    id: Wire.requireString(json['id'], 'id'),
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    seatLabels: (json['seatLabels'] as List?)?.cast<String>() ?? const [],
    expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
    total: Wire.readMoney(json['total'], field: 'total'),
    fare: Wire.readMoney(json['fare'], field: 'fare'),
    serviceFee: Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
    state: Wire.requireString(json['state'], 'state'),
  );
}

final class BookingDto {
  const BookingDto({
    required this.id,
    required this.ref,
    required this.state,
    required this.departureId,
    required this.operatorName,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.passengers,
    required this.total,
    required this.createdAt,
    this.tickets = const [],
    this.involuntaryChange = false,
    this.refundPolicySummaryKey,
    this.fare,
    this.serviceFee,
    this.paymentCode,
    this.paymentDeadline,
  });

  final String id;

  /// `BEL-7QK4M2`. Read aloud over a bad line, typed by a station agent.
  final String ref;

  final String state;
  final String departureId;
  final String operatorName;
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final List<PassengerDto> passengers;
  final Money total;
  final DateTime createdAt;
  final List<TicketDto> tickets;

  /// True when the operator caused a change (breakdown, cancellation, long
  /// delay). Permanently exempts the booking from fees and fare differences,
  /// and shows as "Modifié par l'opérateur" in the traveller's history.
  final bool involuntaryChange;

  final String? refundPolicySummaryKey;

  /// The itemised halves of [total]. A receipt read aloud at a counter has to
  /// be checkable, and a single number is not.
  ///
  /// Nullable because a booking summarised in a history list does not need
  /// them, and the wire rule is that absent and null mean the same thing.
  final Money? fare;
  final Money? serviceFee;

  /// What the traveller reads to the vendor to pay for a reservation
  /// (`04-payments.md` §4.4).
  ///
  /// **Present only while unpaid.** It is a bearer — whoever holds it can pay
  /// for and collect this booking — so it is erased the moment the money is
  /// taken, unlike [ref], which is an identifier that never expires and
  /// grants nothing.
  final String? paymentCode;

  /// When the seats go back on sale if nobody pays. Server-decided: three API
  /// instances with three slightly different clocks must not disagree about
  /// whether a reservation is still payable.
  final DateTime? paymentDeadline;

  bool get isPaid => state == 'confirmed';

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'ref': ref,
    'state': state,
    'departureId': departureId,
    'operatorName': operatorName,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'departsAt': Wire.instant(departsAt),
    'arrivesAt': Wire.instant(arrivesAt),
    'passengers': [for (final p in passengers) p.toJson()],
    'total': Wire.money(total),
    'createdAt': Wire.instant(createdAt),
    'tickets': tickets.isEmpty ? null : [for (final t in tickets) t.toJson()],
    'involuntaryChange': involuntaryChange,
    'refundPolicySummaryKey': refundPolicySummaryKey,
    'fare': fare == null ? null : Wire.money(fare!),
    'serviceFee': serviceFee == null ? null : Wire.money(serviceFee!),
    'paymentCode': paymentCode,
    'paymentDeadline':
        paymentDeadline == null ? null : Wire.instant(paymentDeadline!),
  });

  factory BookingDto.fromJson(Map<String, Object?> json) => BookingDto(
    id: Wire.requireString(json['id'], 'id'),
    ref: Wire.requireString(json['ref'], 'ref'),
    state: Wire.requireString(json['state'], 'state'),
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    operatorName: Wire.requireString(json['operatorName'], 'operatorName'),
    originCity: Wire.requireString(json['originCity'], 'originCity'),
    destinationCity: Wire.requireString(
      json['destinationCity'],
      'destinationCity',
    ),
    departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
    arrivesAt: Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
    passengers: Wire.readList(
      json['passengers'],
      PassengerDto.fromJson,
      field: 'passengers',
    ),
    total: Wire.readMoney(json['total'], field: 'total'),
    createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
    tickets: Wire.readList(
      json['tickets'],
      TicketDto.fromJson,
      field: 'tickets',
    ),
    involuntaryChange: json['involuntaryChange'] as bool? ?? false,
    refundPolicySummaryKey: json['refundPolicySummaryKey'] as String?,
    fare: json['fare'] == null
        ? null
        : Wire.readMoney(json['fare'], field: 'fare'),
    serviceFee: json['serviceFee'] == null
        ? null
        : Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
    paymentCode: json['paymentCode'] as String?,
    paymentDeadline: Wire.readInstantOrNull(
      json['paymentDeadline'],
      field: 'paymentDeadline',
    ),
  );
}

/// A ticket, as delivered to a device.
///
/// Everything needed to render and verify it offline travels in this object —
/// a ticket that needs the network to display is not a ticket (ADR-0003).
final class TicketDto {
  const TicketDto({
    required this.id,
    required this.bookingRef,
    required this.seatLabel,
    required this.passengerName,
    required this.qrPayload,
    required this.rotatingSecret,
    required this.keyId,
    required this.issuedAt,
    this.voidedAt,
  });

  final String id;
  final String bookingRef;
  final String seatLabel;
  final String passengerName;

  /// base45-encoded, Ed25519-signed CBOR. Under 300 bytes so the QR stays
  /// low-density and scans fast on a cracked screen in daylight (ADR-0007).
  final String qrPayload;

  /// Seeds the 30-second rotating code shown beneath the QR. A screenshot
  /// still scans; its code is frozen, which is what fails the freshness check.
  final String rotatingSecret;

  final int keyId;
  final DateTime issuedAt;

  /// Set at refund *approval*, not completion — so a refunded ticket cannot
  /// board while the money is still in flight.
  final DateTime? voidedAt;

  bool get isVoid => voidedAt != null;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'bookingRef': bookingRef,
    'seatLabel': seatLabel,
    'passengerName': passengerName,
    'qrPayload': qrPayload,
    'rotatingSecret': rotatingSecret,
    'keyId': keyId,
    'issuedAt': Wire.instant(issuedAt),
    'voidedAt': voidedAt == null ? null : Wire.instant(voidedAt!),
  });

  factory TicketDto.fromJson(Map<String, Object?> json) => TicketDto(
    id: Wire.requireString(json['id'], 'id'),
    bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
    seatLabel: Wire.requireString(json['seatLabel'], 'seatLabel'),
    passengerName: Wire.requireString(json['passengerName'], 'passengerName'),
    qrPayload: Wire.requireString(json['qrPayload'], 'qrPayload'),
    rotatingSecret: Wire.requireString(
      json['rotatingSecret'],
      'rotatingSecret',
    ),
    keyId: Wire.requireInt(json['keyId'], 'keyId'),
    issuedAt: Wire.readInstant(json['issuedAt'], field: 'issuedAt'),
    voidedAt: Wire.readInstantOrNull(json['voidedAt'], field: 'voidedAt'),
  );
}


/// Turn a hold into an unpaid reservation.
///
/// The passenger list is the body; the *price* is not, and never is. A seat
/// can carry its own fare — a VIP row is a price modifier on the layout — and
/// a client-supplied number is a client-supplied discount.
final class CreateBookingRequest {
  const CreateBookingRequest({
    required this.holdId,
    required this.passengers,
  });

  final String holdId;
  final List<PassengerDto> passengers;

  Map<String, Object?> toJson() => {
    'holdId': holdId,
    'passengers': [for (final p in passengers) p.toJson()],
  };

  factory CreateBookingRequest.fromJson(Map<String, Object?> json) =>
      CreateBookingRequest(
        holdId: Wire.requireString(json['holdId'], 'holdId'),
        passengers: Wire.readList(
          json['passengers'],
          PassengerDto.fromJson,
          field: 'passengers',
        ),
      );
}
