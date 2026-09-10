import 'dart:convert';
import 'dart:io';

import '../application/ports/token_exchange.dart';
import 'firebase_auth_gateway.dart';

/// The two Google endpoints that turn a custom token into a session, and keep
/// it alive (J11).
///
/// The handset never comes here: it exchanges for itself, because its storage
/// is the Keychain and the Android Keystore and a refresh token there is as
/// safe as anything on the device. This exists for the browser, which has no
/// such place — so the exchange happens on the server and the refresh token
/// never crosses the network to the page.
///
/// Both calls take an API key, which is not a secret: it identifies the
/// project and is compiled into every client Firebase ships. Against the
/// emulator it is ignored entirely, which is what lets a fresh clone sign in
/// with nothing configured (ADR-0020).
final class FirebaseTokenExchange implements TokenExchange {
  FirebaseTokenExchange({
    required this.config,
    required this.apiKey,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final FirebaseConfig config;
  final String apiKey;
  final HttpClient _http;

  /// `FIREBASE_API_KEY`, or the emulator's own placeholder.
  static FirebaseTokenExchange? fromEnvironment(
    Map<String, String> env,
    FirebaseConfig config,
  ) {
    final key = env['FIREBASE_API_KEY'] ?? '';
    if (key.isEmpty && !config.usingEmulator) return null;
    return FirebaseTokenExchange(
      config: config,
      apiKey: key.isEmpty ? 'emulator' : key,
    );
  }

  Uri get _signIn => config.usingEmulator
      ? Uri.parse(
          'http://${config.emulatorHost}/identitytoolkit.googleapis.com/v1/'
          'accounts:signInWithCustomToken?key=$apiKey',
        )
      : Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/'
          'accounts:signInWithCustomToken?key=$apiKey',
        );

  Uri get _token => config.usingEmulator
      ? Uri.parse(
          'http://${config.emulatorHost}/securetoken.googleapis.com/v1/'
          'token?key=$apiKey',
        )
      : Uri.parse('https://securetoken.googleapis.com/v1/token?key=$apiKey');

  @override
  Future<ExchangedSession> exchangeCustomToken(String customToken) async {
    final body = await _post(_signIn, {
      'token': customToken,
      'returnSecureToken': true,
    });
    return ExchangedSession(
      idToken: body['idToken']! as String,
      refreshToken: body['refreshToken']! as String,
      expiresIn: _seconds(body['expiresIn']),
    );
  }

  @override
  Future<ExchangedSession> refresh(String refreshToken) async {
    // `x-www-form-urlencoded` here and JSON above, because that is what the
    // two endpoints take. They are different services that happen to sit
    // behind the same product.
    final body = await _post(_token, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    }, form: true);
    return ExchangedSession(
      // The token endpoint answers in snake_case. The two shapes are Google's,
      // not ours, and normalising them is this adapter's job.
      idToken: body['id_token']! as String,
      refreshToken: body['refresh_token']! as String,
      expiresIn: _seconds(body['expires_in']),
    );
  }

  Future<Map<String, Object?>> _post(
    Uri url,
    Map<String, Object?> payload, {
    bool form = false,
  }) async {
    final request = await _http.postUrl(url);
    request.headers.contentType = form
        ? ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8')
        : ContentType.json;
    request.write(
      form
          ? payload.entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent(e.key)}='
                      '${Uri.encodeQueryComponent('${e.value}')}',
                )
                .join('&')
          : jsonEncode(payload),
    );

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      // A refusal is the end of a session, not a reason to retry: the account
      // was disabled, or the token was revoked from another device. The
      // message is Google's own and goes no further than a log.
      throw TokenExchangeRefused(_reason(text, response.statusCode));
    }

    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const TokenExchangeRefused('unreadable');
    }
    return decoded;
  }

  static String _reason(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      final message = error is Map ? error['message'] : null;
      if (message is String && message.isNotEmpty) return message;
    } on FormatException {
      // Not JSON. The status is what there is to say.
    }
    return 'http $status';
  }

  /// Both endpoints send this as a string of seconds.
  static Duration _seconds(Object? raw) =>
      Duration(seconds: int.tryParse('${raw ?? ''}') ?? 3600);

  void close() => _http.close(force: true);
}
