import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';

import 'adapters/acs_notification_gateway.dart';
import 'adapters/fake_auth_gateway.dart';
import 'adapters/firebase_auth_gateway.dart';
import 'adapters/logging_notification_gateway.dart';
import 'adapters/unavailable_operator_console.dart';
import 'adapters/memory_idempotency_store.dart';
import 'application/hold_seats.dart';
import 'adapters/airtel_money_gateway.dart';
import 'adapters/ed25519_ticket_issuer.dart';
import 'adapters/fake_payment_gateway.dart';
import 'adapters/mtn_momo_gateway.dart';
import 'application/ports/booking_store.dart';
import 'application/ports/ticket_issuer.dart';
import 'application/ports/city_catalogue.dart';
import 'application/ports/disruption_desk.dart';
import 'application/ports/payout_desk.dart';
import 'application/ports/protection_desk.dart';
import 'application/ports/passenger_choices.dart';
import 'application/ports/self_cancellation.dart';
import 'application/ports/trip_sharing.dart';
import 'application/ports/operator_console.dart';
import 'application/ports/payment_gateway.dart';
import 'application/ports/payment_store.dart';
import 'application/ports/operator_applications.dart';
import 'application/ports/platform_console.dart';
import 'application/ports/departure_catalogue.dart';
import 'application/ports/notification_gateway.dart';
import 'application/ports/seat_inventory.dart';
import 'application/ports/object_store.dart';
import 'application/ports/storefronts.dart';
import 'application/ports/user_directory.dart';
import 'application/pay_for_booking.dart';
import 'application/reserve_booking.dart';
import 'application/search_departures.dart';
import 'application/second_factor_sign_in.dart';
import 'application/sign_in.dart';
import 'infrastructure/config/market_catalog.dart';
import 'infrastructure/db/database.dart';
import 'infrastructure/memory/memory_booking_store.dart';
import 'infrastructure/memory/memory_operator_directory.dart';
import 'infrastructure/memory/memory_payment_store.dart';
import 'infrastructure/memory/memory_city_catalogue.dart';
import 'infrastructure/memory/memory_identity.dart';
import 'infrastructure/azure/azure_blob_store.dart';
import 'infrastructure/memory/memory_object_store.dart';
import 'infrastructure/memory/memory_seat_inventory.dart';
import 'infrastructure/memory/memory_second_factors.dart';
import 'infrastructure/memory/memory_operator_applications.dart';
import 'infrastructure/memory/memory_storefronts.dart';
import 'infrastructure/postgres/postgres_departure_catalogue.dart';
import 'infrastructure/postgres/postgres_booking_store.dart';
import 'infrastructure/postgres/postgres_identity.dart';
import 'infrastructure/postgres/postgres_operator_applications.dart';
import 'infrastructure/postgres/postgres_disruptions.dart';
import 'infrastructure/postgres/postgres_payouts.dart';
import 'infrastructure/postgres/postgres_protection.dart';
import 'infrastructure/postgres/postgres_passenger_choices.dart';
import 'infrastructure/postgres/postgres_self_cancellation.dart';
import 'infrastructure/postgres/postgres_trip_sharing.dart';
import 'infrastructure/postgres/postgres_operator_console.dart';
import 'infrastructure/postgres/postgres_operator_directory.dart';
import 'infrastructure/postgres/postgres_payment_store.dart';
import 'infrastructure/postgres/postgres_platform_console.dart';
import 'infrastructure/postgres/postgres_idempotency_store.dart';
import 'infrastructure/postgres/postgres_seat_inventory.dart';
import 'infrastructure/postgres/postgres_second_factors.dart';
import 'infrastructure/postgres/postgres_storefronts.dart';
import 'middleware/idempotency.dart';
import 'ports/auth_gateway.dart';

