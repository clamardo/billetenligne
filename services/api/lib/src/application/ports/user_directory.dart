/// A traveller's account, as the application layer knows it.
///
/// Not a DTO and not a database row: it carries what a use case needs to make
/// a decision, which is why there is no `createdAt` here and no `disabledAt`
/// on the DTO. The two shapes drift for good reasons and pretending they are
/// one type is how a `passwordHash` eventually reaches a client.
final class Account {
  const Account({
    required this.id,
    required this.language,
    this.authUid,
    this.email,
    this.phone,
    this.fullName,
    this.emailVerifiedAt,
    this.phoneVerifiedAt,
    this.disabledAt,
    this.staff,
    this.platformRole,
  });

  final String id;
  final String language;

  /// The Firebase UID. We choose it — it is [id] — rather than letting
  /// Firebase mint one, because the alternative is a round trip to Firebase in
  /// the middle of a database transaction, and a failure there would leave an
  /// account nobody can sign in to.
  final String? authUid;

  final String? email;
  final String? phone;
  final String? fullName;

  final DateTime? emailVerifiedAt;
  final DateTime? phoneVerifiedAt;

  /// Set by the admin console. A disabled account still owns its bookings and
  /// its tickets — this is a refusal to sign in, not an erasure.
  final DateTime? disabledAt;

  /// The operator this person works for, if any. Null for a traveller, which
  /// is almost everybody.
  ///
  /// Read from `operator_staff` on **every** authenticated request rather than
  /// carried in the Firebase token. A custom claim is a hint for routing; the
  /// database is the authority (ADR-0018), and the difference matters the hour
  /// somebody is dismissed — their token is still valid for the rest of it.
  final StaffMembership? staff;

  /// `super_admin` | `operations` | `viewer`, for our own people. Null for
  /// everybody else, which is everybody.
  ///
  /// Read from `platform_staff` on every authenticated request, for the same
  /// reason [staff] is: a custom claim is a hint for routing, the database is
  /// the authority (ADR-0018), and the difference matters the hour somebody
  /// leaves. Their token is still valid for the rest of it.
  final String? platformRole;

  bool get isPlatformStaff => platformRole != null;

  bool get isDisabled => disabledAt != null;
}

/// What somebody may do, and for whom.
final class StaffMembership {
  const StaffMembership({
    required this.operatorId,
    required this.roles,
    this.stationIds = const [],
  });

  final String operatorId;
  final List<String> roles;

  /// A vendor is scoped to their station(s): the Pointe-Noire agent must not
  /// be able to open the Brazzaville till. Empty means every station.
  final List<String> stationIds;
}

/// Accounts, keyed the three ways they are actually looked up.
///
/// Every method here runs on the identity surface (`DbScope.identity`), which
/// has no grant on anything that can be sold (migration 0007).
abstract interface class UserDirectory {
  /// Resolves a verified Firebase UID to our account. The hot path: this runs
  /// on every authenticated request.
  Future<Account?> byAuthUid(String authUid);

  /// Resolves our own account id. Used where a caller has already been
  /// identified by something other than a token — the second-factor exchange,
  /// which holds a half-session naming an account but no Firebase UID yet.
  Future<Account?> byId(String id);

  /// The account for a **verified** address, creating one if this is the first
  /// time we have seen it.
  ///
  /// Sign-up and sign-in are one operation on purpose. Separating them means
  /// answering "is this address registered?" before the code is checked, and
  /// that answer is exactly what lets a stranger enumerate our customers.
  ///
  /// Returns the account and whether it was created.
  Future<({Account account, bool created})> forVerifiedEmail({
    required String email,
    required String language,
  });

  /// The same, for a verified E.164 number. Second channel (ADR-0019), same
  /// storage, same guarantees.
  Future<({Account account, bool created})> forVerifiedPhone({
    required String phone,
    required String language,
  });

  /// An account for somebody standing at a counter.
  ///
  /// **Deliberately not verified.** A vendor typing a traveller's number
  /// identifies them; it does not authenticate them, and the difference is
  /// what `phone_verified_at` exists to record. The stamp lands the first
  /// time its owner answers a code — at which point this becomes their
  /// account, with the ticket the vendor sold them already in it.
  ///
  /// This is what keeps agency and app sales in one reconciliation: a counter
  /// sale takes the same hold through the same code path as a phone sale
  /// (`0002_inventory_booking.sql`), and it can only do that if the buyer is
  /// a user like any other.
  Future<Account> forCounterSale({
    required String phone,
    String? fullName,
    String language = 'fr',
  });

  /// Records that we saw them. Best-effort and deliberately not awaited on the
  /// request path — a failure to update a timestamp must never fail a booking.
  Future<void> touch(String userId);
}
