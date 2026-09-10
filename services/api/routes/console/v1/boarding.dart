import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/boarding?date=YYYY-MM-DD` — today's coaches (ADR-0022).
/// `GET /console/v1/boarding?from=…&to=…` — the same list over a span.
///
/// **A second list rather than a filter on the dispatcher's.** That one is
/// read under `booking.read`, and a conductor does not have it: `conductor` is
/// `{boarding.scan}` and nothing else, deliberately, because the handset most
/// likely to be left on a seat should be the one that can read the least.
/// Widening `booking.read` to reach this screen would have handed every
/// conductor the whole day's load factors on every coach the company runs.
///
/// So this row carries route, hour, yard and how many people are expected —
/// the four things somebody standing in a yard at half past five needs to pick
/// their coach — and no money, no held seats and no passenger names.
///
/// **A span, because a rota is not a day.** A driver asking *what am I on next
/// week?* was asking a question this endpoint could not be made to answer one
/// call at a time: seven round trips on a yard's signal is a screen that never
/// finishes. Each row now says whether the caller is rostered on it and as
/// what, which is what turns a board into a plan.
///
/// [_maxSpan] days, and the refusal names the field. The cap is not a
/// performance guess — it is the honest limit of what this list means. A
/// company materialises departures a few weeks out, so a request for six
/// months returns a plan that is mostly silence and reads as *you are not
/// working*, which is worse than being told the question was too big.
///
/// The list is small and it is the thing standing between a conductor and a
/// working door, so it is **never cached**: pinning the wrong departure is
/// discovered at the coach door, by a queue.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.boardingScan);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final q = context.request.uri.queryParameters;

  // `date` still works, and will keep working: the handsets in the field are
  // sideloaded APKs an agency updates when somebody drives to the office.
  final single = _date(q['date']);
  final from = single ?? _date(q['from']);
  final to = single ?? _date(q['to']) ?? from;

  if (from == null || to == null) {
    return _badRequest(trace, q['from'] == null && single == null ? 'from' : 'to');
  }
  if (to.isBefore(from)) return _badRequest(trace, 'to');
  if (to.difference(from).inDays >= _maxSpan) return _badRequest(trace, 'to');

  final departures = await context.read<Services>().console.boardingPlan(
    operatorId: scope.operatorId,
    from: from,
    to: to,
    // Whose plan this is. It decides what each row *says*, never which rows
    // there are — see the port.
    staffUserId: context.read<Principal>().userId,
  );

  return Response.json(
    body: {
      'departures': [
        for (final d in departures)
          BoardingDepartureDto(
            id: d.id,
            routeCode: d.routeCode,
            originCity: d.originCity,
            destinationCity: d.destinationCity,
            departsAt: d.departsAt,
            expected: d.expected,
            capacity: d.capacity,
            status: d.status,
            stationName: d.stationName,
            crewRole: d.crewRole,
          ).toJson(),
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// Thirty-one days: a calendar month, whichever month it is.
const _maxSpan = 31;

DateTime? _date(String? raw) => raw == null ? null : DateTime.tryParse(raw);

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
