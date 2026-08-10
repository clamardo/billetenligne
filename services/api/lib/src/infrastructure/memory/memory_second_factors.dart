import '../../application/ports/second_factor.dart';

/// Second factors held in memory, for tests and for the demo server.
///
/// A fake is right here in a way it is not for the console: this is one row
/// with four columns, not a second definition of the world. What it must
/// reproduce faithfully is the *refusals* — an unconfirmed factor is not a
/// factor, a replayed window is refused, a burned recovery code stays burned —
/// because those are the properties the sign-in path is built on.
final class MemorySecondFactors implements SecondFactors {
  MemorySecondFactors({DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  final DateTime Function() _now;
  final _factors = <String, SecondFactor>{};
  final _recovery = <String, Map<String, bool>>{};

  SecondFactor _with(
    SecondFactor from, {
    DateTime? confirmedAt,
    int? lastWindow,
    int? unusedRecoveryCodes,
    int? failedAttempts,
    DateTime? lockedUntil,
    bool clearLock = false,
  }) => SecondFactor(
    userId: from.userId,
    secretBase32: from.secretBase32,
    confirmedAt: confirmedAt ?? from.confirmedAt,
    lastWindow: lastWindow ?? from.lastWindow,
    unusedRecoveryCodes: unusedRecoveryCodes ?? from.unusedRecoveryCodes,
    failedAttempts: failedAttempts ?? from.failedAttempts,
    lockedUntil: clearLock ? null : (lockedUntil ?? from.lockedUntil),
  );

  @override
  Future<SecondFactor?> forUser(String userId) async => _factors[userId];

  @override
  Future<SecondFactor?> beginEnrolment({
    required String userId,
    required String secretBase32,
    required List<String> recoveryHashes,
  }) async {
    if (_factors[userId]?.isConfirmed ?? false) return null;

    _recovery[userId] = {for (final hash in recoveryHashes) hash: false};
    return _factors[userId] = SecondFactor(
      userId: userId,
      secretBase32: secretBase32,
      unusedRecoveryCodes: recoveryHashes.length,
    );
  }

  @override
  Future<bool> confirm({required String userId, required int window}) async {
    final existing = _factors[userId];
    if (existing == null || existing.isConfirmed) return false;

    _factors[userId] = _with(existing, confirmedAt: _now(), lastWindow: window);
    return true;
  }

  @override
  Future<bool> spendWindow({
    required String userId,
    required int window,
  }) async {
    final existing = _factors[userId];
    if (existing == null || !existing.isConfirmed) return false;
    if (existing.lastWindow != null && existing.lastWindow! >= window) {
      return false;
    }

    _factors[userId] = _with(
      existing,
      lastWindow: window,
      failedAttempts: 0,
      clearLock: true,
    );
    return true;
  }

  @override
  Future<bool> spendRecoveryCode({
    required String userId,
    required String codeHash,
  }) async {
    final codes = _recovery[userId];
    if (codes == null || codes[codeHash] != false) return false;

    codes[codeHash] = true;
    _factors[userId] = _with(
      _factors[userId]!,
      unusedRecoveryCodes: codes.values.where((used) => !used).length,
      failedAttempts: 0,
      clearLock: true,
    );
    return true;
  }

  @override
  Future<SecondFactor?> recordFailure({
    required String userId,
    required int lockAfter,
    required Duration lockFor,
  }) async {
    final existing = _factors[userId];
    if (existing == null) return null;

    final failures = existing.failedAttempts + 1;
    return _factors[userId] = _with(
      existing,
      failedAttempts: failures,
      lockedUntil: failures >= lockAfter ? _now().add(lockFor) : null,
    );
  }

  @override
  Future<void> disable(String userId) async => _factors.remove(userId);
}
