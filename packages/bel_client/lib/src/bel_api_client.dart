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

  /// Departures for a route on a local calendar day, one page at a time.
  ///
  /// The page carries where the next one starts. Pass it back on
  /// `query.nextPage(cursor)` — the cursor is opaque and a client that tried
  /// to build one would be asserting an ordering only the server decides.
  Future<TripPageDto> searchTrips(SearchDeparturesQuery query) async {
    final body = await _get('/public/v1/trips', query: query.toQuery());
    return TripPageDto.fromJson(body);
  }

  /// The layout and the live availability, in one response.
  ///
  /// [from] and [to] are the pair the traveller searched with, sent back
  /// unchanged. On a whole journey they are the road's own ends and change
  /// nothing; on a piece of a road they are what makes the answer be about
  /// that piece — which seats are free between those two towns, at the price
  /// the operator set for them (ADR-0025).
  Future<SeatMapDto> seatMap(
    String departureId, {
    String? from,
    String? to,
  }) async {
    final body = await _get(
      '/public/v1/departures/$departureId/seatmap',
      query: {if (from != null) 'from': from, if (to != null) 'to': to},
    );
    return SeatMapDto.fromJson(body);
  }

  /// Ask to be told when a full coach has room again.
  ///
  /// Not idempotent-keyed and not retried on a lost answer: the server treats
  /// asking twice as asking once (one live alert per traveller per departure),
  /// so a repeat is free and a key would only hide that.
  Future<SeatAlertDto> watchSeats(String departureId, {int seats = 1}) async {
    final body = await _send(
      'POST',
      '/public/v1/departures/$departureId/alerts',
      body: WatchSeatsRequest(seatsWanted: seats).toJson(),
    );
    return SeatAlertDto.fromJson(body ?? const {});
  }

  /// Stop waiting. Succeeds when there was nothing waiting, because tapping
  /// "no longer interested" twice got what was wanted both times.
  Future<void> unwatchSeats(String departureId) => _send(
    'DELETE',
    '/public/v1/departures/$departureId/alerts',
    idempotent: true,
  );

  /// Every coach this traveller is still waiting on, soonest first.
  Future<List<SeatAlertDto>> seatAlerts() async {
    final body = await _get('/public/v1/alerts');
    return Wire.readList(body['items'], SeatAlertDto.fromJson, field: 'items');
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

  /// What this passenger may do about a disrupted journey
  /// (`08-disruption.md` §3.2).
  ///
  /// Never cached: the seat counts on the alternatives go stale in seconds,
  /// and a screen offering a coach that filled is the one failure this
  /// endpoint exists to avoid.
  Future<TravelChoicesDto> travelOptions(String bookingRef) async =>
      TravelChoicesDto.fromJson(
        await _get('/public/v1/bookings/$bookingRef/options'),
      );

  /// Take one. A move happens in this call — seats taken, ticket re-signed —
  /// so there is no second step to forget.
  Future<ChoiceAppliedDto> chooseTravel({
    required String bookingRef,
    required TravelChoiceRequest request,
  }) async => ChoiceAppliedDto.fromJson(
    await _postJson('/public/v1/bookings/$bookingRef/choice', request.toJson()),
  );

  /// The shareable trip link (ADR-0014 §2).
  ///
  /// Idempotent without an idempotency key: the server hands back the link
  /// that already exists rather than minting a second one, so a traveller who
  /// taps twice on a bad connection ends up with one link rather than one they
  /// can see and one they cannot.
  Future<TripShareDto> shareTrip(String bookingRef) async =>
      TripShareDto.fromJson(
        await _postJson('/public/v1/bookings/$bookingRef/share', const {}),
      );

  /// Their own view of it: how many people opened it, when it dies. Null when
  /// they have never shared this booking.
  Future<TripShareDto?> tripShare(String bookingRef) async {
    try {
      return TripShareDto.fromJson(
        await _get('/public/v1/bookings/$bookingRef/share'),
      );
    } on ServerRefused catch (failure) {
      // "Never shared" is not an error and must not reach a screen as one.
      if (failure.status == 404) return null;
      rethrow;
    }
  }

  Future<void> revokeTripShare(String bookingRef) => _send(
    'DELETE',
    '/public/v1/bookings/$bookingRef/share',
    idempotent: true,
  );

  /// What cancelling this booking would do (§8.2).
  ///
  /// Read before the button is drawn, never after: the sentence the traveller
  /// agrees to and the money that moves come from the same domain functions
  /// on the server (ADR-0004).
  Future<CancellationOfferDto> cancellationOffer(String bookingRef) async =>
      CancellationOfferDto.fromJson(
        await _get('/public/v1/bookings/$bookingRef/cancellation'),
      );

  /// Does it. The seat is on sale again before this returns.
  Future<CancellationDoneDto> cancelBooking(String bookingRef) async =>
      CancellationDoneDto.fromJson(
        await _postJson(
          '/public/v1/bookings/$bookingRef/cancellation',
          const {},
        ),
      );

  /// Where else this booking could go, priced (§8.1).
  ///
  /// Never cached: the seat counts and the free window are the content of the
  /// screen, and a list drawn from this morning's answer offers a coach that
  /// filled at lunchtime.
  Future<ChangeOptionsDto> changeOptions(String bookingRef) async =>
      ChangeOptionsDto.fromJson(
        await _get('/public/v1/bookings/$bookingRef/reschedule'),
      );

  /// Moves them. The seats are taken and the ticket re-signed inside this
  /// call, so there is nothing left to do afterwards and nothing to forget.
  Future<ChangeAppliedDto> changeDeparture({
    required String bookingRef,
    required String departureId,
  }) async => ChangeAppliedDto.fromJson(
    await _postJson('/public/v1/bookings/$bookingRef/reschedule', {
      'departureId': departureId,
    }),
  );

  /// Holds a change and says what it costs, without moving anything (§8.1).
  ///
  /// The seats on the target departure are taken for the length of the
  /// payment window; the booking moves only when the difference is captured.
  /// An order that comes back `applied` owed nothing at the lock — the price
  /// fell between the list and the tap, and the change was simply made.
  Future<ChangeOrderDto> orderChange({
    required String bookingRef,
    required String departureId,
  }) async => ChangeOrderDto.fromJson(
    await _postJson('/public/v1/bookings/$bookingRef/reschedule/order', {
      'departureId': departureId,
    }),
  );

  /// Gives the held seats back before the window runs out.
  ///
  /// Idempotent for the same reason releasing a hold is, so no key is
  /// required. A payment already in flight refuses with a 409: releasing
  /// those seats a second before a capture lands strands money.
  Future<void> cancelChangeOrder(String bookingRef) => _send(
    'DELETE',
    '/public/v1/bookings/$bookingRef/reschedule/order',
    idempotent: true,
  );

  /// How this booking can be paid, and where the money goes.
  ///
  /// Server-driven: a rail appears only if this deployment can reach it AND
  /// the operator has a verified account on it. Enabling one is a config push
  /// rather than an app release (ADR-0006).
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId, {String? changeId}) async {
    final body = await _get(
      '/public/v1/bookings/$bookingId/payment-options'
      '${changeId == null ? '' : '?change=$changeId'}',
    );
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

  /// How long this operator's paperwork has left
  /// (`03-operator-lifecycle.md` §3.3).
  ///
  /// Read on every console start rather than on a compliance screen, because
  /// there is no compliance screen: the whole point is that it finds the
  /// person, in the console they already had open, before the sales stop.
  Future<ComplianceDto> compliance() async =>
      ComplianceDto.fromJson(await _get('/console/v1/compliance'));

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

  /// What cancelling this booking would give back, under the terms it was
  /// sold with. A quote, not a refund.
  // ── Onboarding (03-operator-lifecycle.md §2.2) ────────────────────────────

  /// Whatever this account is applying with, or null when it has never
  /// started.
  ///
  /// Null rather than a thrown 404, because "no application" is the normal
  /// state of every account on the platform — it is what a traveller who has
  /// never thought about selling tickets looks like, and a client that has to
  /// catch an exception to learn that is a client that logs an error a
  /// million times a day.
  Future<OperatorApplicationDto?> myApplication() async {
    try {
      return OperatorApplicationDto.fromJson(
        await _get('/public/v1/operator-applications'),
      );
    } on ServerRefused catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<OperatorApplicationDto> startApplication(String legalName) async =>
      OperatorApplicationDto.fromJson(
        await _postJson('/public/v1/operator-applications', {
          'legalName': legalName,
        }),
      );

  /// Saves the whole record. Called constantly by the wizard — §2.2's "save
  /// on every field" — and safe to repeat because it replaces rather than
  /// merges.
  Future<OperatorApplicationDto> saveApplication(ApplicationFacts facts) async {
    final body = await _putJson(
      '/public/v1/operator-applications',
      ApplicationFactsDto(facts).toJson(),
    );
    return OperatorApplicationDto.fromJson(body ?? const {});
  }

  Future<OperatorApplicationDto> submitApplication() async =>
      OperatorApplicationDto.fromJson(
        await _postJson('/public/v1/operator-applications/submit', const {}),
      );

  Future<RefundOfferDto> refundOffer(String bookingRef) async =>
      RefundOfferDto.fromJson(
        await _get('/console/v1/bookings/$bookingRef/refund'),
      );

  /// Cancels the booking and records what is owed.
  ///
  /// The reason is mandatory and is not ceremony: it is the only thing that
  /// answers "why did we give this person money?" six weeks later.
  Future<IssuedRefundDto> refundBooking({
    required String bookingRef,
    required String reason,
  }) async => IssuedRefundDto.fromJson(
    await _postJson('/console/v1/bookings/$bookingRef/refund', {
      'reason': reason,
    }),
  );

  /// Pays a claim out of a station's drawer and closes it.
  Future<ClaimedRefundDto> claimRefund({
    required String claimCode,
    required String stationId,
  }) async => ClaimedRefundDto.fromJson(
    await _postJson('/console/v1/refunds/claim', {
      'claimCode': claimCode,
      'stationId': stationId,
    }),
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
    ChangePolicy change = ChangePolicy.standard,
    MissedPolicy missed = MissedPolicy.notOffered,
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
      'change': ChangePolicyDto.fromDomain(change).toJson(),
      'missed': MissedPolicyDto.fromDomain(missed).toJson(),
    }),
  );

  /// Later coaches for a passenger whose own coach has gone.
  ///
  /// A counter call: the reference is being read off a printed ticket by the
  /// person holding it, and whether to honour it is the company's decision.
  Future<MissedOptionsDto> missedOptions(String bookingRef) async =>
      MissedOptionsDto.fromJson(
        await _get('/console/v1/bookings/$bookingRef/missed'),
      );

  /// Puts them on one, takes the fee, and re-signs the ticket.
  ///
  /// [stationId] is the drawer the cash goes into — required when anything is
  /// owed, refused when nothing is.
  Future<MissedTransferDto> moveMissed({
    required String bookingRef,
    required String departureId,
    String? stationId,
  }) async => MissedTransferDto.fromJson(
    await _postJson('/console/v1/bookings/$bookingRef/missed', {
      'departureId': departureId,
      if (stationId != null) 'stationId': stationId,
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
    List<RouteStopDto>? stops,
    List<SegmentFareDto>? segments,
  }) async => RouteDto.fromJson(
    await _postJson('/console/v1/routes', {
      'code': code,
      'originCity': originCity,
      'destinationCity': destinationCity,
      'durationMinutes': durationMinutes,
      if (id != null) 'id': id,
      if (distanceKm != null) 'distanceKm': distanceKm,
      // Sent only when the caller means to describe the road. Absent leaves
      // the stops alone; an empty list erases them, which is how the last
      // one is removed.
      if (stops != null) 'stops': [for (final stop in stops) stop.toJson()],
      // Same rule, one line down: absent leaves the price list alone, an
      // empty list is how the last leg comes off sale (ADR-0025).
      if (segments != null)
        'segments': [for (final fare in segments) fare.toJson()],
    }),
  );

  /// The terminals this operator uses, closed ones included: reopening one
  /// should not need a database.
  Future<List<StationDto>> stations() async => Wire.readList(
    (await _get('/console/v1/stations'))['items'],
    StationDto.fromJson,
    field: 'items',
  );

  /// Opens a yard, corrects one, or closes one. Coordinates travel as a pair
  /// or not at all — a latitude with no longitude is a marker in the sea.
  Future<StationDto> saveStation({
    required String cityCode,
    required String name,
    String? id,
    double? lat,
    double? lng,
    String? boardingNotes,
    bool active = true,
  }) async => StationDto.fromJson(
    await _postJson('/console/v1/stations', {
      'cityCode': cityCode,
      'name': name,
      'active': active,
      if (id != null) 'id': id,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (boardingNotes != null && boardingNotes.isNotEmpty)
        'boardingNotes': boardingNotes,
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
    String? originStationId,
    String? destinationStationId,
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
      if (originStationId != null) 'originStationId': originStationId,
      if (destinationStationId != null)
        'destinationStationId': destinationStationId,
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

  /// Declares a disruption on a departure (`08-disruption.md` §2.1).
  ///
  /// The request is validated by the same domain function the server runs, so
  /// the console can refuse a delay with no new time before spending a round
  /// trip on it — at a roadside, on 2G, that round trip is the whole latency
  /// budget.
  Future<DeclaredDisruptionDto> declareDisruption({
    required String departureId,
    required DeclareDisruptionRequest request,
  }) async => DeclaredDisruptionDto.fromJson(
    await _postJson(
      '/console/v1/departures/$departureId/disruptions',
      request.toJson(),
    ),
  );

  /// Sends a different coach, and answers with where everybody now sits.
  Future<RescueAppliedDto> assignRescueCoach({
    required String departureId,
    required RescueCoachRequest request,
  }) async => RescueAppliedDto.fromJson(
    await _postJson(
      '/console/v1/departures/$departureId/rescue',
      request.toJson(),
    ),
  );

  /// This operator's own payout statements, newest first.
  ///
  /// A read and only a read. The party being paid does not get to move the
  /// row that pays them — there is no console method to write one, because
  /// there is no route, because the grant does not allow it.
  Future<List<PayoutRunDto>> statements() async => Wire.readList(
    (await _get('/console/v1/statements'))['items'],
    PayoutRunDto.fromJson,
    field: 'items',
  );

  /// One statement as the document an accountant files (`04-payments.md`
  /// §6.2).
  ///
  /// Bytes, not JSON: this is the one call in the client that does not come
  /// back as a DTO. The filename comes from the server rather than being
  /// built here, because the server is what knows the operator's legal name
  /// and the period — and a document whose name is composed on four clients
  /// is four differently-named copies of one file.
  Future<DownloadedFile> statementPdf(String runId) =>
      _download('/console/v1/statements/$runId/pdf');

  /// The same document, from the back office's queue.
  Future<DownloadedFile> payoutPdf(String runId) =>
      _download('/admin/v1/payouts/$runId/pdf');

  /// The standing protection agreements this operator is a party to, in
  /// either role (`08-disruption.md` §5).
  Future<List<ProtectionAgreementDto>> protectionAgreements() async =>
      Wire.readList(
        (await _get('/console/v1/protection'))['items'],
        ProtectionAgreementDto.fromJson,
        field: 'items',
      );

  Future<ProtectionAgreementDto> proposeAgreement(
    ProposeAgreementRequest request,
  ) async => ProtectionAgreementDto.fromJson(
    await _postJson('/console/v1/protection', request.toJson()),
  );

  /// `accept` · `decline` · `suspend` · `resume` · `end`. One method for five
  /// decisions, because the rule they share — the party that wrote the terms
  /// is not the party that agrees to them — is checked in one place.
  Future<ProtectionAgreementDto> decideAgreement({
    required String agreementId,
    required AgreementDecisionRequest request,
  }) async => ProtectionAgreementDto.fromJson(
    await _postJson(
      '/console/v1/protection/$agreementId/decision',
      request.toJson(),
    ),
  );

  /// Protection requests this operator is a party to, in either direction
  /// (`08-disruption.md` §2.3).
  ///
  /// One list rather than an inbox and an outbox: the same row is what we are
  /// waiting on and what they are waiting on, and a console that fetched them
  /// separately would show a decided request in one list and a pending one in
  /// the other for as long as the two calls were apart.
  Future<List<ProtectionRequestDto>> protectionRequests() async =>
      Wire.readList(
        (await _get('/console/v1/protection/requests'))['items'],
        ProtectionRequestDto.fromJson,
        field: 'items',
      );

  /// Ask another company for room on a coach of theirs.
  Future<ProtectionRequestDto> askForProtection(
    ProtectionRequestBody request,
  ) async => ProtectionRequestDto.fromJson(
    await _postJson('/console/v1/protection/requests', request.toJson()),
  );

  /// `accept` or `decline`, by the company being asked.
  ///
  /// Accepting **moves the passengers in the same call**: the seats are taken,
  /// the bookings and tickets change hands and the rebill posts. There is no
  /// second step to forget.
  Future<ProtectionRequestDto> decideProtectionRequest({
    required String requestId,
    required AgreementDecisionRequest request,
  }) async => ProtectionRequestDto.fromJson(
    await _postJson(
      '/console/v1/protection/requests/$requestId/decision',
      request.toJson(),
    ),
  );

  // ── Open protection (§5) ──────────────────────────────────────────────

  /// The open calls this operator can see, and whether they are even in the
  /// channel.
  ///
  /// `receiving` travels with the list on purpose: an empty inbox has to be
  /// able to say which kind of empty it is. *Nobody needs help right now* and
  /// *you never opted in* are the same zero rows and completely different
  /// screens, and a client that had to ask twice would draw the wrong one for
  /// as long as the two calls were apart.
  Future<OpenCallsDto> openProtectionCalls() async =>
      OpenCallsDto.fromJson(await _get('/console/v1/protection/open'));

  /// Broadcast a request for room to every opted-in operator on the road.
  Future<OpenCallDto> openProtectionCall(OpenCallBody body) async =>
      OpenCallDto.fromJson(
        await _postJson('/console/v1/protection/open', body.toJson()),
      );

  /// Take it back. Only the sender can, and only while it is open.
  Future<OpenCallDto> withdrawProtectionCall(String callId) async =>
      OpenCallDto.fromJson(
        (await _send(
          'DELETE',
          '/console/v1/protection/open/$callId',
          idempotent: true,
        ))!,
      );

  /// Answer one with a departure of ours. **First to accept wins**, and a
  /// loser is told so rather than left believing they have taken it on.
  Future<ProtectionRequestDto> answerProtectionCall({
    required String callId,
    required AnswerCallBody body,
  }) async => ProtectionRequestDto.fromJson(
    await _postJson(
      '/console/v1/protection/open/$callId/answer',
      body.toJson(),
    ),
  );

  /// Opt in or out of receiving open calls. Returns what it now is.
  Future<bool> receiveOpenProtectionCalls(bool receiving) async {
    final body = await _putJson('/console/v1/protection/open/receiving', {
      'receiving': receiving,
    });
    return (body ?? const {})['receiving'] as bool? ?? false;
  }

  /// The expiry calendar across every operator, worst first
  /// (`03-operator-lifecycle.md` §6, "Conformité").
  ///
  /// [withinDays] widens the window. Already-lapsed documents are always
  /// included: a calendar that only looked forward would drop an operator off
  /// the screen at the moment they became the reason for a phone call.
  Future<List<ComplianceDto>> complianceCalendar({
    String? reason,
    int withinDays = 60,
  }) async => Wire.readList(
    (await _get(
      '/admin/v1/compliance?days=$withinDays',
      reason: reason,
    ))['items'],
    ComplianceDto.fromJson,
    field: 'items',
  );

  /// The platform's payout queue: prepared and not yet paid, oldest first.
  Future<List<PayoutRunDto>> payoutQueue({String? reason}) async =>
      Wire.readList(
        (await _get('/admin/v1/payouts', reason: reason))['items'],
        PayoutRunDto.fromJson,
        field: 'items',
      );

  Future<PayoutRunDto> preparePayout(
    PreparePayoutRequest request, {
    required String reason,
  }) async => PayoutRunDto.fromJson(
    await _postJson('/admin/v1/payouts', request.toJson(), reason: reason),
  );

  /// Approve a prepared run, or release an approved one. Two calls on
  /// purpose, by two different people (ADR-0011).
  Future<PayoutRunDto> decidePayout({
    required String runId,
    required PayoutDecisionRequest request,
    required String reason,
  }) async => PayoutRunDto.fromJson(
    await _postJson(
      '/admin/v1/payouts/$runId/decision',
      request.toJson(),
      reason: reason,
    ),
  );

  /// Move the passengers onto another of this operator's departures.
  ///
  /// Partial coverage is a success — the answer says how many are still on
  /// the broken coach, and a client that treated "18 / 42" as a failure would
  /// undo the eighteen.
  Future<RebookingAppliedDto> rebookOnto({
    required String departureId,
    required RebookRequest request,
  }) async => RebookingAppliedDto.fromJson(
    await _postJson(
      '/console/v1/departures/$departureId/rebook',
      request.toJson(),
    ),
  );

  Future<ManifestDto> manifest(String departureId) async =>
      ManifestDto.fromJson(
        await _get('/console/v1/departures/$departureId/manifest'),
      );

  /// The one request a scanner makes, in the yard, before the door opens
  /// (ADR-0022). Everything after it is a local decision.
  Future<BoardingManifestDto> pinForBoarding(String departureId) async =>
      BoardingManifestDto.fromJson(
        await _get('/console/v1/departures/$departureId/boarding'),
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

  /// Where people leave, by day (`04-payments.md` §8).
  ///
  /// Counted from holds, bookings and intents — rows that exist because a
  /// sale happened, not because a tracker fired. The response says so in
  /// `countsFrom`, and the screen repeats it: there is no search figure here.
  Future<FunnelDto> funnel({
    String? reason,
    int days = 14,
    String? operatorId,
    String channel = 'app',
  }) async => FunnelDto.fromJson(
    await _get(
      '/admin/v1/analytics/funnel',
      query: {
        'days': '$days',
        'channel': channel,
        if (operatorId != null) 'operatorId': operatorId,
      },
      reason: reason,
    ),
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

  /// A binary read.
  ///
  /// Separate from [_send] because that one decodes JSON, and a PDF decoded
  /// as JSON is an `UnreadableResponse` for a response that was perfectly
  /// readable. A refusal still arrives as JSON — the API's error shape is the
  /// same on every route — so the failure path parses and the success path
  /// does not.
  ///
  /// Retried like any other GET: a download is idempotent by definition, and
  /// the failure it actually meets is a dropped connection on 2G.
  Future<DownloadedFile> _download(String path) async {
    final uri = _base.replace(path: '${_base.path}$path');
    final headers = <String, String>{
      'Accept': 'application/pdf',
      BelHeaders.language: language,
      if (appVersion != null) BelHeaders.appVersion: appVersion!,
      if (deviceId != null) BelHeaders.deviceId: deviceId!,
    };

    final bearer = await _token?.call();
    if (bearer != null && bearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearer';
    }

    ApiFailure? lastFailure;

    for (var attempt = 0; attempt <= retry.maxAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retry.delayFor(attempt));

      try {
        final response = await _http
            .send(_request('GET', uri, headers, null, null))
            .then(http.Response.fromStream)
            .timeout(timeout);

        if (response.statusCode >= 400) {
          throw ServerRefused(
            response.statusCode,
            response.body.isEmpty
                ? ApiError(code: _codeForStatus(response.statusCode))
                : ApiError.fromJson(_decode(response.body)),
          );
        }

        return DownloadedFile(
          bytes: response.bodyBytes,
          contentType:
              response.headers['content-type'] ?? 'application/octet-stream',
          filename: _filenameFrom(response.headers['content-disposition']),
        );
      } on ServerRefused catch (failure) {
        if (!failure.retryable) rethrow;
        lastFailure = failure;
      } on TimeoutException {
        lastFailure = RequestTimedOut(timeout);
      } on UnreadableResponse {
        rethrow;
      } on Object catch (e) {
        lastFailure = NetworkUnreachable(e.toString());
      }
    }

    throw lastFailure ?? const NetworkUnreachable();
  }

  /// `attachment; filename="releve-ocean-du-nord-2026-08-01.pdf"`.
  ///
  /// Null when the header is absent or shaped in a way we do not recognise,
  /// and the caller then names the file itself. Guessing at a header we
  /// cannot parse would be how a download arrives called `attachment;`.
  static String? _filenameFrom(String? disposition) {
    if (disposition == null) return null;
    final match = RegExp(
      'filename="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(disposition);
    final name = match?.group(1)?.trim();
    return name == null || name.isEmpty ? null : name;
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

/// A file the server sent, with the name it chose for it.
final class DownloadedFile {
  const DownloadedFile({
    required this.bytes,
    required this.contentType,
    this.filename,
  });

  final List<int> bytes;
  final String contentType;

  /// From `Content-Disposition`, or null when the server did not say. The
  /// server names it because the server knows the operator's legal name and
  /// the period — a name composed on the client is a different name on every
  /// surface.
  final String? filename;
}
