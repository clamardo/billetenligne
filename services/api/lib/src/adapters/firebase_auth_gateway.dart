import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/user_directory.dart';
import '../ports/auth_gateway.dart';

/// How to talk to Firebase, and which Firebase.
///
/// One field decides everything else: [emulatorHost]. Set, and this is a
/// `demo-` project with no credentials that cannot reach a real Google project
/// (ADR-0020). Unset, and every token must carry a real RS256 signature from
/// Google's published keys.
///
/// The two modes are mutually exclusive by construction rather than by
/// discipline, because the failure they prevent is the one that matters:
/// accepting an unsigned token in production is a complete authentication
/// bypass, and it looks exactly like local development working.
final class FirebaseConfig {
  const FirebaseConfig({
    required this.projectId,
    this.emulatorHost,
    this.serviceAccountEmail,
    this.privateKeyPem,
  });

  final String projectId;

  /// `localhost:9099` locally; null everywhere real.
  final String? emulatorHost;

  /// From the service-account JSON. Both null against the emulator, which
  /// accepts an unsigned custom token — that is the whole point of it.
  final String? serviceAccountEmail;
  final String? privateKeyPem;

  bool get usingEmulator => emulatorHost != null && emulatorHost!.isNotEmpty;

  /// The `iss` every genuine ID token for this project carries.
  String get issuer => 'https://securetoken.google.com/$projectId';

  static FirebaseConfig fromEnvironment(Map<String, String> env) =>
      FirebaseConfig(
        projectId: env['FIREBASE_PROJECT_ID'] ?? 'demo-billetenligne',
        emulatorHost: env['FIREBASE_AUTH_EMULATOR_HOST'],
        serviceAccountEmail: env['FIREBASE_CLIENT_EMAIL'],
        // Service-account JSON escapes the newlines. A PEM whose line breaks
        // are the two characters `\` and `n` parses as garbage, and the error
        // it produces names ASN.1 rather than the environment variable.
        privateKeyPem: env['FIREBASE_PRIVATE_KEY']?.replaceAll(r'\n', '\n'),
      );
}

/// Fetches and caches Google's token-signing keys.
///
/// Separate from the gateway because it is the only part that touches the
/// network, and a test that wants to prove signature verification should not
/// have to reach Google to do it.
abstract interface class FirebasePublicKeys {
  Future<RsaPublicKey?> forKeyId(String keyId);
}

/// The real thing: Google's JWK endpoint, cached until it says otherwise.
///
/// The JWK form rather than the X.509 one — the same keys are published both
/// ways, and `n` and `e` are one parse where a certificate is a walk through
/// ASN.1 to reach the same two integers.
final class GoogleSecureTokenKeys implements FirebasePublicKeys {
  GoogleSecureTokenKeys({Clock clock = const SystemClock(), HttpClient? httpClient})
    : _clock = clock,
      _http = httpClient ?? HttpClient();

  static final _jwkUrl = Uri.parse(
    'https://www.googleapis.com/service_accounts/v1/jwk/'
    'securetoken@system.gserviceaccount.com',
  );

  final Clock _clock;
  final HttpClient _http;

  Map<String, RsaPublicKey> _keys = const {};
  DateTime? _freshUntil;

  @override
  Future<RsaPublicKey?> forKeyId(String keyId) async {
    final cached = _keys[keyId];
    final until = _freshUntil;
    if (cached != null && until != null && _clock.now().isBefore(until)) {
      return cached;
    }

    // A `kid` we have not seen is the normal shape of a key rotation, so a
    // miss refetches rather than refusing. Refusing would mean every token
    // failing for the hour it takes a cache to expire, which is an outage.
    await _refresh();
    return _keys[keyId];
  }

  Future<void> _refresh() async {
    try {
      final request = await _http.getUrl(_jwkUrl);
      final response = await request.close();
      if (response.statusCode != 200) return;

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return;

      final keys = <String, RsaPublicKey>{};
      for (final entry in (decoded['keys'] as List? ?? const [])) {
        if (entry is! Map) continue;
        final jwk = entry.cast<String, Object?>();
        final kid = jwk['kid'];
        if (kid is! String) continue;
        try {
          keys[kid] = RsaPublicKey.fromJwk(jwk);
        } on FormatException {
          // One malformed key must not discard the others.
          continue;
        }
      }

      if (keys.isEmpty) return;
      _keys = keys;
      _freshUntil = _clock.now().add(_maxAge(response.headers.value('cache-control')));
    } on SocketException {
      // Keep serving the cached keys. They are valid for hours after the
      // header says to refresh, and an unreachable Google must not become an
      // outage of our own.
      return;
    } on HttpException {
      return;
    }
  }

  /// Google's `max-age` is measured in hours. The floor exists so a
  /// misconfigured or absent header cannot turn every verification into a
  /// network round trip.
  static Duration _maxAge(String? cacheControl) {
    final match = RegExp(r'max-age=(\d+)').firstMatch(cacheControl ?? '');
    final seconds = int.tryParse(match?.group(1) ?? '') ?? 0;
    return seconds < 300 ? const Duration(minutes: 5) : Duration(seconds: seconds);
  }

  void close() => _http.close(force: true);
}

