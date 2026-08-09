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

      final layout = _layoutFrom(body);
      if (layout == null) return _badRequest(trace, 'preset');

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
SeatLayout? _layoutFrom(Map<String, Object?> body) {
  final preset = body['preset'];
  if (preset is String) {
    final base = switch (preset) {
      'bus_standard_49' => SeatLayout.busStandard49(),
      'bus_vip_front' => SeatLayout.busVipFront(),
      'air_two_class' => SeatLayout.airTwoClass(),
      _ => null,
    };
    if (base == null) return null;

    // Row count is the one thing an operator almost always adjusts: a preset
    // is a 49-seater and theirs is a 51. Overriding it here beats making them
    // open the section builder for one number.
    final rows = body['rows'];
    if (rows is! int || base.sections.isEmpty) return base;

    return SeatLayout(
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
    );
  }

  final sections = body['sections'];
  if (sections is! List || sections.isEmpty) return null;

  final parsed = <CabinSection>[];
  for (final entry in sections) {
    if (entry is! Map) return null;
    final s = entry.cast<String, Object?>();
    final rows = s['rows'];
    final abreast = s['abreast'];
    if (rows is! int || rows < 1 || abreast is! String) return null;

    parsed.add(
      CabinSection(
        code: s['code'] as String? ?? 'STD',
        labelKey: s['labelKey'] as String? ?? 'seat.class.standard',
        rows: rows,
        abreast: abreast,
        startRow: s['startRow'] as int? ?? 1,
      ),
    );
  }

  return SeatLayout(
    version: 1,
    mode: body['mode'] == 'air' ? TransportMode.air : TransportMode.bus,
    sections: parsed,
    blocked: {for (final b in (body['blocked'] as List? ?? const [])) '$b'},
  );
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