/// Where the wires meet.
///
/// The one file allowed to know both an interface and its adapter. Everything
/// else takes ports, which is what makes swapping Postgres for a fake — or
/// Airtel for Orange Money later — a change here and nowhere else.
///
/// **No `DATABASE_URL` means fakes.** Deliberate: `dart_frog dev` and
/// `tool/smoke_api.sh` work on a fresh clone with nothing installed, so the
/// first thing a new engineer sees is a running API rather than a stack trace
/// about a socket. The moment the variable is set, every one of these becomes
/// the real thing and the handlers do not notice.
final class Services {
  Services._({
    required this.holdSeats,
    required this.searchDepartures,
    required this.signIn,
    required this.secondFactor,
    required this.reserveBooking,
    required this.bookings,
    required this.console,
    required this.disruptions,
    required this.payouts,
    required this.protection,
    required this.choices,
    required this.sharing,
    required this.cancellations,
    required this.platform,
    required this.storefronts,
    required this.applications,
    required this.storage,
    required this.payments,
    required this.payForBooking,
    required this.railIds,
    required this.market,
    required this.authGateway,
    required this.directory,
    required this.catalogue,
    required this.cities,
    required this.inventory,
    required this.idempotency,
    required this.clock,
    required this.usingDatabase,
    required this.smsConfigured,
    Database? database,
  }) : _database = database;

  final HoldSeats holdSeats;
  final SearchDepartures searchDepartures;
  final SignIn signIn;

  /// The authenticator step in front of both back offices.
  ///
  /// A field on `Services` rather than something the sign-in route builds,
  /// because three routes need it — sign in, enrol, confirm — and the one
  /// thing they must agree on is the key that signs the half-session.
  final SecondFactorSignIn secondFactor;
  final ReserveBooking reserveBooking;
  final BookingStore bookings;

  /// The operator surface. Backed by Postgres, or by an adapter that refuses
  /// with a message naming `DATABASE_URL` — the console configures the world
  /// the traveller browses, and a fake one would be a second definition of
  /// every coach and route, kept in sync by hand.
  final OperatorConsole console;

  /// The dispatcher's disruption desk (`08-disruption.md`). Separate from
  /// [console] because it is the one operator surface a passenger feels
  /// within seconds: declaring writes a record, moves the departure, marks
  /// the bookings and queues a message to everybody on board.
  final DisruptionDesk disruptions;

  /// The payout run (`04-payments.md` §6.2). On the platform surface on
  /// purpose: an operator reads their statements and cannot write one, which
  /// is what makes two-person control on money leaving mean anything.
  final PayoutDesk payouts;

  /// Inter-operator protection agreements (`08-disruption.md` §5). On the
  /// tenant scope of whoever is asking, because 0019 is the one table in this
  /// schema a row of which belongs to *two* operators — the policies let
  /// either party read it and only the proposer write it, so the adapter does
  /// not have to be careful.
  final ProtectionDesk protection;

  /// The passenger deciding for themselves (`08-disruption.md` §3.2).
  ///
  /// Reads run as the traveller — their booking is theirs by policy, and the
  /// alternatives are rows anybody searching the route can already see.
  /// Committing escalates, because a movement writes seats and tickets that
  /// belong to the operator, and everything that makes the passenger entitled
  /// is re-checked inside that transaction.
  final PassengerChoices choices;

  /// Sharing a trip with somebody who is not a customer (ADR-0014 §2).
  final TripSharing sharing;

  /// The traveller cancelling their own booking (§8.2). Separate from the
  /// console's refund because the actor is, and because the common case here
  /// — a reservation nobody paid for — moves no money at all.
  final SelfCancellation cancellations;

  /// Our own back office. Refuses without a database for the same reason the
  /// operator console does — and more so: every read here is meant to cross
  /// tenants, and a fake with no tenants to cross would be theatre.
  final PlatformConsole platform;

  /// An operator's storefront, on both surfaces: the editor they configure it
  /// from and the public page a stranger opens. One port, because the live
  /// preview in that editor is only honest if it previews the same record.
  final Storefronts storefronts;

  /// Self-signup (`03-operator-lifecycle.md` §2.2). On the **public** surface
  /// and not the console's, because an applicant belongs to no tenant yet —
  /// that is the whole situation — so the console's middleware would refuse
  /// them before a handler ran.
  final OperatorApplications applications;

  /// Where a logo goes.
  ///
  /// Azure Blob when `STORAGE__ACCOUNT` and `STORAGE__KEY` are set, an
  /// in-memory map otherwise — the same shape as the database decision, and
  /// for the same reason: a fresh clone should upload a file and see it come
  /// back rather than read a stack trace about a missing account.
  final ObjectStore storage;

