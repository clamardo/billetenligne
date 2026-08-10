import 'dart:io';

import 'package:bel_api/src/application/ports/disruption_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/departures?date=YYYY-MM-DD` — the dispatcher's day.
///
/// Held seats are reported **beside** sold ones rather than folded into them.
/// A held seat is not revenue, and a dispatcher deciding whether to put a
/// second coach on the road needs to know which of the two they are looking
/// at — a coach that is "48 of 49 sold" and one that is "20 sold, 28 held" are
/// completely different situations twenty minutes before departure.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.bookingRead);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();

  final raw = context.request.uri.queryParameters['date'];
  final date = raw == null ? null : DateTime.tryParse(raw);
  if (date == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: const {'field': 'date'},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final services = context.read<Services>();

  final rows = await services.console.board(
    operatorId: scope.operatorId,
    // A LOCAL calendar day. "Departures on the 15th" is a local question, and
    // a UTC comparison puts the 06:00 coach on the wrong day.
    localDate: date,
  );

  // The window comes from the rows themselves rather than from a second
  // rendering of "which local day is this?". The board already answered that
  // question in the market's own zone, and asking it twice in two places is
  // how the two eventually disagree by an hour.
  final open = rows.isEmpty
      ? const <String, DisruptionRecord>{}
      : await services.disruptions.openFor(
          operatorId: scope.operatorId,
          from: rows.first.departsAt,
          to: rows.last.departsAt.add(const Duration(seconds: 1)),
        );

  return Response.json(
    body: {
      'date': raw,
      'items': [
        for (final row in rows)
          {
            'id': row.id,
            'routeCode': row.routeCode,
            'departsAt': Wire.instant(row.departsAt),
            'status': row.status,
            'capacity': row.capacity,
            'sold': row.sold,
            'held': row.held,
            'available': row.available,
            if (row.vehicleRegistration != null)
              'vehicle': row.vehicleRegistration,
            if (open[row.id] != null)
              'disruption': _disruptionJson(open[row.id]!),
          },
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      // Load factors change by the minute twenty minutes before departure.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// The declaration, as the board renders it. No prose: the kind and the cause
/// are catalog keys, and the note is the dispatcher's own words.
Map<String, Object?> _disruptionJson(DisruptionRecord record) => DisruptionDto(
  id: record.id,
  kind: record.disruption.kind,
  cause: record.disruption.cause,
  declaredAt: record.disruption.declaredAt,
  marksInvoluntary: record.marksInvoluntary,
  note: record.disruption.note,
  location: record.disruption.location,
  revisedDepartsAt: record.disruption.revisedDepartsAt,
  estimatedResolution: record.disruption.estimatedResolution,
).toJson();
