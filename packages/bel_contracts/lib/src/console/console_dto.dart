import 'package:bel_domain/bel_domain.dart';

import '../booking/booking_dto.dart';
import '../disruption/disruption_dto.dart';
import '../json/json_codec.dart';

/// Who the console is talking to, and what they may do.
///
/// The navigation is rendered from [capabilities], never from role names —
/// the same rule the server checks by (ADR-0011), so a vendor never sees a
/// Fleet tab and adding a role is a configuration row on both sides.
///
/// **This is a hint, not an authority.** Every route re-checks server-side,
/// because a client that decides what it may do is a client an attacker can
/// edit.
final class ConsoleIdentityDto {
  const ConsoleIdentityDto({
    required this.userId,
    required this.operatorId,
    required this.roles,
    required this.capabilities,
    required this.stationIds,
    this.language = 'fr',
  });

  final String userId;
  final String operatorId;
  final List<String> roles;
  final List<String> capabilities;

  /// Empty means every station. A vendor is scoped to theirs: the
  /// Pointe-Noire agent must not open the Brazzaville till.
  final List<String> stationIds;

  final String language;

  bool can(String capability) => capabilities.contains(capability);

  factory ConsoleIdentityDto.fromJson(Map<String, Object?> json) =>
      ConsoleIdentityDto(
        userId: Wire.requireString(json['userId'], 'userId'),
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        roles: (json['roles'] as List?)?.cast<String>() ?? const [],
        capabilities:
            (json['capabilities'] as List?)?.cast<String>() ?? const [],
        stationIds: (json['stationIds'] as List?)?.cast<String>() ?? const [],
        language: json['language'] as String? ?? 'fr',
      );
}

/// A seat layout template.
final class LayoutDto {
  const LayoutDto({
    required this.id,
    required this.name,
    required this.version,
    required this.capacity,
    required this.mode,
    required this.vehicleCount,
  });

  final String id;
  final String name;
  final int version;
  final int capacity;
  final String mode;

  /// How many coaches use it. Shown because saving a template again creates a
  /// new version rather than editing, and an operator should see the blast
  /// radius before they start.
  final int vehicleCount;

  String get displayName => '$name · v$version';

  factory LayoutDto.fromJson(Map<String, Object?> json) => LayoutDto(
    id: Wire.requireString(json['id'], 'id'),
    name: Wire.requireString(json['name'], 'name'),
    version: Wire.requireInt(json['version'], 'version'),
    capacity: Wire.requireInt(json['capacity'], 'capacity'),
    mode: json['mode'] as String? ?? 'bus',
    vehicleCount: json['vehicleCount'] as int? ?? 0,
  );
}

final class VehicleDto {
  const VehicleDto({
    required this.id,
    required this.registration,
    required this.layoutId,
    required this.layoutName,
    required this.capacity,
    required this.status,
    required this.sellable,
    this.nickname,
    this.model,
    this.amenities = const [],
  });

  final String id;
  final String registration;
  final String layoutId;
  final String layoutName;
  final int capacity;

  /// `active` | `maintenance` | `out_of_service` | `blocked_compliance`.
  final String status;

  final bool sellable;
  final String? nickname;
  final String? model;
  final List<String> amenities;

  factory VehicleDto.fromJson(Map<String, Object?> json) => VehicleDto(
    id: Wire.requireString(json['id'], 'id'),
    registration: Wire.requireString(json['registration'], 'registration'),
    layoutId: Wire.requireString(json['layoutId'], 'layoutId'),
    layoutName: Wire.requireString(json['layoutName'], 'layoutName'),
    capacity: Wire.requireInt(json['capacity'], 'capacity'),
    status: Wire.requireString(json['status'], 'status'),
    sellable: json['sellable'] == true,
    nickname: json['nickname'] as String?,
    model: json['model'] as String?,
    amenities: (json['amenities'] as List?)?.cast<String>() ?? const [],
  );
}

final class RouteDto {
  const RouteDto({
    required this.id,
    required this.code,
    required this.originCity,
    required this.destinationCity,
    required this.durationMinutes,
    required this.active,
  });

  final String id;
  final String code;
  final String originCity;
  final String destinationCity;
  final int durationMinutes;
  final bool active;

