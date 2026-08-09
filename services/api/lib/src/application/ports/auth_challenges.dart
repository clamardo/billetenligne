import 'package:bel_contracts/bel_contracts.dart';

/// A one-time code, in flight.
///
/// **Never carries the code.** [codeHash] is an HMAC of it under a server-side
/// key, which is what makes a leaked backup of this table worthless.
final class Challenge {
  const Challenge({
    required this.id,
    required this.channel,
    required this.destination,
    required this.codeHash,
    required this.language,
    required this.attempts,
    required this.maxAttempts,
    required this.createdAt,
    required this.expiresAt,
    this.consumedAt,
  });

  final String id;
  final SignInChannel channel;

  /// Normalised: an email lowercased and trimmed, a phone in E.164. The rate
  /// limit keys on this, and a limit keyed on what the user typed is a limit
  /// evaded with a capital letter.
  final String destination;

  final String codeHash;
  final String language;
  final int attempts;
  final int maxAttempts;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? consumedAt;

  bool get isConsumed => consumedAt != null;
  bool get isExhausted => attempts >= maxAttempts;
  bool hasExpiredBy(DateTime now) => !now.isBefore(expiresAt);

  int get attemptsRemaining {
    final left = maxAttempts - attempts;
    return left < 0 ? 0 : left;
  }
}

abstract interface class AuthChallenges {
  /// When we last sent a code to this address, live or not. Drives the resend
  /// cooldown — and it is a query on the *destination*, not on a challenge id,
  /// because otherwise "ask again" with a fresh id would sidestep the limit.
  Future<DateTime?> lastIssuedTo(String destination);

  Future<Challenge> issue({
    required SignInChannel channel,
    required String destination,
    required String codeHash,
    required String language,
    required DateTime expiresAt,
    required int maxAttempts,
  });

  Future<Challenge?> byId(String id);

  /// A wrong answer. Counted whether or not the code was close, and counted
  /// **before** the caller learns the verdict, so a client that disconnects
  /// mid-response has still spent its attempt.
  Future<Challenge?> recordFailedAttempt(String id);

  /// Burns the challenge and ties it to the account it resolved to.
  ///
  /// Returns false when it was already consumed — which is the replay case,
  /// and the reason this is a conditional write in the database rather than a
  /// read-then-write in Dart.
  Future<bool> consume({required String id, required String userId});
}
