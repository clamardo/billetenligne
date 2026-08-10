/// One person's second factor, as the sign-in path knows it.
final class SecondFactor {
  const SecondFactor({
    required this.userId,
    required this.secretBase32,
    this.confirmedAt,
    this.lastWindow,
    this.unusedRecoveryCodes = 0,
    this.failedAttempts = 0,
    this.lockedUntil,
  });

  final String userId;
  final String secretBase32;

  /// Null while somebody is mid-enrolment.
  ///
  /// An unconfirmed row is **not** a second factor and must never be treated
  /// as one: it would lock a person out of the console with a secret they
  /// mistyped into an app that never scanned the QR.
  final DateTime? confirmedAt;

  /// The last TOTP window spent. The replay control: a code is valid for
  /// thirty seconds, and without this the same thirty seconds can be used
  /// twice by somebody reading over a shoulder.
  final int? lastWindow;

  final int unusedRecoveryCodes;

  /// Consecutive wrong answers, and how long they cost.
  ///
  /// Six digits is a million guesses. The lock is on the factor rather than on
  /// the attempt token, because otherwise discarding a token and asking for
  /// another would reset the budget.
  final int failedAttempts;
  final DateTime? lockedUntil;

  bool get isConfirmed => confirmedAt != null;

  bool isLockedAt(DateTime now) =>
      lockedUntil != null && lockedUntil!.isAfter(now);
}

/// Where second factors live.
///
/// Every method runs on the identity surface (`DbScope.identity`), which is
/// the only role granted anything on `user_totp` (migration 0013). That is not
/// an implementation detail: the point of a second factor here is that
/// compromising the operator console does not get you the back office, and a
/// grant from `bel_app` would quietly undo it.
abstract interface class SecondFactors {
  Future<SecondFactor?> forUser(String userId);

  /// Begins enrolment, replacing any unconfirmed attempt.
  ///
  /// Replacing rather than refusing, because the common case is somebody who
  /// scanned a QR, lost the tab, and came back. Refusing them would need a
  /// "cancel my half-finished enrolment" button that nobody would find.
  ///
  /// A **confirmed** factor is not replaced — disabling one is its own act,
  /// and silently overwriting it here would turn a stray click into a lockout
  /// of the person whose phone still holds the old secret.
  Future<SecondFactor?> beginEnrolment({
    required String userId,
    required String secretBase32,
    required List<String> recoveryHashes,
  });

  /// Confirms enrolment and records the window that proved it.
  ///
  /// Returns false when there is nothing to confirm or it is already
  /// confirmed, so a replayed confirmation cannot reset anything.
  Future<bool> confirm({required String userId, required int window});

  /// Spends a window. False when the window is not ahead of the last one —
  /// which is a replay, and is refused as one.
  Future<bool> spendWindow({required String userId, required int window});

  /// Burns a recovery code. False when there is no unused code with that
  /// hash, which is both "wrong code" and "already used" — one answer for two
  /// causes, because telling them apart tells an attacker which of their
  /// guesses was once real.
  Future<bool> spendRecoveryCode({
    required String userId,
    required String codeHash,
  });

  /// Counts a wrong answer, and locks the factor once there have been
  /// [lockAfter] of them in a row. Returns the factor as it now stands, so the
  /// caller can tell somebody how long they are locked out for rather than
  /// leaving them to guess.
  Future<SecondFactor?> recordFailure({
    required String userId,
    required int lockAfter,
    required Duration lockFor,
  });

  /// Removes the factor entirely. Recovery codes are left behind: a burned
  /// one is evidence of the incident it was burned during.
  Future<void> disable(String userId);
}
