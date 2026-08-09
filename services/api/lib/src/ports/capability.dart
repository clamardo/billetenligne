/// Permissions are capability strings; roles are named bundles of them.
///
/// Every check is against a capability, never a role name — so adding a role
/// is a configuration row rather than a release (ADR-0011).
final class Capability {
  const Capability._();

  // Inventory and sales
  static const bookingRead = 'booking.read';
  static const bookingSell = 'booking.sell';
  static const bookingReschedule = 'booking.reschedule';
  static const bookingRefund = 'booking.refund';
  static const bookingRefundAboveCap = 'booking.refund.above_cap';

  // Cash desk
  static const tillOpen = 'till.open';
  static const tillClose = 'till.close';

  // Operations
  static const departureManage = 'departure.manage';
  static const departureCancel = 'departure.cancel';
  static const disruptionDeclare = 'disruption.declare';
  static const boardingScan = 'boarding.scan';

  // Configuration
  static const fleetManage = 'fleet.manage';
  static const routeManage = 'route.manage';
  static const pricingManage = 'pricing.manage';
  static const policyManage = 'policy.manage';
  static const vitrineManage = 'vitrine.manage';
  static const staffManage = 'staff.manage';

  // Money
  static const financeRead = 'finance.read';
  static const payoutApprove = 'payout.approve';
  static const settlementAccountEdit = 'operator.settlement_account.edit';

  // Platform
  static const operatorReview = 'platform.operator.review';
  static const operatorSuspend = 'platform.operator.suspend';
  static const operatorOffboard = 'platform.operator.offboard';
  static const paymentReconcile = 'platform.payment.reconcile';
  static const supportImpersonate = 'platform.support.impersonate';

  /// Operator roles (ADR-0011). Most people hold several: in a five-coach
  /// operator the owner is also the finance office and often the dispatcher.
  static const operatorRoles = <String, Set<String>>{
    'org_owner': {
      bookingRead, bookingSell, bookingReschedule, bookingRefund,
      bookingRefundAboveCap, tillOpen, tillClose, departureManage,
      departureCancel, disruptionDeclare, boardingScan, fleetManage,
      routeManage, pricingManage, policyManage, vitrineManage, staffManage,
      financeRead, payoutApprove,
      // The only role that can redirect where the money goes. Guarded further
      // by fresh 2FA and a 24 h cooling-off, because settlement-account
      // takeover is the highest-value fraud against a platform like this.
      settlementAccountEdit,
    },
    'org_admin': {
      bookingRead,
      bookingSell,
      bookingReschedule,
      bookingRefund,
      tillOpen,
      tillClose,
      departureManage,
      departureCancel,
      disruptionDeclare,
      boardingScan,
      fleetManage,
      routeManage,
      pricingManage,
      policyManage,
      vitrineManage,
      staffManage,
      financeRead,
    },
    'finance': {bookingRead, financeRead, bookingRefundAboveCap},
    'fleet_manager': {bookingRead, fleetManage},
    'dispatcher': {
      bookingRead,
      departureManage,
      departureCancel,
      disruptionDeclare,
    },
    'station_manager': {
      bookingRead,
      bookingSell,
      bookingReschedule,
      bookingRefund,
      tillOpen,
      tillClose,
      staffManage,
    },
    // The highest-volume role, and deliberately the narrowest one that can
    // still serve a customer at a counter.
    'vendor': {
      bookingRead,
      bookingSell,
      bookingReschedule,
      bookingRefund,
      tillOpen,
    },
    'conductor': {boardingScan},
    'viewer': {bookingRead, financeRead},
  };

  /// Our own staff. Three roles, not ten: ten roles for eight people is
  /// theatre, and theatre that makes people share logins is worse than no
  /// separation at all. Four-eyes on money comes from thresholds instead.
  static const platformRoles = <String, Set<String>>{
    'super_admin': {
      operatorReview,
      operatorSuspend,
      operatorOffboard,
      paymentReconcile,
      supportImpersonate,
      bookingRead,
      bookingRefund,
      bookingRefundAboveCap,
      payoutApprove,
      financeRead,
    },
    'operations': {
      operatorReview,
      operatorSuspend,
      paymentReconcile,
      supportImpersonate,
      bookingRead,
      bookingRefund,
      financeRead,
    },
    'viewer': {bookingRead, financeRead},
  };

  static Set<String> forRoles(Iterable<String> roles, {bool platform = false}) {
    final table = platform ? platformRoles : operatorRoles;
    return {for (final r in roles) ...?table[r]};
  }
}