  factory RouteDto.fromJson(Map<String, Object?> json) => RouteDto(
    id: Wire.requireString(json['id'], 'id'),
    code: Wire.requireString(json['code'], 'code'),
    originCity: Wire.requireString(json['originCity'], 'originCity'),
    destinationCity: Wire.requireString(
      json['destinationCity'],
      'destinationCity',
    ),
    durationMinutes: Wire.requireInt(
      json['durationMinutes'],
      'durationMinutes',
    ),
    active: json['active'] != false,
  );
}

/// A timetable line: "the 06:00, Monday to Friday, on this route".
final class ScheduleDto {
  const ScheduleDto({
    required this.id,
    required this.routeId,
    required this.routeCode,
    required this.rrule,
    required this.departureTime,
    required this.fare,
    required this.validFrom,
    required this.active,
    this.vehicleId,
    this.validUntil,
  });

  final String id;
  final String routeId;
  final String routeCode;

  /// The canonical RRULE. A deliberate subset of RFC 5545 — the server
  /// refuses anything it cannot honour by name rather than ignoring it.
  final String rrule;

  /// `HH:mm`, local. Not an instant: "the 06:00" is a local fact about a
  /// timetable.
  final String departureTime;

  final Money fare;
  final DateTime validFrom;
  final DateTime? validUntil;
  final bool active;
  final String? vehicleId;

  factory ScheduleDto.fromJson(Map<String, Object?> json) => ScheduleDto(
    id: Wire.requireString(json['id'], 'id'),
    routeId: Wire.requireString(json['routeId'], 'routeId'),
    routeCode: Wire.requireString(json['routeCode'], 'routeCode'),
    rrule: Wire.requireString(json['rrule'], 'rrule'),
    departureTime: Wire.requireString(json['departureTime'], 'departureTime'),
    fare: Wire.readMoney(json['fare'], field: 'fare'),
    validFrom: DateTime.parse(
      Wire.requireString(json['validFrom'], 'validFrom'),
    ),
    validUntil: json['validUntil'] == null
        ? null
        : DateTime.parse(json['validUntil']! as String),
    active: json['active'] != false,
    vehicleId: json['vehicleId'] as String?,
  );
}

/// What materialising a timetable did.
final class MaterialisationDto {
  const MaterialisationDto({
    required this.created,
    required this.alreadyExisted,
    required this.skipped,
  });

  final int created;

  /// Re-running is a no-op, not a duplicate. Reported so a dispatcher who
  /// taps twice sees "nothing new" rather than a silent success that looks
  /// identical to the first run.
  final int alreadyExisted;

  /// Dates the rule matched but nothing could be created for. Named rather
  /// than dropped: a silently missing Thursday is a coach nobody can book.
  final List<({String date, String reason})> skipped;

  factory MaterialisationDto.fromJson(Map<String, Object?> json) =>
      MaterialisationDto(
        created: json['created'] as int? ?? 0,
        alreadyExisted: json['alreadyExisted'] as int? ?? 0,
        skipped: [
          for (final entry in (json['skipped'] as List? ?? const []))
            if (entry is Map)
              (date: '${entry['date']}', reason: '${entry['reason']}'),
        ],
      );
}

/// One line of the dispatcher's day.
final class DepartureBoardDto {
  const DepartureBoardDto({
    required this.id,
    required this.routeCode,
    required this.departsAt,
    required this.status,
    required this.capacity,
    required this.sold,
    required this.held,
    required this.available,
    this.vehicle,
    this.disruption,
  });

  final String id;
  final String routeCode;
  final DateTime departsAt;
  final String status;
  final int capacity;
  final int sold;

  /// Beside `sold`, never folded into it. A coach that is "48 of 49 sold" and
  /// one that is "20 sold, 28 held" are completely different situations
  /// twenty minutes before departure.
  final int held;

  final int available;
  final String? vehicle;

  /// What is happening to this coach, when something is. Present on the board
  /// itself rather than a row away, because the dispatcher's day view is the
  /// screen somebody is looking at when the phone call comes in.
  final DisruptionDto? disruption;

