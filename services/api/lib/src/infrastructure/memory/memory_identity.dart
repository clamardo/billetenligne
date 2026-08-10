import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/auth_challenges.dart';
import '../../application/ports/user_directory.dart';

/// Accounts and challenges in a map. Used by the fakes composition — the one
/// that runs when no `DATABASE_URL` is set — and by every unit test.
///
/// It is a faithful twin of the Postgres adapter in the ways that decide
/// behaviour, and deliberately not in the ways that decide durability: the
/// conditional consume below returns false on a second call, exactly as the
/// `WHERE consumed_at IS NULL` does, because that is the property the use case
/// leans on.
final class MemoryUserDirectory implements UserDirectory {
  MemoryUserDirectory({Clock clock = const SystemClock()}) : _clock = clock;

  final Clock _clock;
  final Map<String, Account> _byId = {};
  var _next = 0;

  @override
  Future<Account?> byAuthUid(String authUid) async {
    for (final account in _byId.values) {
      if (account.authUid == authUid) return account;
    }
    return null;
  }

  @override
  Future<Account?> byId(String id) async => _byId[id];

  @override
  Future<({Account account, bool created})> forVerifiedEmail({
    required String email,
    required String language,
  }) async => _upsert(
    match: (a) => a.email == email,
    create: (id) => Account(
      id: id,
      authUid: id,
      email: email,
      language: language,
      emailVerifiedAt: _clock.now(),
    ),
    verify: (a) => a.emailVerifiedAt != null
        ? a
        : Account(
            id: a.id,
            authUid: a.authUid ?? a.id,
            email: a.email,
            phone: a.phone,
            fullName: a.fullName,
            language: a.language,
            emailVerifiedAt: _clock.now(),
            phoneVerifiedAt: a.phoneVerifiedAt,
            disabledAt: a.disabledAt,
          ),
  );

  @override
  Future<({Account account, bool created})> forVerifiedPhone({
    required String phone,
    required String language,
  }) async => _upsert(
    match: (a) => a.phone == phone,
    create: (id) => Account(
      id: id,
      authUid: id,
      phone: phone,
      language: language,
      phoneVerifiedAt: _clock.now(),
    ),
    verify: (a) => a.phoneVerifiedAt != null
        ? a
        : Account(
            id: a.id,
            authUid: a.authUid ?? a.id,
            email: a.email,
            phone: a.phone,
            fullName: a.fullName,
            language: a.language,
            emailVerifiedAt: a.emailVerifiedAt,
            phoneVerifiedAt: _clock.now(),
            disabledAt: a.disabledAt,
          ),
  );

  ({Account account, bool created}) _upsert({
    required bool Function(Account) match,
    required Account Function(String id) create,
    required Account Function(Account) verify,
  }) {
    for (final existing in _byId.values) {
      if (match(existing)) {
        final updated = verify(existing);
        _byId[updated.id] = updated;
        return (account: updated, created: false);
      }
    }

    final account = create('u-mem-${++_next}');
    _byId[account.id] = account;
    return (account: account, created: true);
  }

  @override
  Future<Account> forCounterSale({
    required String phone,
    String? fullName,
    String language = 'fr',
  }) async {
    for (final existing in _byId.values) {
      if (existing.phone == phone) return existing;
    }
    // No verification stamp: a vendor identifies a traveller, they do not
    // authenticate one.
    final account = Account(
      id: 'u-mem-${++_next}',
      authUid: 'u-mem-$_next',
      phone: phone,
      fullName: fullName,
      language: language,
    );
    _byId[account.id] = account;
    return account;
  }

  @override
  Future<void> touch(String userId) async {}

  /// Test seam: put a known account in place, disabled or otherwise.
  void seed(Account account) => _byId[account.id] = account;
}

final class MemoryAuthChallenges implements AuthChallenges {
  MemoryAuthChallenges({Clock clock = const SystemClock()}) : _clock = clock;

  final Clock _clock;
  final Map<String, Challenge> _byId = {};
  final Map<String, DateTime> _lastIssued = {};
  var _next = 0;

  @override
  Future<DateTime?> lastIssuedTo(String destination) async =>
      _lastIssued[destination];

  @override
  Future<Challenge> issue({
    required SignInChannel channel,
    required String destination,
    required String codeHash,
    required String language,
    required DateTime expiresAt,
    required int maxAttempts,
  }) async {
    final challenge = Challenge(
      id: 'ch-mem-${++_next}',
      channel: channel,
      destination: destination,
      codeHash: codeHash,
      language: language,
      attempts: 0,
      maxAttempts: maxAttempts,
      createdAt: _clock.now(),
      expiresAt: expiresAt,
    );
    _byId[challenge.id] = challenge;
    _lastIssued[destination] = challenge.createdAt;
    return challenge;
  }

  @override
  Future<Challenge?> byId(String id) async => _byId[id];

  @override
  Future<Challenge?> recordFailedAttempt(String id) async {
    final existing = _byId[id];
    if (existing == null) return null;
    final updated = _copy(existing, attempts: existing.attempts + 1);
    _byId[id] = updated;
    return updated;
  }

  @override
  Future<bool> consume({required String id, required String userId}) async {
    final existing = _byId[id];
    if (existing == null || existing.isConsumed) return false;
    _byId[id] = _copy(existing, consumedAt: _clock.now());
    return true;
  }

  static Challenge _copy(
    Challenge c, {
    int? attempts,
    DateTime? consumedAt,
  }) => Challenge(
    id: c.id,
    channel: c.channel,
    destination: c.destination,
    codeHash: c.codeHash,
    language: c.language,
    attempts: attempts ?? c.attempts,
    maxAttempts: c.maxAttempts,
    createdAt: c.createdAt,
    expiresAt: c.expiresAt,
    consumedAt: consumedAt ?? c.consumedAt,
  );
}
