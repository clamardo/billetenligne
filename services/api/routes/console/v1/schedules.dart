import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/schedules` — the timetables.
/// `POST /console/v1/schedules` — write one, or materialise one.
///
/// A pattern is "the 06:00, Monday to Friday, on this route, at this fare".
/// Materialising it is what turns it into departures a traveller can actually
/// buy — and **until this endpoint existed, departures came from hand-written
/// SQL**, which is why it is the piece the pilot was blocked on.
///
/// Two properties are worth stating:
///
///   * **Re-materialising is a no-op**, not a duplicate. A dispatcher who taps
///     twice must not put two coaches on one road, and the response says how
///     many already existed rather than silently reporting nothing.
///   * **Dates the rule matched but could not be filled are named.** No
///     vehicle assigned, or the assigned one is in the workshop. A silently
///     missing Thursday is a coach nobody can book and an operator who thinks
///     they are selling it.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final patterns = await console.patterns(scope.operatorId);
      return Response.json(
        body: {
          'items': [
            for (final p in patterns)
              {
                'id': p.id,
                'routeId': p.routeId,
                'routeCode': p.routeCode,
                'rrule': p.recurrence.toRRule(),
                'departureTime': p.departureTime,
                'fare': Wire.money(p.fare),
                'validFrom': _date(p.validFrom),
                if (p.validUntil != null) 'validUntil': _date(p.validUntil!),
                'active': p.active,
                if (p.vehicleId != null) 'vehicleId': p.vehicleId,
              },
          ],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.departureManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;

      // Materialise and save are the same verb on the same resource, told
      // apart by which fields arrived — the same shape the vehicles route
      // uses for status changes.
      if (body['materialise'] == true) {
        return _materialise(console, scope, body, trace);
      }
      return _save(console, scope, body, trace);

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Future<Response> _save(
  dynamic console,
  TenantScope scope,
  Map<String, Object?> body,
  String trace,
) async {
  final routeId = body['routeId'];
  final rrule = body['rrule'];
  final time = body['departureTime'];
  final fareMinor = body['fareMinor'];
  final validFrom = body['validFrom'];

  if (routeId is! String) return _badRequest(trace, 'routeId');
  if (rrule is! String) return _badRequest(trace, 'rrule');
  if (time is! String || !RegExp(r'^\d{2}:\d{2}$').hasMatch(time)) {
    return _badRequest(trace, 'departureTime');
  }
  if (fareMinor is! int || fareMinor < 1) {
    return _badRequest(trace, 'fareMinor');
  }
  if (validFrom is! String) return _badRequest(trace, 'validFrom');

  final from = DateTime.tryParse(validFrom);
  if (from == null) return _badRequest(trace, 'validFrom');

  // The subset we honour, refusing anything else by name. A partial RRULE
  // implementation that ignored the parts it did not understand would not
  // fail — it would materialise the wrong departures and sell seats on them.
  final recurrence = Recurrence.parse(rrule);
  if (recurrence case Err(:final failure)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: failure.code,
        params: failure.params,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final until = body['validUntil'];
  final saved = await console.savePattern(
    operatorId: scope.operatorId,
    routeId: routeId,
    recurrence: recurrence.valueOrNull!,
    departureTime: time,
    fare: Money(fareMinor, Market.current.currency),
    validFrom: from,
    id: body['id'] as String?,
    vehicleId: body['vehicleId'] as String?,
    validUntil: until is String ? DateTime.tryParse(until) : null,
  );

  if (saved == null) return _badRequest(trace, 'routeId');

  return Response.json(
    statusCode: HttpStatus.created,
    body: {
      'id': saved.id,
      'routeId': saved.routeId,
      'routeCode': saved.routeCode,
      'rrule': saved.recurrence.toRRule(),
      'departureTime': saved.departureTime,
      'fare': Wire.money(saved.fare),
      'validFrom': _date(saved.validFrom),
      'active': saved.active,
    },
    headers: {BelHeaders.traceId: trace},
  );
}

Future<Response> _materialise(
  dynamic console,
  TenantScope scope,
  Map<String, Object?> body,
  String trace,
) async {
  final patternId = body['id'];
  final from = DateTime.tryParse('${body['from']}');
  final to = DateTime.tryParse('${body['to']}');

  if (patternId is! String) return _badRequest(trace, 'id');
  if (from == null) return _badRequest(trace, 'from');
  if (to == null || to.isBefore(from)) return _badRequest(trace, 'to');

  // A bounded horizon. Materialising a decade would write hundreds of
  // thousands of seat rows in one transaction, and nobody sells a coach seat
  // two years out — the practical window is the next few weeks.
  if (to.difference(from).inDays > 366) return _badRequest(trace, 'to');

  final report = await console.materialise(
    operatorId: scope.operatorId,
    patternId: patternId,
    from: from,
    to: to,
  );

  return Response.json(
    body: {
      'created': report.created,
      // Reported rather than folded into `created`. A dispatcher who taps
      // twice should see "nothing new", not a number that looks like a
      // second coach.
      'alreadyExisted': report.alreadyExisted,
      'skipped': [
        for (final s in report.skipped)
          {'date': _date(s.date), 'reason': s.reason},
      ],
    },
    headers: {BelHeaders.traceId: trace},
  );
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