  factory DepartureBoardDto.fromJson(Map<String, Object?> json) =>
      DepartureBoardDto(
        id: Wire.requireString(json['id'], 'id'),
        routeCode: Wire.requireString(json['routeCode'], 'routeCode'),
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        status: Wire.requireString(json['status'], 'status'),
        capacity: Wire.requireInt(json['capacity'], 'capacity'),
        sold: Wire.requireInt(json['sold'], 'sold'),
        held: Wire.requireInt(json['held'], 'held'),
        available: Wire.requireInt(json['available'], 'available'),
        vehicle: json['vehicle'] as String?,
        disruption: json['disruption'] == null
            ? null
            : DisruptionDto.fromJson(
                (json['disruption'] as Map).cast<String, Object?>(),
              ),
      );
}

final class ManifestPassengerDto {
  const ManifestPassengerDto({
    required this.seatLabel,
    required this.passengerName,
    required this.bookingRef,
    required this.boarded,
    this.phone,
    this.boardedAt,
  });

  final String seatLabel;
  final String passengerName;
  final String bookingRef;
  final bool boarded;
  final String? phone;
  final DateTime? boardedAt;

  factory ManifestPassengerDto.fromJson(
    Map<String, Object?> json,
  ) => ManifestPassengerDto(
    seatLabel: Wire.requireString(json['seatLabel'], 'seatLabel'),
    passengerName: Wire.requireString(json['passengerName'], 'passengerName'),
    bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
    boarded: json['boarded'] == true,
    phone: json['phone'] as String?,
    boardedAt: Wire.readInstantOrNull(json['boardedAt'], field: 'boardedAt'),
  );
}

/// The document a conductor carries and a station manager signs.
final class ManifestDto {
  const ManifestDto({
    required this.departureId,
    required this.routeCode,
    required this.departsAt,
    required this.capacity,
    required this.sold,
    required this.boarded,
    required this.passengers,
  });

  final String departureId;
  final String routeCode;
  final DateTime departsAt;
  final int capacity;
  final int sold;

  /// A fact, not a claim: it comes from `redemptions`, which has one row per
  /// ticket ever and whose primary key is the double-boarding guard.
  final int boarded;

  final List<ManifestPassengerDto> passengers;

  factory ManifestDto.fromJson(Map<String, Object?> json) => ManifestDto(
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    routeCode: Wire.requireString(json['routeCode'], 'routeCode'),
    departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
    capacity: Wire.requireInt(json['capacity'], 'capacity'),
    sold: Wire.requireInt(json['sold'], 'sold'),
    boarded: Wire.requireInt(json['boarded'], 'boarded'),
    passengers: Wire.readList(
      json['passengers'],
      ManifestPassengerDto.fromJson,
      field: 'passengers',
    ),
  );
}

/// What the guichet answers with: a paid booking and its tickets.
final class CounterSaleDto {
  const CounterSaleDto({
    required this.id,
    required this.ref,
    required this.state,
    required this.total,
    required this.fare,
    required this.serviceFee,
    required this.passengers,
    required this.tickets,
  });

  final String id;
  final String ref;
  final String state;
  final Money total;
  final Money fare;
  final Money serviceFee;
  final List<PassengerDto> passengers;

  /// Present because the money moved. A ticket that exists before payment is
  /// a ticket that can board before payment.
  final List<({String id, String seatLabel, String qrPayload})> tickets;

  factory CounterSaleDto.fromJson(Map<String, Object?> json) => CounterSaleDto(
    id: Wire.requireString(json['id'], 'id'),
    ref: Wire.requireString(json['ref'], 'ref'),
    state: Wire.requireString(json['state'], 'state'),
    total: Wire.readMoney(json['total'], field: 'total'),
    fare: Wire.readMoney(json['fare'], field: 'fare'),
    serviceFee: Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
    passengers: Wire.readList(
      json['passengers'],
      (m) => PassengerDto(
        fullName: Wire.requireString(m['fullName'], 'fullName'),
        phone: m['phone'] as String?,
        seatLabel: m['seatLabel'] as String?,
      ),
      field: 'passengers',
    ),
    tickets: [
      for (final entry in (json['tickets'] as List? ?? const []))
        if (entry is Map)
          (
            id: '${entry['id']}',
            seatLabel: '${entry['seatLabel']}',
            qrPayload: '${entry['qrPayload']}',
          ),
    ],
  );
}
