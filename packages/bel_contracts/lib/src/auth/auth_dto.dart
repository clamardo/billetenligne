import '../json/json_codec.dart';

/// How the one-time code reaches the traveller.
///
/// Email leads because it is the channel we can actually send on today
/// (ADR-0019: ACS email is configured, SMS is not), and because an emailed
/// code costs nothing per attempt while an SMS is a real line item. Phone is
/// the channel this market actually prefers and it is second, not absent —
/// the flow, the storage and the rate limits below are written once and are
/// channel-agnostic, so adding it is an adapter and a template.
enum SignInChannel { email, phone }

/// "Send me a code."
///
/// Exactly one of [email] / [phone] is set; which one chooses the channel.
/// Deliberately not a `channel` field plus a free-text `address`, because
/// that shape lets a client claim `channel: email` with a phone number in the
/// address and pushes the validation somewhere less obvious.
final class StartSignInRequest {
  const StartSignInRequest.email(String this.email)
    : phone = null;
  const StartSignInRequest.phone(String this.phone)
    : email = null;

  const StartSignInRequest._({this.email, this.phone});

  final String? email;
  final String? phone;

  SignInChannel get channel =>
      email != null ? SignInChannel.email : SignInChannel.phone;

  Map<String, Object?> toJson() => Wire.compact({
    'email': email,
    'phone': phone,
  });

  factory StartSignInRequest.fromJson(Map<String, Object?> json) {
    final email = json['email'] as String?;
    final phone = json['phone'] as String?;
    if ((email == null) == (phone == null)) {
      throw const WireFormatException(
        'email',
        'supply exactly one of email or phone',
      );
    }
    return StartSignInRequest._(email: email, phone: phone);
  }
}

/// A code is on its way.
///
/// **Never carries the code**, and never confirms whether the address was
/// already known: this response is identical for a returning traveller and a
/// stranger probing for registered addresses. Sign-up and sign-in are one
/// flow here, which is what makes that possible.
final class SignInChallengeDto {
  const SignInChallengeDto({
    required this.challengeId,
    required this.channel,
    required this.sentTo,
    required this.expiresAt,
    required this.resendAfter,
    required this.attemptsRemaining,
  });

  final String challengeId;
  final SignInChannel channel;

  /// Masked — `c***t@gmail.com`. Enough for the traveller to recognise which
  /// address they typed, not enough for a stranger holding a stolen device to
  /// read one off the screen.
  final String sentTo;

  final DateTime expiresAt;

  /// How long before "send it again" does anything. The client renders a
  /// countdown from this rather than inventing its own cooldown, so the
  /// button and the server agree (ADR-0013).
  final Duration resendAfter;

  final int attemptsRemaining;

  Map<String, Object?> toJson() => {
    'challengeId': challengeId,
    'channel': channel.name,
    'sentTo': sentTo,
    'expiresAt': Wire.instant(expiresAt),
    'resendAfter': Wire.seconds(resendAfter),
    'attemptsRemaining': attemptsRemaining,
  };

  factory SignInChallengeDto.fromJson(Map<String, Object?> json) =>
      SignInChallengeDto(
        challengeId: Wire.requireString(json['challengeId'], 'challengeId'),
        channel: Wire.readEnum(
          json['channel'],
          SignInChannel.values,
          field: 'channel',
        ),
        sentTo: Wire.requireString(json['sentTo'], 'sentTo'),
        expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
        resendAfter: Wire.readSeconds(
          json['resendAfter'],
          field: 'resendAfter',
        ),
        attemptsRemaining: Wire.requireInt(
          json['attemptsRemaining'],
          'attemptsRemaining',
        ),
      );
}

final class VerifySignInRequest {
  const VerifySignInRequest({required this.challengeId, required this.code});

  final String challengeId;
  final String code;

  Map<String, Object?> toJson() => {
    'challengeId': challengeId,
    'code': code,
  };

  factory VerifySignInRequest.fromJson(Map<String, Object?> json) =>
      VerifySignInRequest(
        challengeId: Wire.requireString(json['challengeId'], 'challengeId'),
        code: Wire.requireString(json['code'], 'code'),
      );
}

/// The traveller, as the app knows them.
///
/// No roles and no capabilities: this is a traveller's own profile, and what
/// they may do is decided server-side against Postgres on every request
/// (ADR-0018). A field here that the UI treated as authority would be a claim
/// the client could edit.
final class AccountDto {
  const AccountDto({
    required this.id,
    required this.language,
    this.email,
    this.phone,
    this.fullName,
  });

  final String id;
  final String language;
  final String? email;
  final String? phone;
  final String? fullName;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'language': language,
    'email': email,
    'phone': phone,
    'fullName': fullName,
  });

  factory AccountDto.fromJson(Map<String, Object?> json) => AccountDto(
    id: Wire.requireString(json['id'], 'id'),
    language: Wire.requireString(json['language'], 'language'),
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    fullName: json['fullName'] as String?,
  );
}

/// The answer to a correct code.
///
/// [customToken] is a **Firebase custom token**, not a session of ours: the
/// app exchanges it with Firebase for an ID token and a refresh token, and
/// every subsequent request carries the ID token. We own the challenge —
/// which is what lets us send it over a channel we can measure — and Firebase
/// owns the session, refresh rotation and revocation (ADR-0018).
final class SessionDto {
  const SessionDto({
    required this.customToken,
    required this.account,
    required this.isNewAccount,
  });

  final String customToken;
  final AccountDto account;

  /// True on the request that created the account. The app uses it to decide
  /// whether to ask for a name, and nothing security-relevant hangs on it.
  final bool isNewAccount;

  Map<String, Object?> toJson() => {
    'customToken': customToken,
    'account': account.toJson(),
    'isNewAccount': isNewAccount,
  };

  factory SessionDto.fromJson(Map<String, Object?> json) => SessionDto(
    customToken: Wire.requireString(json['customToken'], 'customToken'),
    account: AccountDto.fromJson(Wire.requireMap(json['account'], 'account')),
    isNewAccount: json['isNewAccount'] == true,
  );
}