  /// Resolves a vitrine's storage keys into URLs a client can fetch.
  ///
  /// Here rather than in the adapter because *where a file can be fetched
  /// from* is a fact about this deployment — the account, the container and
  /// whatever CDN sits in front of them — and the database row knows none of
  /// it. Public URLs, not signed ones: a logo is on a poster and a cached
  /// page, and a signature that expires would break an image nobody was
  /// protecting.
  VitrineDto withAssetUrls(VitrineDto vitrine) => vitrine.withAssetUrls(
    logoUrl: vitrine.logoAsset == null
        ? null
        : storage.publicUrl(vitrine.logoAsset!).toString(),
    coverUrl: vitrine.coverAsset == null
        ? null
        : storage.publicUrl(vitrine.coverAsset!).toString(),
  );

  final PaymentStore payments;
  final PayForBooking payForBooking;

  /// The rails this deployment can actually collect on. Intersected with the
  /// operator's verified accounts before anything is offered, so a rail we
  /// cannot reach is absent rather than present-and-broken.
  final Set<String> railIds;

  /// The country this deployment serves, read from `config/markets.yaml` at
  /// startup rather than compiled in (ADR-0006).
  ///
  /// Every handler that needs a currency, a dialling code, a service fee or a
  /// rail list reads it from here — `Market.current` is now only the fallback
  /// that runs when there is no file. That is the whole difference between
  /// enabling Orange Money with a config push and enabling it with a release.
  final Market market;

  /// Who the caller is. Firebase behind a real database, a deterministic fake
  /// otherwise — the same condition under which the inventory is a fake, so a
  /// token that works locally is worthless anywhere real.
  final AuthGateway authGateway;

  final UserDirectory directory;
  final DepartureCatalogue catalogue;
  final CityCatalogue cities;
  final SeatInventory inventory;
  final Idempotency idempotency;
  final Clock clock;

  /// False when the API is running on fakes. Reported by `/health`, because
  /// "the tests passed" and "the tests passed against a database" are
  /// different claims and confusing them wastes an afternoon.
  final bool usingDatabase;

  /// Whether a message sent to a handset would actually arrive.
  ///
  /// Reported so the sign-in route can refuse the phone channel outright
  /// rather than accepting it and leaving a traveller on a screen waiting for
  /// an SMS that is never coming. Email is the channel that works today
  /// (ADR-0019); phone is second, and this is the switch that turns it on.
  final bool smsConfigured;

  final Database? _database;

