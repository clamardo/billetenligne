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

  /// Writing and agreeing to an inter-operator protection agreement
  /// (`08-disruption.md` §5). Separate from `disruption.declare` because a
  /// dispatcher declares a breakdown at the roadside and must not, in the
  /// same moment, be able to commit their company to a standing rate with a
  /// competitor. Reading one needs only `booking.read` — the dispatcher has
  /// to see that option ③ exists before they can use it.
  static const protectionManage = 'protection.manage';
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

  /// Reading what the operator owes the platform this month, and choosing
  /// which rail to pay it with (`04-payments.md` §6.2 note). Separate from
  /// [financeRead] — that is the payout run, money coming in from us; this
  /// is the platform's own bill, money going the other way — and separate
  /// from [payoutApprove] and [settlementAccountEdit] for the same reason
  /// those two are separate from each other: a different weight of
  /// consequence than either.
  static const billingManage = 'billing.manage';

  // Platform
  static const operatorReview = 'platform.operator.review';
  static const operatorSuspend = 'platform.operator.suspend';
  static const operatorOffboard = 'platform.operator.offboard';
  static const paymentReconcile = 'platform.payment.reconcile';
  static const supportImpersonate = 'platform.support.impersonate';

  /// Confirming an operator's mobile-money account is real, so the rail can
  /// be offered to a traveller. A manual human judgement — "somebody who saw
  /// the merchant agreement" — not a route every reviewer holds by having
  /// `operator.review`: reviewing paperwork and moving somebody's payout
  /// destination are different weights of consequence.
  static const paymentAccountVerify = 'platform.payment_account.verify';

  /// Saying a coach has begun boarding, has left, or has arrived (J4).
  ///
  /// Held by the crew, which is the first capability `driver` has ever had —
  /// and it is deliberately not enough on its own. Closing a departure stops
  /// its sales, so the write additionally requires the person to be **on this
  /// coach**, from the roster 0049 built. A capability alone would let any
  /// driver in the company close any coach in it.
  ///
  /// Not folded into `departure.manage`: that is a dispatcher's authority
  /// over the plan — which coach, which crew — and this is the crew's
  /// statement about what has actually happened on the road. A dispatcher
  /// holds both, and may close a coach whose crew has no signal.
  static const departureClose = 'departure.close';

  /// Operator roles (ADR-0011). Most people hold several: in a five-coach
  /// operator the owner is also the finance office and often the dispatcher.
  static const operatorRoles = <String, Set<String>>{
    'org_owner': {
      bookingRead, bookingSell, bookingReschedule, bookingRefund,
      bookingRefundAboveCap, tillOpen, tillClose, departureManage,
      departureClose,
      departureCancel, disruptionDeclare, boardingScan, fleetManage,
      routeManage, pricingManage, policyManage, vitrineManage, staffManage,
      financeRead, payoutApprove, protectionManage,
      // The only role that can redirect where the money goes. Guarded further
      // by fresh 2FA and a 24 h cooling-off, because settlement-account
      // takeover is the highest-value fraud against a platform like this.
      settlementAccountEdit,
      billingManage,
    },
    'org_admin': {
      bookingRead,
      bookingSell,
      bookingReschedule,
      bookingRefund,
      tillOpen,
      tillClose,
      departureManage,
      departureClose,
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
      protectionManage,
      billingManage,
    },
    'finance': {bookingRead, financeRead, bookingRefundAboveCap, billingManage},
    'fleet_manager': {bookingRead, fleetManage},
    'dispatcher': {
      bookingRead,
      departureManage,
      departureClose,
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
    // The handset at the door, and the tap that says the coach has gone.
    'conductor': {boardingScan, departureClose},
    // **Deliberately empty**, and the only role here that is.
    //
    // A driver drives. They do not scan tickets — that is the conductor, and
    // on an intercity coach here they are usually two people — they do not
    // sell, and they have no reason to read a booking. What the role buys is
    // eligibility: only somebody holding it can be rostered onto a departure
    // (`CrewAssignment`), which is a fact about the roster rather than a key
    // to anything.
    //
    // An empty set is safer than a plausible one. The alternative on offer
    // was `bookingRead`, "so they can see who is on their coach", which is
    // read access to every booking in the company for the person whose phone
    // spends the day on a dashboard.
    //
    // J4 gives it its first and only entry. A driver says the coach has left
    // — the "close the departure" the business asked for — and that is still
    // not read access to anything: the write is refused unless they are
    // rostered on the coach in question.
    'driver': {departureClose},
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
      paymentAccountVerify,
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
      paymentAccountVerify,
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