/// Verifies Firebase ID tokens and mints Firebase custom tokens.
///
/// Firebase answers *who you are*; it does not decide *what you may do*
/// (ADR-0018). So the last thing this does with a valid token is look the
/// subject up in our own `user_accounts` — the token is the claim, the
/// database is the authority, and a stale claim can never authorise anything.
final class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuthGateway({
    required this.config,
    required UserDirectory directory,
    FirebasePublicKeys? publicKeys,
    Clock clock = const SystemClock(),
    this.leeway = const Duration(seconds: 30),
  }) : _directory = directory,
       _publicKeys = publicKeys ?? GoogleSecureTokenKeys(clock: clock),
       _clock = clock;

  final FirebaseConfig config;
  final UserDirectory _directory;
  final FirebasePublicKeys _publicKeys;
  final Clock _clock;

  /// Clock skew tolerance. Small: a token is valid for an hour, so thirty
  /// seconds of slack costs nothing and closes the window in which a handset
  /// with a fast clock cannot sign in.
  final Duration leeway;

  final _rsa = const RsaSha256();

  @override
  Future<Principal?> verify(String bearerToken) async {
    final Jwt token;
    try {
      token = Jwt.decode(bearerToken);
    } on JwtMalformed {
      return null;
    }

    if (!await _signatureIsGood(token)) return null;
    if (!_claimsAreGood(token)) return null;

    final uid = token.subject;
    if (uid == null || uid.isEmpty) return null;

    final account = await _directory.byAuthUid(uid);
    // A token Google will happily vouch for, for a user we have never seen or
    // have since disabled. Both are anonymous here: authentication succeeded
    // and authorisation did not.
    if (account == null || account.isDisabled) return null;

    return Principal(
      userId: account.id,
      authUid: uid,
      language: account.language,
    );
  }

  Future<bool> _signatureIsGood(Jwt token) async {
    if (config.usingEmulator) {
      // The emulator issues unsigned tokens, so there is nothing to check.
      // This branch is reachable only when FIREBASE_AUTH_EMULATOR_HOST is set,
      // which is also the condition under which the project id is a `demo-`
      // one that cannot exist in Google's directory.
      return true;
    }

    // Outside the emulator the algorithm is decided here, never by the token.
    // `alg: none` is the classic bypass and it dies on this line.
    if (token.algorithm != 'RS256') return false;

    final kid = token.keyId;
    if (kid == null || kid.isEmpty) return false;

    final key = await _publicKeys.forKeyId(kid);
    if (key == null) return false;

    return _rsa.verify(token.signingInput, token.signature, key);
  }

  bool _claimsAreGood(Jwt token) {
    final now = _clock.now();

    if (token.issuer != config.issuer) return false;
    if (!token.audience.contains(config.projectId)) return false;

    final expiresAt = token.expiresAt;
    if (expiresAt == null || !now.isBefore(expiresAt.add(leeway))) return false;

    final issuedAt = token.issuedAt;
    // A token issued in the future is either a badly set clock or a forgery,
    // and we cannot tell which — so it waits.
    if (issuedAt != null && now.add(leeway).isBefore(issuedAt)) return false;

    // Firebase sets auth_time on every ID token. Its absence means this is not
    // one — most likely a custom token, which is a credential to be exchanged
    // and never a credential to be presented.
    return token.authenticatedAt != null;
  }

  /// A Firebase custom token for a traveller who has just answered a correct
  /// code (ADR-0018's documented fallback).
  ///
  /// The app exchanges this with Firebase for an ID token and a refresh token,
  /// which is the point: we own the challenge, so the code can travel over a
  /// channel we can measure and price, and Firebase still owns the session,
  /// the refresh rotation and the revocation.
  Future<String> mintCustomToken({
    required String uid,
    Map<String, Object?> claims = const {},
    Duration ttl = const Duration(hours: 1),
  }) async {
    final now = _clock.now();
    final issuer = config.serviceAccountEmail ?? 'firebase-adminsdk@${config.projectId}';

    final payload = <String, Object?>{
      'iss': issuer,
      'sub': issuer,
      'aud':
          'https://identitytoolkit.googleapis.com/'
          'google.identity.identitytoolkit.v1.IdentityToolkit',
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(ttl).millisecondsSinceEpoch ~/ 1000,
      'uid': uid,
      if (claims.isNotEmpty) 'claims': claims,
    };

    final pem = config.privateKeyPem;

    if (config.usingEmulator || pem == null || pem.isEmpty) {
      // The emulator does not check the signature on a custom token, which is
      // what makes a credential-free local loop possible at all. Guarded the
      // same way verification is: reachable only when the emulator host is
      // set, or when there is genuinely no key to sign with — and in the
      // latter case the emulator would refuse it too, so this fails loudly at
      // exchange rather than silently granting anything.
      return '${_segment({'alg': 'none', 'typ': 'JWT'})}'
          '.${_segment(payload)}.';
    }

    final header = _segment({'alg': 'RS256', 'typ': 'JWT'});
    final body = _segment(payload);
    final signature = _rsa.sign(
      Uint8List.fromList(ascii.encode('$header.$body')),
      RsaPrivateKey.fromPkcs8Pem(pem),
    );

    return '$header.$body.${Jwt.base64UrlEncode(signature)}';
  }

  @override
  Future<String> mintConductorToken({
    required String staffUserId,
    required String operatorId,
    required List<String> departureIds,
    required Duration ttl,
  }) => mintCustomToken(
    uid: staffUserId,
    // Coarse routing facts only. They ride in every token and the JWT has a
    // size limit, so the departure list is a *hint* for the scanner's UI —
    // whether a ticket may actually be redeemed is re-read from Postgres.
    claims: {
      'tenantId': operatorId,
      'roles': const ['conductor'],
      'departures': departureIds,
    },
    ttl: ttl,
  );

  static String _segment(Map<String, Object?> value) =>
      Jwt.base64UrlEncode(utf8.encode(jsonEncode(value)));
}
