import 'dart:async';
import 'dart:convert';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:http/http.dart' as http;

import 'api_failure.dart';
import 'idempotency_key.dart';
import 'retry_policy.dart';

/// Supplies the bearer token, or null when nobody is signed in.
///
/// A function rather than a stored string: tokens expire mid-session, and a
/// client holding a stale copy fails the one request that mattered.
typedef TokenProvider = FutureOr<String?> Function();

/// The BilletEnLigne API, typed.
///
/// Shared unchanged by the traveller app, the operator console and the admin
/// back office. One place knows about retries, idempotency keys, trace ids and
/// what "offline" means — which is what stops three surfaces from inventing
/// three different answers to the same bad connection.
///
/// Three rules run through it:
///
///   * **Reads retry; writes retry only with a key.** A GET is safe to repeat.
///     A POST is safe to repeat *only* because the same `Idempotency-Key`
///     goes with it, which is why the key is generated once per attempt and
///     reused across every retry of that attempt.
///   * **Every response carries a trace id, and failures keep it.** It is the
///     one string a support agent needs, and it is worthless if the client
///     throws it away on the path that matters.
///   * **The client never produces prose.** Failures carry catalog keys and
///     parameters; the surface renders them in the reader's language.
final class BelApiClient {
  BelApiClient({
    required Uri baseUrl,
    http.Client? httpClient,
    TokenProvider? token,
    this.language = 'fr',
    this.appVersion,
    this.deviceId,
    this.retry = RetryPolicy.standard,
    this.timeout = const Duration(seconds: 20),
  }) : _base = baseUrl,
       _http = httpClient ?? http.Client(),
       _token = token;

  final Uri _base;
  final http.Client _http;
  final TokenProvider? _token;

  final String language;
  final String? appVersion;
  final String? deviceId;
  final RetryPolicy retry;

  /// Generous on purpose. A 2G handshake in Pointe-Noire routinely takes eight
  /// seconds before a byte moves; a five-second timeout would fail requests
  /// that were about to succeed and teach travellers the app is broken.
  final Duration timeout;

  // ── Catalogue ─────────────────────────────────────────────────────────────

  /// Departures for a route on a local calendar day.
  Future<List<DepartureSummaryDto>> searchTrips(
    SearchDeparturesQuery query,
  ) async {
    final body = await _get('/public/v1/trips', query: query.toQuery());
    return Wire.readList(
      body['items'],
      DepartureSummaryDto.fromJson,
      field: 'items',
    );
  }

  /// The layout and the live availability, in one response.
  Future<SeatMapDto> seatMap(String departureId) async {
    final body = await _get('/public/v1/departures/$departureId/seatmap');
    return SeatMapDto.fromJson(body);
  }

  /// Where you can go.
  ///
  /// The first call the app makes — the search screen cannot render without
  /// it — and the one answer in the product safe to serve from cache.
  Future<List<CityDto>> cities() async {
    final body = await _get('/public/v1/cities');
    return Wire.readList(body['items'], CityDto.fromJson, field: 'items');
  }

  Future<MarketDto> market() async {
    final body = await _get('/public/v1/market');
    return MarketDto.fromJson(body);
  }

  // ── Identity ──────────────────────────────────────────────────────────────

  /// Ask for a one-time code. Open to anonymous callers, necessarily: this is
  /// how somebody stops being one.
  ///
  /// No idempotency key, and that is not an omission. A repeat is a *resend*,
  /// which is a different act with a different cost — the server's cooldown is
  /// what decides whether it happens, and a key would quietly turn the second
  /// tap into a replay of the first answer while the traveller waits for a
  /// message that was never sent again.
  Future<SignInChallengeDto> startSignIn(StartSignInRequest request) async {
    final body = await _send(
      'POST',
      '/public/v1/auth/challenges',
      body: request.toJson(),
    );
    return SignInChallengeDto.fromJson(body ?? const {});
  }

  /// Answer the code.
  ///
  /// **Not retried, ever.** Each attempt is counted by the server, so a silent
  /// retry of a request whose answer was lost would spend a traveller's five
  /// attempts on one typed code. `idempotent: false` here is load-bearing.
  Future<SessionDto> verifySignIn(VerifySignInRequest request) async {
    final body = await _send(
      'POST',
      '/public/v1/auth/sessions',
      body: request.toJson(),
    );
    return SessionDto.fromJson(body ?? const {});
  }

  /// The signed-in traveller's own profile.
  ///
  /// How the app learns that a token it still holds is no longer good: a
  /// refresh token survives a disabled account, so "I have a token" and "I am
  /// still a customer" are different claims and only this settles the second.
  Future<AccountDto> me() async =>
      AccountDto.fromJson(await _get('/public/v1/me'));

  // ── Inventory ─────────────────────────────────────────────────────────────

