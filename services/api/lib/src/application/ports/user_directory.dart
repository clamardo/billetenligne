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

  bool get isDisabled => disabledAt != null;
}

/// Accounts, keyed the three ways they are actually looked up.
///
/// Every method here runs on the identity surface (`DbScope.identity`), which
/// has no grant on anything that can be sold (migration 0007).
abstract interface class UserDirectory {
  /// Resolves a verified Firebase UID to our account. The hot path: this runs
  /// on every authenticated request.
  Future<Account?> byAuthUid(String authUid);

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

  /// Records that we saw them. Best-effort and deliberately not awaited on the
  /// request path — a failure to update a timestamp must never fail a booking.
  Future<void> touch(String userId);
}