  factory Services.resolve({
    Map<String, String>? environment,
    Clock clock = const SystemClock(),
  }) {
    final env = environment ?? Platform.environment;
    final market = marketCatalog(env).defaultMarket;
    final url = env['DATABASE_URL'];

    if (url == null || url.isEmpty) {
      return Services.inMemory(clock: clock, environment: env);
    }

    final db = Database.open(url);
    final inventory = PostgresSeatInventory(db);
    final catalogue = PostgresDepartureCatalogue(db, timeZone: market.timeZone);

    final directory = PostgresUserDirectory(db);

    // Tickets are signed with the KMS key in a real environment; the fixed
    // development seed keeps a ticket signed by yesterday's run verifiable
    // today (ADR-0020). Resolved once, at startup, because key material is
    // not something to fetch per request.
    final bookings = PostgresBookingStore(db, issuer: _ticketIssuer);
    final paymentStore = PostgresPaymentStore(db);
    final rails = _railsFrom(env, market);

    return Services._(
      holdSeats: HoldSeats(inventory: inventory, market: market),
      searchDepartures: SearchDepartures(catalogue: catalogue, market: market),
      signIn: SignIn(
        challenges: PostgresAuthChallenges(db),
        // Tunable without a deploy, like `max_attempts` is a column rather
        // than a constant. A market with worse deliverability, or one whose
        // traffic sits behind a single carrier NAT, needs a different number
        // — and finding that out is not a reason to ship a release.
        maxPerSource: _maxPerSource(env),
        directory: directory,
        notifications: _notifications(env),
        render: _renderSignInMessage,
        mac: const HmacSha256Authenticator(),
        codeKey: _codeKey(env),
        clock: clock,
        msisdn: market.msisdn,
      ),
      // Shares `_codeKey` with the sign-in above on purpose: both sign a
      // short-lived claim about the same person, minutes apart, and a second
      // key would be a second thing to rotate and a second way to get it
      // wrong.
      secondFactor: SecondFactorSignIn(
        factors: PostgresSecondFactors(db),
        mac: const HmacSha256Authenticator(),
        signingKey: _codeKey(env),
        clock: clock,
      ),
      reserveBooking: ReserveBooking(bookings: bookings, market: market),
      bookings: bookings,
      console: PostgresOperatorConsole(db, timeZone: market.timeZone),
      disruptions: PostgresDisruptions(db, issuer: _ticketIssuer),
      payouts: PostgresPayouts(db),
      protection: PostgresProtection(db, issuer: _ticketIssuer),
      choices: PostgresPassengerChoices(db, issuer: _ticketIssuer),
      sharing: PostgresTripSharing(
        db,
        shareBase: Uri.parse(env['BEL__SHAREBASEURL'] ?? 'https://blt.cg'),
      ),
      cancellations: PostgresSelfCancellation(db),
      platform: PostgresPlatformConsole(db),
      storefronts: PostgresStorefronts(db),
      applications: PostgresOperatorApplications(db),
      // Falls back to the in-memory store rather than refusing to start. A
      // deployment with a database and no storage account is a real state —
      // it is every deployment on the day before the storage account is
      // provisioned — and `/health` reports it rather than the API dying.
      storage: AzureBlobStore.fromEnvironment(env) ?? MemoryObjectStore(),
      payments: paymentStore,
      payForBooking: PayForBooking(
        market: market,
        payments: paymentStore,
        bookings: bookings,
        // The commission is a term of one operator's contract, so it is read
        // from their row when a fare settles — never from a constant here.
        operators: PostgresOperatorDirectory(db),
        gateways: rails,
      ),
      railIds: rails.keys.toSet(),
      market: market,
      authGateway: FirebaseAuthGateway(
        config: FirebaseConfig.fromEnvironment(env),
        directory: directory,
        clock: clock,
      ),
      directory: directory,
      catalogue: catalogue,
      cities: PostgresCityCatalogue(db),
      inventory: inventory,
      // Scoped per request in the handler; this instance carries the anonymous
      // scope so a key written outside a signed-in request cannot masquerade
      // as one.
      idempotency: Idempotency(
        PostgresIdempotencyStore(db, scope: const DbScope.anonymous()),
      ),
      clock: clock,
      usingDatabase: true,
      smsConfigured: (env['COMMS__SMSFROM'] ?? '').isNotEmpty,
      database: db,
    );
  }

  /// How many sign-in codes one host may ask for per hour.
  ///
  /// Thirty by default: loose on purpose (migration 0016). One address here
  /// is routinely one building, and a bound tight enough to stop a determined
  /// attacker would lock out an agency counter.
  static int _maxPerSource(Map<String, String> env) {
    final raw = env['BEL_SIGNIN_MAX_PER_SOURCE'];
    final parsed = raw == null ? null : int.tryParse(raw);
    return parsed != null && parsed > 0 ? parsed : 30;
  }