  /// Claim seats.
  ///
  /// [idempotencyKey] defaults to a fresh one per call, which is correct for a
  /// *new* attempt. Pass the previous key to resume an attempt whose answer
  /// was lost — that is what turns a dropped connection into a retry rather
  /// than a second hold.
  Future<HoldDto> createHold(
    CreateHoldRequest request, {
    String? idempotencyKey,
  }) async {
    final body = await _post(
      '/public/v1/holds',
      body: request.toJson(),
      idempotencyKey: idempotencyKey ?? IdempotencyKey.generate(),
    );
    return HoldDto.fromJson(body);
  }

  /// Reserve now, pay at the agency.
  ///
  /// Takes the same [idempotencyKey] discipline as [createHold], and for a
  /// sharper reason: a duplicate tap that produced a second reservation would
  /// fail on the already-consumed hold, leaving the traveller believing
  /// nothing worked when in fact everything did.
  Future<BookingDto> createBooking(
    CreateBookingRequest request, {
    String? idempotencyKey,
  }) async {
    final body = await _post(
      '/public/v1/bookings',
      body: request.toJson(),
      idempotencyKey: idempotencyKey ?? IdempotencyKey.generate(),
    );
    return BookingDto.fromJson(body);
  }

  /// The traveller's own bookings, newest first.
  Future<List<BookingDto>> bookings() async {
    final body = await _get('/public/v1/bookings');
    return Wire.readList(body['items'], BookingDto.fromJson, field: 'items');
  }

  /// Give the seats back. Idempotent, so no key is required — demanding one
  /// for an operation that is already idempotent is ceremony clients get
  /// wrong.
  Future<void> releaseHold(String holdId) =>
      _send('DELETE', '/public/v1/holds/$holdId', idempotent: true);

  // ── Plumbing ──────────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final body = await _send('GET', path, query: query, idempotent: true);
    return body ?? const {};
  }

  Future<Map<String, Object?>> _post(
    String path, {
    required Map<String, Object?> body,
    required String idempotencyKey,
  }) async {
    final result = await _send(
      'POST',
      path,
      body: body,
      idempotencyKey: idempotencyKey,
      // Safe to repeat *because* of the key, and for no other reason.
      idempotent: true,
    );
    return result ?? const {};
  }

  Future<Map<String, Object?>?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    String? idempotencyKey,
    bool idempotent = false,
  }) async {
    final uri = _base.replace(
      path: '${_base.path}$path',
      queryParameters: query?.isEmpty ?? true ? null : query,
    );

    final headers = <String, String>{
      'Accept': 'application/json',
      BelHeaders.language: language,
      if (body != null) 'Content-Type': 'application/json',
      if (idempotencyKey != null) BelHeaders.idempotencyKey: idempotencyKey,
      if (appVersion != null) BelHeaders.appVersion: appVersion!,
      if (deviceId != null) BelHeaders.deviceId: deviceId!,
    };

    final bearer = await _token?.call();
    if (bearer != null && bearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearer';
    }

    final payload = body == null ? null : jsonEncode(body);

    ApiFailure? lastFailure;

    for (var attempt = 0; attempt <= retry.maxAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retry.delayFor(attempt));

      try {
        final response = await _http
            .send(_request(method, uri, headers, payload))
            .then(http.Response.fromStream)
            .timeout(timeout);

        if (response.statusCode == 204 || response.body.isEmpty) {
          if (response.statusCode >= 400) {
            throw ServerRefused(
              response.statusCode,
              ApiError(code: _codeForStatus(response.statusCode)),
            );
          }
          return null;
        }

        final decoded = _decode(response.body);

        if (response.statusCode >= 400) {
          throw ServerRefused(response.statusCode, ApiError.fromJson(decoded));
        }
        return decoded;
      } on ServerRefused catch (failure) {
        // A refusal is an answer. Retrying a 409 "seat taken" cannot help and
        // burns the traveller's data allowance saying so — except for the
        // handful of codes the server itself marks retryable.
        if (!failure.retryable || !idempotent) rethrow;
        lastFailure = failure;
      } on TimeoutException {
        lastFailure = RequestTimedOut(timeout);
        if (!idempotent) throw lastFailure;
      } on UnreadableResponse {
        rethrow;
      } on Object catch (e) {
        lastFailure = NetworkUnreachable(e.toString());
        if (!idempotent) throw lastFailure;
      }
    }

    throw lastFailure ?? const NetworkUnreachable();
  }

  http.Request _request(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? payload,
  ) {
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (payload != null) request.body = payload;
    return request;
  }

  Map<String, Object?> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        throw UnreadableResponse(
          'expected an object, got ${decoded.runtimeType}',
        );
      }
      return decoded;
    } on FormatException catch (e) {
      throw UnreadableResponse(e.message);
    }
  }

  /// A body-less error still needs a code. Guessing from the status is worse
  /// than a typed code and far better than an empty screen.
  static String _codeForStatus(int status) => switch (status) {
    401 => ErrorCode.unauthorized,
    403 => ErrorCode.forbidden,
    404 => ErrorCode.notFound,
    409 => ErrorCode.conflict,
    429 => ErrorCode.rateLimited,
    503 => ErrorCode.unavailable,
    _ => ErrorCode.internal,
  };

  void close() => _http.close();
}
