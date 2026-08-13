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

/// One place a coach touches between its two endpoints.
///
/// `offsetMinutes` is measured from the departure rather than from the
/// previous stop, because that is the number on the timetable a dispatcher
/// already has: *Dolisie, cinq heures quinze* is a fact about the journey,
/// while "two hours ten after Madingou" is arithmetic somebody has to do
/// before they can tell whether it is right.
///
/// The two flags are the detail every naive model gets wrong: a yard people
/// are only ever set down at must not be offerable as a place to get on.
/// A piece of a road the operator sells, and what it costs (ADR-0025).
///
/// **Cities on the wire, positions in the database.** A console form is two
/// dropdowns of town names; a position is an index into a road the client
/// does not own and must not be able to guess wrong. The server resolves one
/// into the other, which is also where the boarding rules are applied — so a
/// client that offers a set-down-only stop as an origin is told, rather than
/// quietly writing a segment nobody can use.
final class SegmentFareDto {
  const SegmentFareDto({
    required this.fromCity,
    required this.toCity,
    required this.fareMinor,
    this.fromPosition,
    this.toPosition,
  });

  final String fromCity;
  final String toCity;

  /// Minor units, and no currency — the same shape a timetable fare travels
  /// in, for the same reason: **the currency of a road is not the client's to
  /// choose.** The server attaches the market's, so a console that thought it
  /// was pricing in euros cannot put a euro row on an XAF road.
  final int fareMinor;

  /// Sent by the server, ignored on the way up. Reading them lets a console
  /// tell two visits to the same town apart; writing them would let a client
  /// name a piece of a road it had not looked at.
  final int? fromPosition;
  final int? toPosition;

  Map<String, Object?> toJson() => Wire.compact({
    'fromCity': fromCity,
    'toCity': toCity,
    'fareMinor': fareMinor,
    'fromPosition': fromPosition,
    'toPosition': toPosition,
  });

  factory SegmentFareDto.fromJson(Map<String, Object?> json) => SegmentFareDto(
    fromCity: Wire.requireString(json['fromCity'], 'fromCity'),
    toCity: Wire.requireString(json['toCity'], 'toCity'),
    fareMinor: Wire.requireInt(json['fareMinor'], 'fareMinor'),
    fromPosition: json['fromPosition'] as int?,
    toPosition: json['toPosition'] as int?,
  );
}

final class RouteStopDto {
  const RouteStopDto({
    required this.cityCode,
    required this.offsetMinutes,
    this.stationId,
    this.stationName,
    this.allowsBoarding = true,
    this.allowsAlighting = true,
  });

  final String cityCode;
  final int offsetMinutes;

  /// Which yard, when the operator has named one. Optional in a way the
  /// endpoints are not — a coach that pauses at a roadside town may have no
  /// terminal there, and inventing one puts an address on a ticket nobody
  /// can find.
  final String? stationId;

  /// Resolved for reading. Sent by the server, ignored on the way up: a
  /// client that could rename a station by writing this field would be
  /// editing the catalogue through a route form.
  final String? stationName;

  final bool allowsBoarding;
  final bool allowsAlighting;

  RouteStop toDomain() => RouteStop(
    cityCode: cityCode,
    offsetMinutes: offsetMinutes,
    stationId: stationId,
    allowsBoarding: allowsBoarding,
    allowsAlighting: allowsAlighting,
  );

  Map<String, Object?> toJson() => Wire.compact({
    'cityCode': cityCode,
    'offsetMinutes': offsetMinutes,
    'stationId': stationId,
    'stationName': stationName,
    'allowsBoarding': allowsBoarding,
    'allowsAlighting': allowsAlighting,
  });

  factory RouteStopDto.fromJson(Map<String, Object?> json) => RouteStopDto(
    cityCode: Wire.requireString(json['cityCode'], 'cityCode'),
    offsetMinutes: Wire.requireInt(json['offsetMinutes'], 'offsetMinutes'),
    stationId: json['stationId'] as String?,
    stationName: json['stationName'] as String?,
    allowsBoarding: json['allowsBoarding'] != false,
    allowsAlighting: json['allowsAlighting'] != false,
  );