  /// Fakes, with one coach already on sale so the API answers something useful
  /// on a fresh clone.
  factory Services.inMemory({
    Clock clock = const SystemClock(),
    List<MemoryDeparture>? departures,
    NotificationGateway? notifications,
    Map<String, String>? environment,
  }) {
    final market = marketCatalog(environment).defaultMarket;
    final inventory = MemorySeatInventory(
      clock: clock,
      departures:
          departures ??
          [
            MemoryDeparture.coach(
              id: 'dep-demo-0001',
              operatorId: 'op-demo',
              departsAt: clock.now().add(const Duration(days: 1)),
            ),
          ],
    );

    final catalogue = MemoryDepartureCatalogue(inventory, clock: clock);
    final directory = MemoryUserDirectory(clock: clock)
      // The account behind `FakeAuthGateway.demo`'s bearer. Seeded rather than
      // left absent so the demo token is a *whole* traveller — one that can
      // read its profile and enrol a second factor, not just hold a seat.
      ..seed(
        Account(
          id: 'u-demo-traveller',
          authUid: 'demo',
          language: 'fr',
          email: 'demo@billetenligne.cg',
          emailVerifiedAt: clock.now(),
        ),
      );
    final memoryBookings = MemoryBookingStore(
      inventory: inventory,
      issuer: _ticketIssuer,
      clock: clock,
    );
    final memoryPayments = MemoryPaymentStore(
      bookings: memoryBookings,
      clock: clock,
    );

    return Services._(
      holdSeats: HoldSeats(inventory: inventory, market: market),
      searchDepartures: SearchDepartures(catalogue: catalogue, market: market),
      signIn: SignIn(
        challenges: MemoryAuthChallenges(clock: clock),
        directory: directory,
        // Prints the code to the log, which is the whole point of the fakes
        // composition: a fresh clone can complete a sign-in with nothing
        // installed and no message reaching anybody's inbox.
        notifications: notifications ?? const LoggingNotificationGateway(),
        render: _renderSignInMessage,
        mac: const HmacSha256Authenticator(),
        codeKey: _developmentCodeKey,
        clock: clock,
        // Read here too, so the fakes composition refuses exactly where the
        // real one does. A fake that is more permissive than the server is a
        // fake that lets a limit ship untested.
        maxPerSource: _maxPerSource(environment ?? Platform.environment),
        msisdn: market.msisdn,
      ),
      secondFactor: SecondFactorSignIn(
        factors: MemorySecondFactors(now: clock.now),
        mac: const HmacSha256Authenticator(),
        signingKey: _developmentCodeKey,
        clock: clock,
      ),
      reserveBooking: ReserveBooking(bookings: memoryBookings, market: market),
      bookings: memoryBookings,
      console: const UnavailableOperatorConsole(),
      disruptions: const UnavailableDisruptionDesk(),
      payouts: const UnavailablePayouts(),
      protection: const UnavailableProtection(),
      choices: const NoChoices(),
      sharing: const NoTripSharing(),
      cancellations: const NoSelfCancellation(),
      platform: const UnavailablePlatformConsole(),
      storefronts: MemoryStorefronts.demo(),
      applications: MemoryOperatorApplications(clock: clock),
      storage: MemoryObjectStore(),
      payments: memoryPayments,
      payForBooking: PayForBooking(
        market: market,
        payments: memoryPayments,
        bookings: memoryBookings,
        // The demo operator on the seed rate. A real one has negotiated.
        operators: MemoryOperatorDirectory(
          commissions: const {'op-demo': CommissionTerm.seed},
        ),
        // One fake rail, so a fresh clone can walk the whole payment funnel
        // with no credentials and no network — including the failure screens,
        // which is what `FakePaymentGateway.decliningMsisdn` is for.
        //
        // Scripted to settle on the second poll rather than left silent. A
        // fake that never captures means a fresh clone can never reach a
        // confirmed booking, a ticket or a QR — and the states nobody sees in
        // development are exactly the ones that ship broken. One poll of
        // waiting first, so the waiting screen is actually seen.
        gateways: {
          'cg.fake_money': FakePaymentGateway(clock: clock)..settlesAfter(1),
        },
      ),
      railIds: const {'cg.fake_money'},
      market: market,
      // A demo traveller, so a fresh clone can hold a seat without standing up
      // Firebase first — and a fake, so this token cannot reach a real
      // database even by accident.
      authGateway: FakeAuthGateway.demo(),
      directory: directory,
      catalogue: catalogue,
      cities: const MemoryCityCatalogue(),
      inventory: inventory,
      idempotency: Idempotency(MemoryIdempotencyStore()),
      clock: clock,
      usingDatabase: false,
      // The logging sender will happily "send" an SMS to the console, and a
      // fresh clone should be able to exercise both channels.
      smsConfigured: true,
    );
  }

  /// Idempotency scoped to one traveller, so two travellers cannot see or
  /// clobber each other's keys.
  Idempotency idempotencyFor(String? userId) {
    final db = _database;
    if (db == null) return idempotency;
    return Idempotency(
      PostgresIdempotencyStore(
        db,
        scope: userId == null || userId.isEmpty
            ? const DbScope.anonymous()
            : DbScope.traveller(userId),
      ),
    );
  }

