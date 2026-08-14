import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/fleet/layouts` — the templates this operator has drawn.
/// `POST /console/v1/fleet/layouts` — draw one, or version one.
///
/// **Templates, not per-vehicle layouts.** An operator with fourteen coaches
/// has two or three layouts (`06-fleet-and-routes.md` §1): draw each once,
/// point every coach at it. A fleet of fourteen becomes a twenty-minute setup
/// rather than a two-hour one, and the seat map an operator checks is the
/// seat map every one of those coaches sells.
///
/// A POST with a name that already exists creates a **new version** rather
/// than editing. Departures keep the layout they were sold with, so a template
/// change can never renumber a seat somebody already bought (ADR-0015).
///
/// `preset` is the fast path: most operators never open the editor. Four
/// presets cover what actually runs in Congo, and picking one takes ninety
/// seconds against the twenty minutes the section builder takes.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final layouts = await console.layouts(scope.operatorId);
      return Response.json(
        body: {
          'items': [
            for (final l in layouts)
              {
                'id': l.id,
                'name': l.name,
                'version': l.version,
                'capacity': l.capacity,
                'mode': l.mode,
                // Shown because editing a template in use creates a new
                // version, and an operator should see the blast radius before
                // they start.
                'vehicleCount': l.vehicleCount,
              },
          ],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.fleetManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final name = body['name'];
      if (name is! String || name.trim().isEmpty) {
        return _badRequest(trace, 'name');
      }

      final drawn = _layoutFrom(body);
      if (drawn.layout == null) return _badRequest(trace, drawn.field!);
      final layout = drawn.layout!;

      final saved = await console.saveLayout(
        operatorId: scope.operatorId,
        name: name.trim(),
        layout: layout,
      );

      return Response.json(
        statusCode: HttpStatus.created,
        body: {
          'id': saved.id,
          'name': saved.name,
          'version': saved.version,
          'capacity': saved.capacity,
          'mode': saved.mode,
          'vehicleCount': 0,
        },
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

/// A preset, or sections drawn by hand.
///
/// The presets are the ones that actually run in Congo
/// (`06-fleet-and-routes.md` §3.2), and they live in `bel_domain` so the
/// console's preview, the seat map and the manifest all draw the same coach.
({SeatLayout? layout, String? field}) _layoutFrom(Map<String, Object?> body) {
  final preset = body['preset'];
  if (preset is String) {
    final base = switch (preset) {
      'bus_standard_49' => SeatLayout.busStandard49(),
      'bus_vip_front' => SeatLayout.busVipFront(),
      'air_two_class' => SeatLayout.airTwoClass(),
      _ => null,
    };
    if (base == null) return (layout: null, field: 'preset');

    // Row count is the one thing an operator almost always adjusts: a preset
    // is a 49-seater and theirs is a 51. Overriding it here beats making them
    // open the section builder for one number.
    final rows = body['rows'];
    if (rows == null || base.sections.isEmpty)
      return (layout: base, field: null);
    // A row count that is not a number, or is zero or negative, is a typo
    // rather than an instruction. It used to be ignored, which meant an
    // operator asking for 51 rows and silently getting the preset's 11.
    if (rows is! int || rows < 1 || rows > _maxRows) {
      return (layout: null, field: 'rows');
    }

    return (
      layout: SeatLayout(
        version: base.version,
        mode: base.mode,
        sections: [
          CabinSection(
            code: base.sections.first.code,
            labelKey: base.sections.first.labelKey,
            rows: rows,
            abreast: base.sections.first.abreast,
            startRow: base.sections.first.startRow,
            numbering: base.sections.first.numbering,
            pitchCm: base.sections.first.pitchCm,
            modifier: base.sections.first.modifier,
          ),
          ...base.sections.skip(1),
        ],
        features: base.features,
        blocked: base.blocked,
      ),
      field: null,
    );
  }

  final sections = body['sections'];
  if (sections is! List || sections.isEmpty) {
    return (layout: null, field: 'sections');
  }
  if (sections.length > _maxSections) {
    return (layout: null, field: 'sections');
  }

  final parsed = <CabinSection>[];
  for (var i = 0; i < sections.length; i++) {
    final entry = sections[i];
    if (entry is! Map) return (layout: null, field: 'sections[$i]');
    final s = entry.cast<String, Object?>();

    final rows = s['rows'];
    if (rows is! int || rows < 1 || rows > _maxRows) {
      return (layout: null, field: 'sections[$i].rows');
    }

    // The check that matters. `abc` used to throw a FormatException out of a
    // capacity getter — a 500 on a request whose only fault was a typo — and
    // `9+9` walked off the end of the seat-letter table with a RangeError.
    final abreast = s['abreast'];
    if (abreast is! String || !Abreast.isValid(abreast)) {
      return (layout: null, field: 'sections[$i].abreast');
    }

    final startRow = s['startRow'] ?? 1;
    if (startRow is! int || startRow < 1) {
      return (layout: null, field: 'sections[$i].startRow');
    }

    final numbering = switch (s['numbering']) {
      null || 'rowLetter' => SeatNumbering.rowLetter,
      'sequential' => SeatNumbering.sequential,
      _ => null,
    };
    if (numbering == null) {
      return (layout: null, field: 'sections[$i].numbering');
    }

    final modifier = _modifierFrom(s['fareMultiplier'], s['fareSupplement']);
    if (modifier.invalid) {
      return (layout: null, field: 'sections[$i].fare');
    }

    final pitch = s['pitchCm'];
    if (pitch != null && (pitch is! int || pitch < 40 || pitch > 250)) {
      return (layout: null, field: 'sections[$i].pitchCm');
    }

    parsed.add(
      CabinSection(
        code: (s['code'] as String? ?? 'STD').trim(),
        labelKey: s['labelKey'] as String? ?? 'seat.class.standard',
        rows: rows,
        abreast: abreast,
        startRow: startRow,
        numbering: numbering,
        modifier: modifier.value,
        pitchCm: pitch as int?,
      ),
    );
  }

  final features = _featuresFrom(body['features']);
  if (features.invalid) return (layout: null, field: features.field);

  final layout = SeatLayout(
    version: 1,
    mode: body['mode'] == 'air' ? TransportMode.air : TransportMode.bus,
    sections: parsed,
    features: features.value,
    blocked: {for (final b in (body['blocked'] as List? ?? const [])) '$b'},
  );

  // A blocked seat that is not in the layout is not a harmless extra: it is a
  // capacity the operator believes they blocked and did not, and it surfaces
  // as a seat somebody buys on a coach with a wheel arch where it should be.
  // Refused rather than dropped, because dropping it is the silent version.
  final labels = layout.allSeatLabels().toSet();
  for (final b in layout.blocked) {
    if (!labels.contains(b)) return (layout: null, field: 'blocked');
  }

  // A layout with no sellable seat is a departure nobody can book. Refusing it
  // here beats discovering it when a dispatcher publishes a timetable.
  if (layout.capacity < 1) return (layout: null, field: 'sections');

  return (layout: layout, field: null);
}

/// Doors, stairs and the lavatory, as the console draws them.
///
/// A closed set of types, because each one has a glyph on the traveller's seat
/// map: a free-text type would render as a blank square on the one screen it
/// exists for. Coordinates are bounded rather than merely non-negative — an
/// operator's typo must not put a door at row four thousand and stretch every
/// seat map that draws it.
({List<LayoutFeature> value, bool invalid, String field}) _featuresFrom(
  Object? raw,
) {
  if (raw == null) return (value: const [], invalid: false, field: '');
  if (raw is! List) {
    return (value: const [], invalid: true, field: 'features');
  }

  final out = <LayoutFeature>[];
  for (var i = 0; i < raw.length; i++) {
    final f = raw[i];
    if (f is! Map)
      return (value: const [], invalid: true, field: 'features[$i]');

    final type = LayoutFeatureType.values
        .where((t) => t.name == f['type'])
        .firstOrNull;
    if (type == null) {
      return (value: const [], invalid: true, field: 'features[$i].type');
    }

    final row = f['row'];
    final col = f['col'];
    if (row is! int || row < 0 || row > _maxRows) {
      return (value: const [], invalid: true, field: 'features[$i].row');
    }
    if (col is! int || col < 0 || col > 10) {
      return (value: const [], invalid: true, field: 'features[$i].col');
    }

    out.add(LayoutFeature(type, row: row, col: col));
  }
  return (value: out, invalid: false, field: '');
}

/// Two ways to price a section, and never both.
///
/// A multiplier and a supplement together is not an argument about which one
/// wins — it is a request nobody meant to send, and answering it either way
/// puts a price on a seat the operator did not choose.
({PriceModifier? value, bool invalid}) _modifierFrom(
  Object? multiplier,
  Object? supplement,
) {
  if (multiplier != null && supplement != null) {
    return (value: null, invalid: true);
  }

  if (multiplier != null) {
    final value = multiplier is int ? multiplier.toDouble() : multiplier;
    // A VIP seat is worth more, not five hundred times more. The ceiling is
    // what stops a stray decimal point quoting a fare nobody can pay.
    if (value is! double || value <= 0 || value > 10) {
      return (value: null, invalid: true);
    }
    return (value: PriceModifier.multiplier(value), invalid: false);
  }

  if (supplement != null) {
    if (supplement is! int || supplement < 0) {
      return (value: null, invalid: true);
    }
    return (value: PriceModifier.supplementMinor(supplement), invalid: false);
  }

  return (value: null, invalid: false);
}

/// A coach has fewer than twenty rows and a wide-body fewer than sixty. The
/// cap is not about realism — it is about what one request may make the server
/// allocate, because every row becomes seat rows in the database on every
/// departure that uses the layout.
const _maxRows = 80;

/// Six cabins is more than any vehicle in this market has. A layout with forty
/// is somebody's script, not somebody's coach.
const _maxSections = 6;

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
