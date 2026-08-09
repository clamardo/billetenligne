import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  const traveller = Principal(userId: 'u1', authUid: 'a1');

  const vendor = Principal(
    userId: 'u2',
    authUid: 'a2',
    tenantId: 'op-odn',
    roles: ['vendor'],
    stationIds: ['st-bzv'],
  );

  const owner = Principal(
    userId: 'u3',
    authUid: 'a3',
    tenantId: 'op-odn',
    roles: ['org_owner'],
  );

  const opsStaff = Principal(
    userId: 'u4',
    authUid: 'a4',
    isPlatform: true,
    platformRole: 'operations',
  );

  const superAdmin = Principal(
    userId: 'u5',
    authUid: 'a5',
    isPlatform: true,
    platformRole: 'super_admin',
  );

  group('a scope cannot be conjured from nothing', () {
    test('a traveller has no tenant scope', () {
      expect(TenantScope.forPrincipal(traveller), isNull);
    });

    test('an operator user gets one', () {
      expect(TenantScope.forPrincipal(vendor)?.operatorId, 'op-odn');
    });

    test('platform staff cannot obtain a tenant scope', () {
      // Deliberately separate types: a repository taking a TenantScope can
      // never be handed platform authority by accident.
      expect(TenantScope.forPrincipal(opsStaff), isNull);
    });

    test('an operator user cannot obtain platform scope', () {
      expect(PlatformScope.forPrincipal(owner, reason: 'x'), isNull);
    });

    test('platform scope requires a stated reason', () {
      // "Why" is the question an audit answers, and it cannot be
      // reconstructed afterwards.
      expect(PlatformScope.forPrincipal(opsStaff, reason: ''), isNull);
      expect(PlatformScope.forPrincipal(opsStaff, reason: '   '), isNull);
      expect(
        PlatformScope.forPrincipal(opsStaff, reason: 'support ticket #412'),
        isNotNull,
      );
    });
  });

  group('capabilities, not role names', () {
    test('a vendor can sell and refund within their cap', () {
      final scope = TenantScope.forPrincipal(vendor)!;
      expect(scope.can(Capability.bookingSell), isTrue);
      expect(scope.can(Capability.bookingRefund), isTrue);
      expect(scope.can(Capability.tillOpen), isTrue);
    });

    test('a vendor cannot refund above the cap or approve a payout', () {
      final scope = TenantScope.forPrincipal(vendor)!;
      expect(scope.can(Capability.bookingRefundAboveCap), isFalse);
      expect(scope.can(Capability.payoutApprove), isFalse);
      expect(scope.can(Capability.staffManage), isFalse);
    });

    test('only the owner can redirect the money', () {
      // Settlement-account takeover is the highest-value fraud against a
      // platform like this, so exactly one role can do it.
      final ownerScope = TenantScope.forPrincipal(owner)!;
      expect(ownerScope.can(Capability.settlementAccountEdit), isTrue);

      for (final role in Capability.operatorRoles.keys.where(
        (r) => r != 'org_owner',
      )) {
        final caps = Capability.forRoles([role]);
        expect(
          caps.contains(Capability.settlementAccountEdit),
          isFalse,
          reason: '$role must not change the settlement account',
        );
      }
    });

    test('a conductor can only scan', () {
      final caps = Capability.forRoles(['conductor']);
      expect(caps, {Capability.boardingScan});
    });

    test('roles are additive — a small operator wears several hats', () {
      // In a five-coach operator the owner is also the finance office and
      // often the dispatcher.
      final caps = Capability.forRoles(['vendor', 'dispatcher']);
      expect(caps.contains(Capability.bookingSell), isTrue);
      expect(caps.contains(Capability.disruptionDeclare), isTrue);
    });

    test('an unknown role grants nothing', () {
      expect(Capability.forRoles(['wizard']), isEmpty);
    });
  });

  group('station scoping', () {
    test('a vendor is bound to their own station', () {
      final scope = TenantScope.forPrincipal(vendor)!;
      expect(scope.coversStation('st-bzv'), isTrue);
      // The Pointe-Noire vendor must not be able to open the Brazzaville till.
      expect(scope.coversStation('st-pnr'), isFalse);
    });

    test('an unscoped role covers every station', () {
      expect(TenantScope.forPrincipal(owner)!.coversStation('st-pnr'), isTrue);
    });
  });

  group('platform roles are deliberately few', () {
    test('there are exactly three', () {
      // Ten roles for eight people is theatre, and theatre that makes people
      // share logins is worse than no separation at all.
      expect(Capability.platformRoles.keys, [
        'super_admin',
        'operations',
        'viewer',
      ]);
    });

    test('four-eyes on money comes from thresholds, not role count', () {
      final ops = Capability.forRoles(['operations'], platform: true);
      final admin = Capability.forRoles(['super_admin'], platform: true);

      expect(ops.contains(Capability.bookingRefund), isTrue);
      expect(ops.contains(Capability.bookingRefundAboveCap), isFalse);
      expect(ops.contains(Capability.payoutApprove), isFalse);

      expect(admin.contains(Capability.payoutApprove), isTrue);
      expect(admin.contains(Capability.bookingRefundAboveCap), isTrue);
    });

    test('a viewer can read and nothing else', () {
      final caps = Capability.forRoles(['viewer'], platform: true);
      expect(caps.contains(Capability.bookingRead), isTrue);
      expect(caps.contains(Capability.bookingRefund), isFalse);
      expect(caps.contains(Capability.operatorSuspend), isFalse);
    });

    test('only super_admin can offboard an operator', () {
      expect(
        Capability.forRoles([
          'operations',
        ], platform: true).contains(Capability.operatorOffboard),
        isFalse,
      );
      expect(
        Capability.forRoles([
          'super_admin',
        ], platform: true).contains(Capability.operatorOffboard),
        isTrue,
      );
    });
  });

  group('session variables — what the database actually enforces', () {
    test('a tenant scope sets its own id and never the platform flag', () {
      final vars = SessionVariables.forTenant(
        TenantScope.forPrincipal(vendor)!,
      );
      expect(vars.toSettings(), {
        'app.tenant_id': 'op-odn',
        'app.platform': 'off',
      });
    });

    test('platform scope sets the flag and no tenant', () {
      final vars = SessionVariables.forPlatform(
        PlatformScope.forPrincipal(superAdmin, reason: 'incident 12')!,
      );
      expect(vars.toSettings(), {'app.tenant_id': '', 'app.platform': 'on'});
    });

    test('the default sees nothing', () {
      // A code path that forgets to scope must fail closed, never open. RLS
      // reads these settings, and an empty tenant matches no tenant-scoped row.
      expect(SessionVariables.none.toSettings(), {
        'app.tenant_id': '',
        'app.platform': 'off',
      });
    });
  });

  group('failures reach the client as named codes', () {
    test('a domain failure keeps its code and params', () {
      const failure = SeatUnavailable(['14A', '14B']);
      final err = Problem.fromFailure(failure, traceId: 't1');

      expect(err.code, 'hold.seat_unavailable');
      expect(err.params['seats'], '14A, 14B');
      expect(err.messageKey, 'errors.hold.seat_unavailable');
      expect(err.traceId, 't1');
    });

    test('an expired hold is 410, not 400 — the client did nothing wrong', () {
      expect(Problem.statusFor(ErrorCode.holdExpired), 410);
      expect(Problem.statusFor(ErrorCode.holdExpiredDuringPayment), 410);
    });

    test('a taken seat is 409', () {
      expect(Problem.statusFor(ErrorCode.seatUnavailable), 409);
    });

    test('a declined payment is 422, not 500', () {
      // Well-formed request, refused by the rules. A 500 here would tell the
      // client to retry blindly and would page someone at 03:00.
      expect(Problem.statusFor(ErrorCode.paymentInsufficientFunds), 422);
      expect(Problem.statusFor(ErrorCode.refundOutsideWindow), 422);
    });

    test('a PSP outage is 503 so clients back off', () {
      expect(Problem.statusFor(ErrorCode.paymentPspUnavailable), 503);
    });

    test('an internal error carries a trace id and no detail', () {
      final err = Problem.internal(traceId: '01JABC');
      expect(err.traceId, '01JABC');
      expect(
        err.params,
        isEmpty,
        reason: 'a stack trace leaks internals and is in the wrong language',
      );
    });

    test('every payment failure code maps to a real status', () {
      for (final code in PaymentFailureCode.values) {
        final status = Problem.statusFor(code.wire);
        expect(status, greaterThanOrEqualTo(400));
        expect(status, lessThan(600));
      }
    });
  });
}