  Future<void> close() async => _database?.close();

  // ── Identity wiring ───────────────────────────────────────────────────────

  /// ACS when it is configured, the log when it is not (ADR-0019).
  ///
  /// **Blank is a supported state.** A new engineer clones the repo and
  /// everything runs, writing messages to the log instead of a real handset,
  /// so nobody's phone receives an SMS from someone else's laptop and no test
  /// run costs money.
  static NotificationGateway _notifications(Map<String, String> env) =>
      AcsNotificationGateway.tryParse(
        env['COMMS__CONNECTIONSTRING'],
        emailFrom: env['COMMS__EMAILFROM'],
        smsFrom: env['COMMS__SMSFROM'],
      ) ??
      const LoggingNotificationGateway();

  /// Keys the HMAC that stands in for a stored code.
  ///
  /// Absent, it is **generated fresh at startup** rather than defaulting to a
  /// constant. Both are wrong in production, but they fail differently: a
  /// constant means a leaked repository can forge codes forever, while a
  /// random one means codes issued before a restart stop verifying and a
  /// second instance disagrees with the first. The second is loud, immediate
  /// and impossible to ignore — which is the failure worth having.
  static List<int> _codeKey(Map<String, String> env) {
    final configured = env['AUTH_CODE_KEY'];
    if (configured != null && configured.length >= 32) {
      return utf8.encode(configured);
    }

    stderr.writeln(
      'AUTH_CODE_KEY is unset or shorter than 32 characters. Using a '
      'per-process key: sign-in codes will not survive a restart and will '
      'not verify across instances.',
    );
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256));
  }

  /// Fixed, and only ever reached by the fakes composition — the one that runs
  /// when there is no database to sign anybody in to.
  static final List<int> _developmentCodeKey = utf8.encode(
    'billetenligne-development-only-code-key',
  );

  /// Renders the message body from the shared catalog, in the language the
  /// request asked for.
  ///
  /// The **server** is the only place prose is produced (ADR-0008 / ADR-0019
  /// rule 3), which is why this lives here and not in the adapter: an adapter
  /// that reached for a template would have to know a language, and there
  /// would then be two places words can come from.
  static ({String? subject, String body}) _renderSignInMessage({
    required SignInChannel channel,
    required String language,
    required String code,
    required int minutes,
  }) {
    final t = CatalogTranslator(_catalog, language);
    final params = <String, Object?>{'code': code, 'minutes': minutes};

    return switch (channel) {
      SignInChannel.email => (
        subject: t('email.otp.subject', params),
        body: t('email.otp.body', params),
      ),
      SignInChannel.phone => (subject: null, body: t('sms.otp.body', params)),
    };
  }

  /// The rails this deployment can actually collect on.
  ///
  /// Credentials-driven, not a compiled-in list: a rail with no credentials is
  /// absent rather than present-and-broken, which is what makes enabling
  /// Orange Money a config push rather than a release (ADR-0006). The map is
  /// also what the payment options endpoint intersects with the operator's
  /// verified accounts, so a rail we cannot reach is never offered.
  ///
  /// Two halves of the same switch, deliberately kept apart: `markets.yaml`
  /// says a rail is *offered*, credentials say it can be *collected on*, and a
  /// rail needs both. Announcing one we hold no keys for would put a tile on
  /// the payment screen that fails on tap.
  static Map<String, PaymentGateway> _railsFrom(
    Map<String, String> env,
    Market market,
  ) {
    final rails = <String, PaymentGateway>{};

    final mtnKey = env['MTN__SUBSCRIPTIONKEY'] ?? '';
    if (mtnKey.isNotEmpty) {
      rails['cg.mtn_momo'] = MtnMomoGateway(
        baseUrl: Uri.parse(
          env['MTN__BASEURL'] ?? 'https://sandbox.momodeveloper.mtn.com',
        ),
        subscriptionKey: mtnKey,
        apiUser: env['MTN__APIUSER'] ?? '',
        apiKey: env['MTN__APIKEY'] ?? '',
        targetEnvironment: env['MTN__TARGETENVIRONMENT'] ?? 'sandbox',
        callbackUrl: '${env['PUBLIC_BASE_URL'] ?? ''}/hooks/payments/mtn',
      );
    }

    final airtelId = env['AIRTEL__CLIENTID'] ?? '';
    if (airtelId.isNotEmpty) {
      rails['cg.airtel_money'] = AirtelMoneyGateway(
        baseUrl: Uri.parse(
          env['AIRTEL__BASEURL'] ?? 'https://openapiuat.airtel.africa',
        ),
        clientId: airtelId,
        clientSecret: env['AIRTEL__CLIENTSECRET'] ?? '',
        country: market.code,
        currency: market.currency.code,
      );
    }

    // No credentials at all is a real state — every developer, and every CI
    // run. The fake rail keeps the funnel walkable rather than leaving a
    // payment screen with nothing on it.
    if (rails.isEmpty) rails['cg.fake_money'] = FakePaymentGateway();

    return rails;
  }

  /// Signs every ticket this process issues.
  ///
  /// A fixed development seed, so a ticket signed by yesterday's run still
  /// verifies today (ADR-0020) — production keys are generated in and never
  /// leave the KMS, and swapping this line is the whole change. Lazily
  /// resolved because key generation is async and composition is not.
  static final TicketIssuer _ticketIssuer = _LazyTicketIssuer();

  /// The shared catalog, for the one thing that renders prose server-side and
  /// is not a message: the payout statement PDF.
  ///
  /// A document is not a screen — an operator's accountant files it, a bank
  /// asks for it, and there is no client to hand a key to — so the sentences
  /// on it are rendered here, from the same catalog the SMS templates use
  /// (ADR-0008 / ADR-0019 rule 3).
  static TranslationCatalog get translations => _catalog;

  /// Loaded once, from disk.
  ///
  /// `BEL_I18N_DIR` because the working directory differs between `dart_frog
  /// dev`, `dart test` and a built binary, and a catalog that resolves in one
  /// of those and not the others is a feature that works until it is deployed.
  static final TranslationCatalog _catalog = CatalogLoader.fromDirectory(
    Platform.environment['BEL_I18N_DIR'] ?? _findI18nDirectory(),
  );

  /// The markets this deployment serves, read once from `config/markets.yaml`.
  ///
  /// Cached in a static because composition runs per process, not per request
  /// — and because a rail list that could change between pricing a booking
  /// and charging for it would be worse than one compiled in.
  static MarketCatalog? _markets;

  /// Reads and validates `config/markets.yaml`, once per process.
  ///
  /// Public because `main.dart` calls it before the socket opens: a malformed
  /// file must stop the deploy rather than let an instance come up healthy
  /// and serve the rails of the release before it.
  static MarketCatalog marketCatalog([Map<String, String>? environment]) =>
      _markets ??= MarketCatalog.load(
        environment: environment ?? Platform.environment,
      );

  /// Walks up from the current directory looking for the catalog. Ugly, and
  /// the alternative is every entry point knowing how deep it is in the tree.
  static String _findI18nDirectory() {
    var dir = Directory.current;
    for (var up = 0; up < 5; up++) {
      final candidate = Directory('${dir.path}/packages/bel_localization/i18n');
      if (candidate.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    throw StateError(
      'translation catalog not found. Set BEL_I18N_DIR to the i18n directory.',
    );
  }
}

/// Defers key generation until the first ticket is issued.
///
/// `Ed25519TicketSigner.fromSeed` is async and `Services.resolve` is not —
/// and making composition async would push a `Future` into every route's
/// context read. The signer is created once and reused; concurrent first
/// issues share one future rather than generating two keys.
final class _LazyTicketIssuer implements TicketIssuer {
  Future<Ed25519TicketIssuer>? _resolved;

  @override
  Future<List<SignedTicket>> issue({
    required BookingRef bookingRef,
    required String departureId,
    required DateTime departsAt,
    required String routeCode,
    required String operatorCode,
    required List<({String seatLabel, String passengerName})> seats,
  }) async {
    final issuer = await (_resolved ??= Ed25519TicketIssuer.development());
    return issuer.issue(
      bookingRef: bookingRef,
      departureId: departureId,
      departsAt: departsAt,
      routeCode: routeCode,
      operatorCode: operatorCode,
      seats: seats,
    );
  }
}
