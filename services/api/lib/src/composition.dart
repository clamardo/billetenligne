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
import 'application/ports/operator_console.dart';
import 'application/ports/payment_gateway.dart';
import 'application/ports/payment_store.dart';
import 'application/ports/departure_catalogue.dart';
import 'application/ports/notification_gateway.dart';
import 'application/ports/seat_inventory.dart';
import 'application/ports/user_directory.dart';
import 'application/pay_for_booking.dart';
import 'application/reserve_booking.dart';
import 'application/search_departures.dart';
import 'application/sign_in.dart';
import 'infrastructure/db/database.dart';
import 'infrastructure/memory/memory_booking_store.dart';
import 'infrastructure/memory/memory_payment_store.dart';
import 'infrastructure/memory/memory_city_catalogue.dart';
import 'infrastructure/memory/memory_identity.dart';
import 'infrastructure/memory/memory_seat_inventory.dart';
import 'infrastructure/postgres/postgres_departure_catalogue.dart';
import 'infrastructure/postgres/postgres_booking_store.dart';
import 'infrastructure/postgres/postgres_identity.dart';
import 'infrastructure/postgres/postgres_operator_console.dart';
import 'infrastructure/postgres/postgres_payment_store.dart';
import 'infrastructure/postgres/postgres_idempotency_store.dart';
import 'infrastructure/postgres/postgres_seat_inventory.dart';
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
    required this.reserveBooking,
    required this.bookings,
    required this.console,
    required this.payments,
    required this.payForBooking,
    required this.railIds,
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
  final ReserveBooking reserveBooking;
  final BookingStore bookings;

  /// The operator surface. Backed by Postgres, or by an adapter that refuses
  /// with a message naming `DATABASE_URL` — the console configures the world
  /// the traveller browses, and a fake one would be a second definition of
  /// every coach and route, kept in sync by hand.
  final OperatorConsole console;

  final PaymentStore payments;
  final PayForBooking payForBooking;

  /// The rails this deployment can actually collect on. Intersected with the
  /// operator's verified accounts before anything is offered, so a rail we
  /// cannot reach is absent rather than present-and-broken.
  final Set<String> railIds;

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
    final url = env['DATABASE_URL'];

    if (url == null || url.isEmpty) return Services.inMemory(clock: clock);

    final db = Database.open(url);
    final inventory = PostgresSeatInventory(db);
    final catalogue = PostgresDepartureCatalogue(
      db,
      timeZone: Market.current.timeZone,
    );

    final directory = PostgresUserDirectory(db);

    // Tickets are signed with the KMS key in a real environment; the fixed
    // development seed keeps a ticket signed by yesterday's run verifiable
    // today (ADR-0020). Resolved once, at startup, because key material is
    // not something to fetch per request.
    final bookings = PostgresBookingStore(db, issuer: _ticketIssuer);
    final paymentStore = PostgresPaymentStore(db);
    final rails = _railsFrom(env);

    return Services._(
      holdSeats: HoldSeats(inventory: inventory),
      searchDepartures: SearchDepartures(catalogue: catalogue),
      signIn: SignIn(
        challenges: PostgresAuthChallenges(db),
        directory: directory,
        notifications: _notifications(env),
        render: _renderSignInMessage,
        mac: const HmacSha256Authenticator(),
        codeKey: _codeKey(env),
        clock: clock,
      ),
      reserveBooking: ReserveBooking(bookings: bookings),
      bookings: bookings,
      console: PostgresOperatorConsole(db, timeZone: Market.current.timeZone),
      payments: paymentStore,
      payForBooking: PayForBooking(
        payments: paymentStore,
        bookings: bookings,
        gateways: rails,
      ),
      railIds: rails.keys.toSet(),
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

  /// Fakes, with one coach already on sale so the API answers something useful
  /// on a fresh clone.
  factory Services.inMemory({
    Clock clock = const SystemClock(),
    List<MemoryDeparture>? departures,
    NotificationGateway? notifications,
  }) {
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
    final directory = MemoryUserDirectory(clock: clock);
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
      holdSeats: HoldSeats(inventory: inventory),
      searchDepartures: SearchDepartures(catalogue: catalogue),
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
      ),
      reserveBooking: ReserveBooking(bookings: memoryBookings),
      bookings: memoryBookings,
      console: const UnavailableOperatorConsole(),
      payments: memoryPayments,
      payForBooking: PayForBooking(
        payments: memoryPayments,
        bookings: memoryBookings,
        // One fake rail, so a fresh clone can walk the whole payment funnel
        // with no credentials and no network — including the failure screens,
        // which is what `FakePaymentGateway.decliningMsisdn` is for.
        gateways: {'cg.fake_money': FakePaymentGateway(clock: clock)},
      ),
      railIds: const {'cg.fake_money'},
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

  /// Loaded once, from disk.
  ///
  /// `BEL_I18N_DIR` because the working directory differs between `dart_frog
  /// dev`, `dart test` and a built binary, and a catalog that resolves in one
  /// of those and not the others is a feature that works until it is deployed.
  /// The rails this deployment can actually collect on.
  ///
  /// Credentials-driven, not a compiled-in list: a rail with no credentials is
  /// absent rather than present-and-broken, which is what makes enabling
  /// Orange Money a config push rather than a release (ADR-0006). The map is
  /// also what the payment options endpoint intersects with the operator's
  /// verified accounts, so a rail we cannot reach is never offered.
  static Map<String, PaymentGateway> _railsFrom(Map<String, String> env) {
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
        callbackUrl:
            '${env['PUBLIC_BASE_URL'] ?? ''}/hooks/payments/mtn',
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
        country: Market.current.code,
        currency: Market.current.currency.code,
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

  static final TranslationCatalog _catalog = CatalogLoader.fromDirectory(
    Platform.environment['BEL_I18N_DIR'] ?? _findI18nDirectory(),
  );

  /// Walks up from the current directory looking for the catalog. Ugly, and
  /// the alternative is every entry point knowing how deep it is in the tree.
  static String _findI18nDirectory() {
    var dir = Directory.current;
    for (var up = 0; up < 5; up++) {
      final candidate = Directory(
        '${dir.path}/packages/bel_localization/i18n',
      );
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
