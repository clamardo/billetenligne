import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/departures/{id}/redemptions` — what the door did.
///
/// The other half of the pinned manifest (ADR-0022). The scanner boards with
/// the radio off and queues every boarding in its own outbox; this is where
/// the outbox empties, whenever there is signal — in the yard at the far end,
/// or that evening on the agency's wifi.
///
/// **A batch, and idempotent.** A device that could not reach us retries the
/// whole outbox, two conductors may work two doors of the same coach, and the
/// row that settles a dispute is the earliest one — so a repeat is dropped
/// rather than allowed to overwrite the time somebody actually boarded.
///
/// **The device's clock is the one recorded**, not ours. It is the only clock
/// that was at the door, and a boarding stamped with the hour it happened to
/// sync is evidence of nothing.
///
/// The answer names what was accepted and what this coach has never heard of,
/// and **both leave the device's outbox**: a ticket that is not on this
/// departure will not start being on it, and an outbox that retries forever
/// is a handset flat by eleven.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.boardingScan);
  if (denied != null) return denied;

  final trace = context.read<String>();

  final List<BoardingUploadDto> uploads;
  try {
    final body = await context.request.json() as Map<String, Object?>;
    uploads = [
      for (final row in (body['boardings'] as List? ?? const []))
        BoardingUploadDto.fromJson(row as Map<String, Object?>),
    ];
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  } on TypeError {
    return _badRequest(trace, 'boardings');
  }

  final boardings = <Boarding>[];
  for (final u in uploads) {
    // `REF/SEAT`, which is how the scanner has indexed a ticket since the
    // first version of the manifest. A key with no seat in it names a whole
    // booking, and a booking is not what boards — a party of three is three
    // people, of whom two may have missed the coach.
    final slash = u.key.indexOf('/');
    if (slash <= 0 || slash == u.key.length - 1) {
      return _badRequest(trace, 'key');
    }
    if (u.mode != 'scan' && u.mode != 'manual') {
      return _badRequest(trace, 'mode');
    }
    boardings.add(
      Boarding(
        bookingRef: u.key.substring(0, slash),
        seatLabel: u.key.substring(slash + 1),
        scannedAt: u.scannedAt,
        mode: u.mode,
        deviceId: u.deviceId,
        codeWasStale: u.codeWasStale,
      ),
    );
  }

  final result = await context.read<Services>().console.recordBoardings(
    operatorId: context.read<TenantScope>().operatorId,
    departureId: id,
    scannedByUserId: context.read<Principal>().userId,
    boardings: boardings,
  );

  return Response.json(
    body: BoardingUploadResultDto(
      recorded: result.recorded,
      unknown: result.unknown,
    ).toJson(),
    headers: {BelHeaders.traceId: trace},
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
