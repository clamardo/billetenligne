import 'dart:convert';

import 'package:bel_domain/bel_domain.dart';
import 'package:http/http.dart' as http;

import 'api_failure.dart';

/// Which Firebase, and how to reach it.
///
/// One field decides everything: [emulatorHost]. Set, and every request goes
/// to a `demo-` project on localhost that needs no credentials and cannot
/// reach Google (ADR-0020). Unset, and the real endpoints are used with a real
/// web API key.
///
/// The API key is not a secret — Firebase publishes it in every web app — and
/// it is not an authorisation of any kind. It identifies the project. Treating
/// it as a credential is the mistake that leads to it being kept out of the
/// repository and then hardcoded in a hurry.
final class FirebaseClientConfig {
  const FirebaseClientConfig({
    required this.apiKey,
    required this.projectId,
    this.emulatorHost,
  });

  final String apiKey;
  final String projectId;
  final String? emulatorHost;

  bool get usingEmulator => emulatorHost != null && emulatorHost!.isNotEmpty;

  /// The emulator serves the real Google paths under its own host, which is
  /// what lets one code path address both.
  Uri _endpoint(String host, String path) => usingEmulator
      ? Uri.parse('http://$emulatorHost/$host$path?key=$apiKey')
      : Uri.parse('https://$host$path?key=$apiKey');

  Uri get exchangeUrl => _endpoint(
    'identitytoolkit.googleapis.com',
    '/v1/accounts:signInWithCustomToken',
  );

  Uri get refreshUrl => _endpoint('securetoken.googleapis.com', '/v1/token');

  /// A local emulator loop. The key is ignored by the emulator, so a
  /// recognisable string beats an empty one in a log.
  factory FirebaseClientConfig.emulator({
    String projectId = 'demo-billetenligne',
    String host = 'localhost:9099',
  }) => FirebaseClientConfig(
    apiKey: 'emulator-key',
    projectId: projectId,
    emulatorHost: host,
  );
}

/// What Firebase hands back in exchange for a custom token.
final class FirebaseSession {
  const FirebaseSession({
    required this.idToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  /// The bearer every API request carries. Short-lived by design — an hour —
  /// which is why the refresh token exists and why nothing stores this one.
  final String idToken;

  /// **The only thing worth persisting**, and only in platform secure storage:
  /// Keychain or the Android Keystore (ADR-0013). It rotates on use and is
  /// revocable from the admin console.
  final String refreshToken;

  final DateTime expiresAt;

  /// A minute of headroom. A token that expires while the request carrying it
  /// is in flight fails the one call that mattered, and on a 2G handshake that
  /// flight is measured in seconds rather than milliseconds.
  bool isFreshAt(DateTime now) =>
      now.add(const Duration(minutes: 1)).isBefore(expiresAt);

  Map<String, Object?> toJson() => {
    'refreshToken': refreshToken,
    // The ID token is deliberately absent. It is worth an hour and it would
    // outlive its usefulness in storage while remaining a bearer for anyone
    // who read the file.
  };
}

/// Talks to Firebase Authentication over its REST API.
///
/// REST rather than the `firebase_auth` plugin, deliberately. Three reasons,
/// and the third is the one that decided it:
///
///   * it is **pure Dart**, so the operator console's web build and any future
///     worker use the same code as the app;
///   * it needs **no `google-services.json` and no native platform config**,
///     which is what makes the emulator loop work on a fresh clone;
///   * it is **testable without a device**, so the exchange below has unit
///     tests rather than a manual checklist.
///
/// The cost is that we do not get the plugin's automatic secure-storage or its
/// background refresh, so [FirebaseSession] is stored by the caller and
/// [refresh] is called by the token provider. Both are small and both are
/// visible, which is the trade.
final class FirebaseIdentityClient {
  FirebaseIdentityClient({
    required this.config,
    http.Client? httpClient,
    Clock clock = const SystemClock(),
  }) : _http = httpClient ?? http.Client(),
       _clock = clock;

  final FirebaseClientConfig config;
  final http.Client _http;

  /// Injected, because `expiresAt` is computed from it and a session that
  /// reads the wall clock cannot be tested at the only moment that matters —
  /// the instant the token goes stale. That is the same bug the hold countdown
  /// had, and it hid a real defect behind a green suite.
  final Clock _clock;

  /// Exchanges the custom token our API minted for a real session.
  ///
  /// This is the step that keeps Firebase as the identity provider even though
  /// we ran the challenge ourselves (ADR-0024): the credential the traveller
  /// ends up holding is Firebase's, with Firebase's expiry, rotation and
  /// revocation behind it.
  Future<FirebaseSession> exchangeCustomToken(String customToken) =>
      _session(config.exchangeUrl, {
        'token': customToken,
        'returnSecureToken': true,
      }, idTokenField: 'idToken', refreshField: 'refreshToken');

  /// Trades a refresh token for a new ID token. Firebase rotates the refresh
  /// token on use, so the answer replaces what the caller stored.
  Future<FirebaseSession> refresh(String refreshToken) =>
      _session(config.refreshUrl, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        // The refresh endpoint answers in snake_case while the exchange
        // endpoint answers in camelCase. Not a typo — two different Google
        // APIs, and reading the wrong field yields a null that surfaces three
        // screens later as an unexplained 401.
      }, idTokenField: 'id_token', refreshField: 'refresh_token');

  Future<FirebaseSession> _session(
    Uri url,
    Map<String, Object?> body, {
    required String idTokenField,
    required String refreshField,
  }) async {
    final http.Response response;
    try {
      response = await _http.post(
        url,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } on Object catch (e) {
      throw NetworkUnreachable(e.toString());
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw UnreadableResponse(e.message);
    }

    if (decoded is! Map<String, Object?>) {
      throw const UnreadableResponse('expected an object from Firebase');
    }

    if (response.statusCode >= 400) {
      // Firebase's own error strings — TOKEN_EXPIRED, USER_DISABLED — are
      // stable and worth keeping, but they are not prose and never reach a
      // screen: the surface renders the catalog key.
      final error = decoded['error'];
      throw FirebaseRefused(
        response.statusCode,
        error is Map ? '${error['message']}' : 'UNKNOWN',
      );
    }

    final idToken = decoded[idTokenField];
    final refreshToken = decoded[refreshField];
    if (idToken is! String || refreshToken is! String) {
      throw UnreadableResponse(
        'Firebase answered without $idTokenField or $refreshField',
      );
    }

    // `expiresIn` is seconds, as a string. Defaulting to an hour rather than
    // throwing: a session that works and refreshes a little early beats a
    // sign-in that fails on a field nobody reads.
    final seconds =
        int.tryParse('${decoded['expiresIn'] ?? decoded['expires_in']}') ??
        3600;

    return FirebaseSession(
      idToken: idToken,
      refreshToken: refreshToken,
      expiresAt: _clock.now().add(Duration(seconds: seconds)),
    );
  }

  void close() => _http.close();
}