  factory RouteStopDto.fromDomain(RouteStop stop, {String? stationName}) =>
      RouteStopDto(
        cityCode: stop.cityCode,
        offsetMinutes: stop.offsetMinutes,
        stationId: stop.stationId,
        stationName: stationName,
        allowsBoarding: stop.allowsBoarding,
        allowsAlighting: stop.allowsAlighting,
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
    this.stops = const [],
    this.segments = const [],
  });

  final String id;
  final String code;
  final String originCity;
  final String destinationCity;
  final int durationMinutes;
  final bool active;

  /// In order, from the first one after the origin. Empty is the ordinary
  /// case and not an absence of data — most roads in this market are two
  /// cities and a road between them.
  final List<RouteStopDto> stops;

  /// The pieces of this road that are on sale. Empty is the ordinary case
  /// and means the road sells end to end only — there is deliberately no
  /// pro-rata fallback, so an unpriced pair is simply not offered.
  final List<SegmentFareDto> segments;

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
    stops: Wire.readList(
      json['stops'] ?? const [],
      RouteStopDto.fromJson,
      field: 'stops',
    ),
    segments: Wire.readList(
      json['segments'] ?? const [],
      SegmentFareDto.fromJson,
      field: 'segments',
    ),
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
    this.boardsAt,
    this.alightsAt,
  });

  final String seatLabel;
  final String passengerName;
  final String bookingRef;
  final bool boarded;
  final String? phone;
  final DateTime? boardedAt;

  /// Where this passenger gets on and off, when it is not the whole road
  /// (ADR-0025). City codes, resolved by the server from the positions the
  /// booking was sold at — the conductor's list is the one place somebody
  /// finds out that seat 12A is free again after Dolisie.
  ///
  /// Null on a whole journey, which is every booking on a road with no priced
  /// legs, and is drawn as nothing rather than as the terminus repeated.
  final String? boardsAt;
  final String? alightsAt;

  factory ManifestPassengerDto.fromJson(
    Map<String, Object?> json,
  ) => ManifestPassengerDto(
    seatLabel: Wire.requireString(json['seatLabel'], 'seatLabel'),
    passengerName: Wire.requireString(json['passengerName'], 'passengerName'),
    bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
    boarded: json['boarded'] == true,
    phone: json['phone'] as String?,
    boardedAt: Wire.readInstantOrNull(json['boardedAt'], field: 'boardedAt'),
    boardsAt: json['boardsAt'] as String?,
    alightsAt: json['alightsAt'] as String?,
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

/// One seat on a pinned boarding manifest (ADR-0022).
final class BoardingTicketDto {
  const BoardingTicketDto({
    required this.bookingRef,
    required this.seatLabel,
    required this.passengerName,
    required this.rotatingSecret,
    this.boardsAt,
    this.alightsAt,
  });

  final String bookingRef;
  final String seatLabel;
  final String passengerName;

  /// Base64, because this is bytes on a JSON wire. It seeds the freshness
  /// code the traveller's screen regenerates every thirty seconds (ADR-0007),
  /// which is what makes a screenshot detectably stale — and what makes this
  /// response a credential rather than a passenger list.
  final String rotatingSecret;

  /// Where this passenger gets on and off, when they bought a piece of the
  /// road (ADR-0025). Absent is the whole journey.
  final String? boardsAt;
  final String? alightsAt;

  factory BoardingTicketDto.fromJson(
    Map<String, Object?> json,
  ) => BoardingTicketDto(
    bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
    seatLabel: Wire.requireString(json['seatLabel'], 'seatLabel'),
    passengerName: Wire.requireString(json['passengerName'], 'passengerName'),
    rotatingSecret: Wire.requireString(json['secret'], 'secret'),
    boardsAt: json['boardsAt'] as String?,
    alightsAt: json['alightsAt'] as String?,
  );
}

/// The departure a scanner pins before the coach leaves the yard (ADR-0022).
///
/// Downloaded once, on whatever signal there is, and then the door works with
/// the radio switched off: the verdict is a signature check against [keys], a
/// lookup in [tickets] and the device's own redemption log.
final class BoardingManifestDto {
  const BoardingManifestDto({
    required this.departureId,
    required this.operatorCode,
    required this.routeCode,
    required this.departsAt,
    required this.capacity,
    required this.tickets,
    required this.voided,
    required this.keys,
  });

  final String departureId;
  final String operatorCode;
  final String routeCode;
  final DateTime departsAt;
  final int capacity;
  final List<BoardingTicketDto> tickets;

  /// `REF/SEAT` for every ticket voided since it was issued. Carried
  /// explicitly because a signature stays valid forever: only the manifest
  /// knows the money went back.
  final List<String> voided;

  /// Ticket-signing public keys by key id, base64. Shipped with the manifest
  /// rather than compiled into the app, so a key can be rotated without a
  /// store release.
  final Map<int, String> keys;

  factory BoardingManifestDto.fromJson(
    Map<String, Object?> json,
  ) => BoardingManifestDto(
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    operatorCode: Wire.requireString(json['operatorCode'], 'operatorCode'),
    routeCode: Wire.requireString(json['routeCode'], 'routeCode'),
    departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
    capacity: Wire.requireInt(json['capacity'], 'capacity'),
    tickets: Wire.readList(
      json['tickets'],
      BoardingTicketDto.fromJson,
      field: 'tickets',
    ),
    voided: [
      for (final v in (json['voided'] as List? ?? const []))
        Wire.requireString(v, 'voided'),
    ],
    keys: {
      for (final e in (json['keys'] as Map? ?? const {}).entries)
        int.parse(e.key.toString()): Wire.requireString(e.value, 'keys'),
    },
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
