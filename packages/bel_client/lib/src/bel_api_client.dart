import 'dart:async';
import 'dart:convert';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
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

  /// Prove the second factor, and get the session the first half withheld.
  ///
  /// Not retried either, and for the same reason: every attempt is counted
  /// against a factor that locks after five, so a silent retry would spend
  /// somebody's budget on one typed code.
  Future<SessionDto> verifySecondFactor(
    VerifySecondFactorRequest request,
  ) async {
    final body = await _send(
      'POST',
      '/public/v1/auth/sessions/mfa',
      body: request.toJson(),
    );
    return SessionDto.fromJson(body ?? const {});
  }

  /// Whether this account has an authenticator, and whether it owes one.
  Future<SecondFactorStatusDto> secondFactor() async =>
      SecondFactorStatusDto.fromJson(
        await _get('/public/v1/auth/second-factor'),
      );

  /// Begin enrolment.
  ///
  /// The recovery codes in the answer exist in readable form **here and
  /// nowhere else** — the server stores only their HMACs. A caller that
  /// discards this response has discarded them.
  Future<SecondFactorEnrolmentDto> beginSecondFactor() async {
    final body = await _send('POST', '/public/v1/auth/second-factor');
    return SecondFactorEnrolmentDto.fromJson(body ?? const {});
  }

  /// Finish enrolment by proving the app can compute a code. Until this
  /// succeeds the stored secret is inert.
  Future<void> confirmSecondFactor(String code) => _send(
    'POST',
    '/public/v1/auth/second-factor/confirm',
    body: {'code': code},
  );

  Future<void> disableSecondFactor() =>
      _send('DELETE', '/public/v1/auth/second-factor');

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

  /// How this booking can be paid, and where the money goes.
  ///
  /// Server-driven: a rail appears only if this deployment can reach it AND
  /// the operator has a verified account on it. Enabling one is a config push
  /// rather than an app release (ADR-0006).
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId) async {
    final body = await _get('/public/v1/bookings/$bookingId/payment-options');
    return (
      options: Wire.readList(
        body['items'],
        PaymentOptionDto.fromJson,
        field: 'items',
      ),
      accountMsisdn: body['accountMsisdn'] as String?,
      amount: Wire.readMoney(body['amount'], field: 'amount'),
    );
  }

  /// Pushes a PIN prompt to a handset.
  ///
  /// Answers `pending`, not `paid` — the traveller has not typed anything
  /// yet. Takes an idempotency key for a sharper reason than the hold does: a
  /// duplicate tap would put two PIN prompts on one handset.
  Future<PaymentIntentDto> startPayment(
    StartPaymentRequest request, {
    String? idempotencyKey,
  }) async {
    final body = await _post(
      '/public/v1/payments',
      body: request.toJson(),
      idempotencyKey: idempotencyKey ?? IdempotencyKey.generate(),
    );
    return PaymentIntentDto.fromJson(body);
  }

  /// Has it settled?
  ///
  /// Re-queries the rail server-side on every call, because a callback can be
  /// lost and a traveller staring at a spinner while the money has left their
  /// wallet is the worst state this product has.
  Future<PaymentIntentDto> paymentStatus(String intentId) async =>
      PaymentIntentDto.fromJson(await _get('/public/v1/payments/$intentId'));

  /// Give the seats back. Idempotent, so no key is required — demanding one
  /// for an operation that is already idempotent is ceremony clients get
  /// wrong.
  Future<void> releaseHold(String holdId) =>
      _send('DELETE', '/public/v1/holds/$holdId', idempotent: true);

  // ── Console ───────────────────────────────────────────────────────────────
  //
  // The operator surface. Every call below is refused with a 403 unless the
  // caller holds the capability the route checks, and this client does not
  // pre-check: a client that decides what it may do is a client an attacker
  // can edit. [consoleIdentity] exists to render navigation, not to authorise.

  Future<ConsoleIdentityDto> consoleIdentity() async =>
      ConsoleIdentityDto.fromJson(await _get('/console/v1/me'));

  Future<List<LayoutDto>> layouts() async => Wire.readList(
    (await _get('/console/v1/fleet/layouts'))['items'],
    LayoutDto.fromJson,
    field: 'items',
  );

  /// Creates a layout, or a **new version** of one with this name.
  ///
  /// [preset] is the fast path — most operators never open the editor, and
  /// picking one of the four that actually run in Congo takes ninety seconds
  /// against the twenty minutes the section builder takes.
  Future<LayoutDto> saveLayout({
    required String name,
    required String preset,
    int? rows,
  }) async => LayoutDto.fromJson(
    await _postJson('/console/v1/fleet/layouts', {
      'name': name,
      'preset': preset,
      if (rows != null) 'rows': rows,
    }),
  );

  /// Creates a layout drawn section by section, for the coach no preset fits.
  ///
  /// Separate from [saveLayout] rather than an optional argument on it,
  /// because the two are different requests with different failure modes: a
  /// preset can only be misspelled, and a draft can be wrong in eleven places.
  /// [LayoutDraft.isValid] answers the same question the server will, so the
  /// screen refuses before the socket does.
  Future<LayoutDto> drawLayout(LayoutDraft draft) async => LayoutDto.fromJson(
    await _postJson('/console/v1/fleet/layouts', draft.toJson()),
  );

  /// Every version of every refund policy this operator has written.
  Future<({List<RefundPolicyDto> items, bool hasDefault})>
  refundPolicies() async {
    final json = await _get('/console/v1/policies');
    return (
      items: Wire.readList(
        json['items'],
        RefundPolicyDto.fromJson,
        field: 'items',
      ),
      hasDefault: json['hasDefault'] as bool? ?? false,
    );
  }

  /// Writes a policy, or the next version of one with this name.
  ///
  /// Never an edit — ADR-0015 rule 1. Saving under a name that already exists
  /// creates version n+1, and the bookings sold under version n keep it.
  Future<RefundPolicyDto> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
  }) async => RefundPolicyDto.fromJson(
    await _postJson('/console/v1/policies', {
      'name': name,
      'tiers': [
        for (final t in policy.tiers) RefundTierDto.fromDomain(t).toJson(),
      ],
      'destination': policy.destination.name,
      'processingHours': policy.processingWindow.inHours,
      'refundServiceFee': policy.refundServiceFee,
      'nonRefundableFares': policy.nonRefundableFareCodes.toList()..sort(),
    }),
  );

  /// Points future sales at one version, or at nothing.
  ///
  /// Returns null when the default was cleared, which is a legitimate state:
  /// no policy means no self-service refund rather than a hidden one.
  Future<RefundPolicyDto?> setDefaultRefundPolicy({
    String? policyId,
    int? version,
  }) async {
    final json = await _putJson('/console/v1/policies/default', {
      'policyId': policyId,
      'version': version,
    });
    return json == null ? null : RefundPolicyDto.fromJson(json);
  }

  Future<List<VehicleDto>> vehicles() async => Wire.readList(
    (await _get('/console/v1/fleet/vehicles'))['items'],
    VehicleDto.fromJson,
    field: 'items',
  );

  Future<VehicleDto> saveVehicle({
    required String registration,
    required String layoutId,
    String? id,
    String? nickname,
    String? model,
    List<String> amenities = const [],
  }) async => VehicleDto.fromJson(
    await _postJson('/console/v1/fleet/vehicles', {
      'registration': registration,
      'layoutId': layoutId,
      if (id != null) 'id': id,
      if (nickname != null) 'nickname': nickname,
      if (model != null) 'model': model,
      'amenities': amenities,
    }),
  );

  /// Returns the **future departures this coach was carrying**. Taking a
  /// vehicle off the road without saying which departures it was running is
  /// how bookings get dropped without anybody noticing until the passengers
  /// are at the station.
  Future<List<String>> setVehicleStatus({
    required String vehicleId,
    required String status,
  }) async {
    final body = await _postJson('/console/v1/fleet/vehicles', {
      'id': vehicleId,
      'status': status,
    });
    return (body['affectedDepartureIds'] as List?)?.cast<String>() ?? const [];
  }

  Future<List<RouteDto>> operatorRoutes() async => Wire.readList(
    (await _get('/console/v1/routes'))['items'],
    RouteDto.fromJson,
    field: 'items',
  );

  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    int? distanceKm,
  }) async => RouteDto.fromJson(
    await _postJson('/console/v1/routes', {
      'code': code,
      'originCity': originCity,
      'destinationCity': destinationCity,
      'durationMinutes': durationMinutes,
      if (id != null) 'id': id,
      if (distanceKm != null) 'distanceKm': distanceKm,
    }),
  );

  Future<List<ScheduleDto>> schedules() async => Wire.readList(
    (await _get('/console/v1/schedules'))['items'],
    ScheduleDto.fromJson,
    field: 'items',
  );

  Future<ScheduleDto> saveSchedule({
    required String routeId,
    required String rrule,
    required String departureTime,
    required int fareMinor,
    required DateTime validFrom,
    String? id,
    String? vehicleId,
    DateTime? validUntil,
  }) async => ScheduleDto.fromJson(
    await _postJson('/console/v1/schedules', {
      'routeId': routeId,
      'rrule': rrule,
      'departureTime': departureTime,
      'fareMinor': fareMinor,
      'validFrom': _isoDate(validFrom),
      if (id != null) 'id': id,
      if (vehicleId != null) 'vehicleId': vehicleId,
      if (validUntil != null) 'validUntil': _isoDate(validUntil),
    }),
  );

  /// Turns a timetable into departures a traveller can buy.
  Future<MaterialisationDto> materialise({
    required String scheduleId,
    required DateTime from,
    required DateTime to,
  }) async => MaterialisationDto.fromJson(
    await _postJson('/console/v1/schedules', {
      'materialise': true,
      'id': scheduleId,
      'from': _isoDate(from),
      'to': _isoDate(to),
    }),
  );

  Future<List<DepartureBoardDto>> departureBoard(DateTime localDate) async =>
      Wire.readList(
        (await _get(
          '/console/v1/departures',
          query: {'date': _isoDate(localDate)},
        ))['items'],
        DepartureBoardDto.fromJson,
        field: 'items',
      );

  Future<ManifestDto> manifest(String departureId) async =>
      ManifestDto.fromJson(
        await _get('/console/v1/departures/$departureId/manifest'),
      );

  /// Collect against a reservation made on a phone.
  Future<CounterSaleDto> collectPayment({
    required String paymentCode,
    required String stationId,
  }) async => CounterSaleDto.fromJson(
    await _postJson('/console/v1/bookings', {
      'paymentCode': paymentCode,
      'stationId': stationId,
    }),
  );

  /// Sell across the counter to somebody standing there.
  ///
  /// Takes an [idempotencyKey] because the till's network drops mid-sale and
  /// the vendor taps again — that must return the same booking rather than a
  /// second one on different seats.
  Future<CounterSaleDto> sellAtCounter({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    String? idempotencyKey,
  }) async => CounterSaleDto.fromJson(
    await _postJson(
      '/console/v1/bookings',
      {
        'departureId': departureId,
        'buyerPhone': buyerPhone,
        'stationId': stationId,
        'passengers': [for (final p in passengers) p.toJson()],
      },
      idempotencyKey: idempotencyKey ?? IdempotencyKey.generate(),
    ),
  );

  // ── The vitrine ───────────────────────────────────────────────────────────

  /// The operator's own storefront, for the editor.
  Future<VitrineDto> vitrine() async =>
      VitrineDto.fromJson(await _get('/console/v1/vitrine'));

  /// Saves it. A `PUT` because it is one record replaced whole — an operator
  /// clearing their English tagline is sending a field, not omitting one, and
  /// a PATCH shape would make "cleared" and "unchanged" the same request.
  Future<VitrineDto> saveVitrine(SaveVitrineRequest request) async =>
      VitrineDto.fromJson(
        await _send(
          'PUT',
          '/console/v1/vitrine',
          body: request.toJson(),
        ).then((body) => body ?? const {}),
      );

  /// Uploads a logo or a cover.
  ///
  /// Raw bytes with a content type, not multipart: one file and no
  /// accompanying fields, so multipart would mean a boundary protocol to
  /// carry exactly what a request body already carries. The server sniffs the
  /// bytes regardless — [contentType] is a courtesy to proxies, not a claim it
  /// trusts.
  ///
  /// Answers with the whole vitrine, so the editor's preview re-renders from
  /// one response rather than stitching a URL into state it already holds.
  Future<VitrineDto> uploadVitrineAsset({
    required String asset,
    required List<int> bytes,
    required String contentType,
  }) async => VitrineDto.fromJson(
    await _send(
      'PUT',
      '/console/v1/vitrine/$asset',
      rawBody: bytes,
      contentType: contentType,
    ).then((body) => body ?? const {}),
  );

  Future<VitrineDto> removeVitrineAsset(String asset) async =>
      VitrineDto.fromJson(
        await _send(
          'DELETE',
          '/console/v1/vitrine/$asset',
        ).then((body) => body ?? const {}),
      );

  /// The public storefront behind `blt.cg/o/<code>`. Anonymous, and cacheable.
  Future<StorefrontDto> storefront(String code) async =>
      StorefrontDto.fromJson(await _get('/public/v1/operators/$code'));

  // ── Back office ───────────────────────────────────────────────────────────

  /// Every call below carries [BelHeaders.reason].
  ///
  /// Not a nicety: the admin middleware refuses a mutation without it with a
  /// 400, and records it against the actor on every read. The parameter is
  /// therefore required on writes and defaulted on reads — a queue that
  /// cannot be listed without typing a sentence is a queue nobody works, and
  /// the actor and the subject are recorded either way.
  Future<AdminIdentityDto> adminIdentity() async =>
      AdminIdentityDto.fromJson(await _get('/admin/v1/me'));

  /// The review queue. Empty [statuses] means everybody.
  Future<List<AdminOperatorDto>> adminOperators({
    Set<String> statuses = const {},
    String? reason,
  }) async => Wire.readList(
    (await _get(
      '/admin/v1/operators',
      query: statuses.isEmpty ? null : {'status': statuses.join(',')},
      reason: reason,
    ))['items'],
    AdminOperatorDto.fromJson,
    field: 'items',
  );

  /// One operator's file: the agreement, the documents and the trail.
  Future<AdminOperatorDetailDto> adminOperator(
    String id, {
    String? reason,
  }) async => AdminOperatorDetailDto.fromJson(
    await _get('/admin/v1/operators/$id', reason: reason),
  );

  /// approve · activate · requestInfo · reject · suspend · reinstate.
  ///
  /// **Never retried.** A 409 means this operator has moved on since the
  /// screen was drawn, and repeating the request cannot help — it can only
  /// hide from the reviewer that they were looking at a stale row.
  Future<AdminOperatorDto> decideOperator({
    required String id,
    required String decision,
    required String reason,
    String? detail,
  }) async => AdminOperatorDto.fromJson(
    await _postJson('/admin/v1/operators/$id/decision', {
      'decision': decision,
      'reason': reason,
      if (detail != null) 'detail': detail,
    }, reason: reason),
  );

  /// What this client negotiated, in basis points.
  Future<AdminOperatorDto> setOperatorCommission({
    required String id,
    required int commissionBps,
    required String reason,
  }) async => AdminOperatorDto.fromJson(
    await _send(
      'PUT',
      '/admin/v1/operators/$id/commission',
      body: {'commissionBps': commissionBps, 'reason': reason},
      reason: reason,
    ).then((body) => body ?? const {}),
  );

  /// Payments the rail never settled (ADR-0005). Longest-waiting first.
  Future<List<UnresolvedPaymentDto>> unresolvedPayments({
    String? reason,
  }) async => Wire.readList(
    (await _get('/admin/v1/payments', reason: reason))['items'],
    UnresolvedPaymentDto.fromJson,
    field: 'items',
  );

  /// `reask` · `captured` · `failed` — the queue's only exits.
  ///
  /// [reason] is the standing one, sent in the header; [evidence] is what was
  /// actually seen about *this* payment — a merchant statement line, a
  /// screenshot of a wallet. The server joins them into one `payment_events`
  /// row, and that row is the only thing that settles a dispute six weeks
  /// later. They are two parameters because they are two different claims.
  Future<UnresolvedPaymentDto> resolvePayment({
    required String intentId,
    required String outcome,
    required String reason,
    String? evidence,
    String? failureCode,
  }) async => UnresolvedPaymentDto.fromJson(
    await _postJson('/admin/v1/payments/$intentId/resolution', {
      'outcome': outcome,
      'reason': evidence == null || evidence.trim().isEmpty
          ? reason
          : evidence.trim(),
      if (failureCode != null) 'failureCode': failureCode,
    }, reason: reason),
  );

  // ── Plumbing ──────────────────────────────────────────────────────────────

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// A POST whose answer is a body, with no idempotency key by default.
  ///
  /// Distinct from [_post], which demands one: configuration writes are
  /// upserts keyed on something stable — a registration, a route code — so a
  /// retry is already safe, and demanding a key for an operation that is
  /// idempotent by construction is ceremony clients get wrong.
  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
    String? reason,
  }) async {
    final result = await _send(
      'POST',
      path,
      body: body,
      idempotencyKey: idempotencyKey,
      reason: reason,
      idempotent: idempotencyKey != null,
    );
    return result ?? const {};
  }

  /// A PUT whose 204 is a real answer rather than an empty success.
  ///
  /// Used where clearing a setting is a legitimate outcome the caller has to
  /// be able to tell apart from setting one — collapsing both into `{}` is
  /// how "no default policy" and "the default is this policy" become the same
  /// value on the client.
  Future<Map<String, Object?>?> _putJson(
    String path,
    Map<String, Object?> body,
  ) => _send('PUT', path, body: body, idempotent: true);

  Future<Map<String, Object?>> _get(
    String path, {
    Map<String, String>? query,
    String? reason,
  }) async {
    final body = await _send(
      'GET',
      path,
      query: query,
      reason: reason,
      idempotent: true,
    );
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
    List<int>? rawBody,
    String? contentType,
    String? idempotencyKey,
    String? reason,
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
      if (contentType != null) 'Content-Type': contentType,
      if (idempotencyKey != null) BelHeaders.idempotencyKey: idempotencyKey,
      if (reason != null && reason.trim().isNotEmpty)
        BelHeaders.reason: reason.trim(),
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
            .send(_request(method, uri, headers, payload, rawBody))
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

  /// A fresh request per attempt.
  ///
  /// Rebuilt rather than reused because `http.Request` is single-use — a retry
  /// that re-sent the same instance would throw about a finalized request
  /// instead of retrying, which is a bug that only appears on a flaky network.
  http.Request _request(
    String method,
    Uri uri,
    Map<String, String> headers,
    String? payload,
    List<int>? rawBody,
  ) {
    final request = http.Request(method, uri)..headers.addAll(headers);
    // Bytes win over text: an upload sets one and a JSON call sets the other,
    // and nothing sets both.
    if (rawBody != null) {
      request.bodyBytes = rawBody;
    } else if (payload != null) {
      request.body = payload;
    }
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
