import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import 'problem.dart';
import 'tenant_scope.dart';

/// Capability checks, at the point of use.
///
/// Per route rather than per surface, because `booking.sell` and
/// `fleet.manage` are held by different people: a vendor sells and cannot
/// touch the fleet, a fleet manager configures coaches and cannot open a till
/// (ADR-0011). A blanket check one layer up would be the coarsest possible
/// answer to the most granular question in the product.
///
/// Returns the refusal, or null to proceed. Written as a returned response
/// rather than a thrown exception so the check reads in line with the handler:
///
/// ```dart
/// final denied = Require.capability(context, Capability.bookingSell);
/// if (denied != null) return denied;
/// ```
abstract final class Require {
  /// The caller holds [capability] for the operator this request is scoped to.
  ///
  /// The refusal **names the capability**. A bare 403 sends an operator's
  /// admin to us asking why their vendor cannot do something, and the answer
  /// is always "they need this role" — so we may as well say it.
  static Response? capability(RequestContext context, String capability) {
    final scope = context.read<TenantScope>();
    if (scope.can(capability)) return null;

    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(
        capability: capability,
        traceId: context.read<String>(),
      ).toJson(),
    );
  }

  /// The caller may act at [stationId].
  ///
  /// A vendor is scoped to their station: the Pointe-Noire agent must not be
  /// able to open the Brazzaville till. An empty station list means every
  /// station, which is what an owner or a dispatcher has.
  static Response? station(RequestContext context, String stationId) {
    final scope = context.read<TenantScope>();
    if (scope.coversStation(stationId)) return null;

    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(
        capability: 'station:$stationId',
        traceId: context.read<String>(),
      ).toJson(),
    );
  }
}
