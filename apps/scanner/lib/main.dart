import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:bel_backoffice/bel_backoffice.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_secure_store/bel_secure_store.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import 'src/application/boarding_session.dart';
import 'src/application/boarding_sync.dart';
import 'src/application/ports/boarding_gateway.dart';
import 'src/application/road_progress.dart';
import 'src/application/simulated_scan.dart';
import 'src/infrastructure/api_boarding_gateway.dart';
import 'src/infrastructure/demo_boarding_gateway.dart';
import 'src/infrastructure/memory_redemption_log.dart';
import 'src/infrastructure/language_preference.dart';
import 'src/infrastructure/sqlite_redemption_log.dart';
import 'src/presentation/l10n.dart';
import 'src/presentation/pages/boarding_page.dart';
import 'src/presentation/pages/coach_picker_page.dart';

/// BilletEnLigne boarding scanner — composition root.
///
/// A standalone, operator-owned app (ADR-0022). It exists to answer one
/// question in under two seconds, with the radio switched off: does this
/// person board?
///
///   flutter run --dart-define=BEL_API_URL=http://10.0.2.2:8080
///
/// With no URL it runs against a signed demo departure: the picker, the pin,
/// the door and the outbox all work on a fresh clone with no server, through
/// the same widgets and the same Ed25519 path a conductor uses. What it
/// cannot demonstrate is a refusal by the server, which is the honest limit
/// of a demo that has none.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final catalog = await CatalogAssets.load();

  // A stored choice beats the handset. A conductor's phone is issued by the
  // agency and set up once by whoever unboxed it, which is rarely the person
  // holding it at half past five.
  final language =
      await loadLanguage() ??
      catalog.bestMatch(
        PlatformDispatcher.instance.locales.map((l) => l.toLanguageTag()),
      );

  final apiUrl = _reachable(const String.fromEnvironment('BEL_API_URL'));

  // Where the boarding log lives between launches. A failure to open it is
  // not a failure to start — the door still works, and the queue behaves as
  // it did before this existed — but it is the difference between a killed
  // app losing forty boardings and picking them up again, so it is tried
  // first and the fallback is named rather than silent.
  SqliteRedemptionStore? log;
  try {
    log = await SqliteRedemptionStore.open();
  } on Object catch (e) {
    debugPrint('boarding log unavailable, falling back to memory: $e');
  }

  if (apiUrl.isEmpty) {
    runApp(
      ScannerApp(
        catalog: catalog,
        language: language,
        onLanguage: saveLanguage,
        gateway: DemoBoardingGateway(),
        deviceId: 'demo-device',
        log: log,
      ),
    );
    return;
  }

  final session = BelSession(
    firebase: FirebaseIdentityClient(config: _firebaseConfig()),
    // The Keychain and the Android Keystore, shared with the traveller app
    // (ADR-0013). It matters more here than anywhere: a conductor signs in in
    // a yard at half past five, and a session that ended when the app was
    // killed is a sign-in at the coach door with a queue behind it.
    store: const SecureSessionStore(),
  );

  final client = BelApiClient(
    baseUrl: Uri.parse(apiUrl),
    token: session.token,
    language: 'fr',
  );

  runApp(
    ScannerApp(
      catalog: catalog,
      language: language,
      // Three places: the tree has already repainted, the preference store
      // survives a relaunch, and the account row is what the server writes
      // this conductor's own messages in tomorrow (ADR-0019 rule 3).
      // Best-effort on the last, like `touch` — a conductor in a yard with no
      // signal still gets the app in the language they asked for.
      onLanguage: (code) async {
        await saveLanguage(code);
        try {
          await client.setLanguage(code);
        } on Object {
          // Nothing to tell them. The screen already changed.
        }
      },
      gateway: ApiBoardingGateway(client, clock: const SystemClock()),
      deviceId: _deviceId(),
      log: log,
      session: session,
      client: client,
    ),
  );
}

/// Which handset boarded them.
///
/// Recorded on every redemption so an operator can tell two doors apart, and
/// so a device scanning what it should not be scanning is identifiable. Set
/// `BEL_DEVICE_ID` when provisioning a handset; otherwise it is unique per
/// launch, which is enough to separate two devices boarding one coach and not
/// enough to recognise the same one tomorrow. Persisting it needs the same
/// secure storage the session is waiting on.
String _deviceId() {
  const configured = String.fromEnvironment('BEL_DEVICE_ID');
  if (configured.isNotEmpty) return configured;
  return 'scanner-'
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

/// `localhost`, as seen from wherever this app is actually running.
///
/// On the Android emulator `localhost` is the *emulator*, and the machine that
/// started it is `10.0.2.2`. Nothing listens on the emulator's own loopback,
/// so a request there does not fail — it hangs until the socket times out,
/// which presents as a spinner that never stops.
///
/// Rewriting it here rather than in the launch configuration means there is
/// one way to point this app at a local server and it is right everywhere. A
/// real handset is untouched: it needs the machine's address on the network,
/// which is neither of these names. A deployed build never sees this, because
/// `BEL_API_URL` is then a public hostname.
String _reachable(String value) {
  if (!Platform.isAndroid || value.isEmpty) return value;
  return value
      .replaceAll('localhost', '10.0.2.2')
      .replaceAll('127.0.0.1', '10.0.2.2');
}

/// Which Firebase, and how to reach it. The API key is not a secret — it
/// identifies a project rather than authorising anything.
FirebaseClientConfig _firebaseConfig() {
  const emulator = String.fromEnvironment('BEL_FIREBASE_EMULATOR');
  const projectId = String.fromEnvironment(
    'BEL_FIREBASE_PROJECT',
    defaultValue: 'demo-billetenligne',
  );

  if (emulator.isNotEmpty) {
    return FirebaseClientConfig.emulator(
      projectId: projectId,
      host: _reachable(emulator),
    );
  }
  return const FirebaseClientConfig(
    apiKey: String.fromEnvironment('BEL_FIREBASE_API_KEY'),
    projectId: projectId,
  );
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({
    required this.catalog,
    required this.gateway,
    required this.deviceId,
    this.log,
    this.session,
    this.client,
    this.language = 'fr',
    this.onLanguage,
    super.key,
  });

  final TranslationCatalog catalog;
  final BoardingGateway gateway;
  final String deviceId;

  /// Null when the handset could not open one, and in a widget test. The
  /// coach is then boarded through an in-memory log, exactly as before —
  /// working, and unable to survive being killed.
  final SqliteRedemptionStore? log;

  /// Null in demo mode, where there is nobody to sign in and nothing to sign
  /// in to. Present otherwise, and then the way in is `bel_backoffice`'s
  /// shared screen — the same one the console and the admin app use, second
  /// factor included. A conductor is operator staff (ADR-0013), so they hold
  /// an authenticator like everybody else who can move other people's money.
  final BelSession? session;
  final BelApiClient? client;

  /// The language this handset opens in — its own locale, resolved against
  /// the catalog, unless somebody has chosen otherwise.
  final String language;

  /// Persists a choice. Null in tests, where a switch holds for the run.
  final void Function(String code)? onLanguage;

  @override
  Widget build(BuildContext context) => Localized(
    catalog: catalog,
    initialLanguage: language,
    onChanged: onLanguage,
    child: MaterialApp(
      // `onGenerateTitle` rather than `title`, because this string is read
      // in the handset's task switcher and `title` takes a `String` with no
      // context to translate it from. The builder runs below `Localized`,
      // which is above this `MaterialApp`.
      onGenerateTitle: (context) =>
          'BilletEnLigne — ${context.t('scanner.title')}',
      debugShowCheckedModeBanner: false,
      // `plein soleil` is the DEFAULT here, not an option. A conductor
      // validating sixty tickets in direct equatorial sun is our least
      // forgiving user, and the one whose failure is most visible.
      theme: KiloTheme.materialTheme(brightness: KiloBrightness.pleinSoleil),
      home: _Root(
        gateway: gateway,
        deviceId: deviceId,
        log: log,
        session: session,
        client: client,
      ),
    ),
  );
}

class _Root extends StatefulWidget {
  const _Root({
    required this.gateway,
    required this.deviceId,
    this.log,
    this.session,
    this.client,
  });

  final BoardingGateway gateway;
  final String deviceId;
  final SqliteRedemptionStore? log;
  final BelSession? session;
  final BelApiClient? client;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  late bool _signedIn = widget.session == null;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final client = widget.client;

    if (!_signedIn && session != null && client != null) {
      return BackOfficeSignIn(
        client: client,
        session: session,
        title: context.t('scanner.title'),
        icon: Icons.qr_code_scanner,
        t: context.t,
        onSignedIn: () => setState(() => _signedIn = true),
      );
    }

    return _CoachFlow(
      gateway: widget.gateway,
      deviceId: widget.deviceId,
      log: widget.log,
    );
  }
}

/// Pick a coach, pin it, board, empty the outbox.
///
/// One state machine rather than a Navigator stack: there are three screens
/// and a conductor must never be able to swipe back from the door into a list
/// while somebody is standing in front of them.
class _CoachFlow extends StatefulWidget {
  const _CoachFlow({required this.gateway, required this.deviceId, this.log});

  final BoardingGateway gateway;
  final String deviceId;
  final SqliteRedemptionStore? log;

  @override
  State<_CoachFlow> createState() => _CoachFlowState();
}

class _CoachFlowState extends State<_CoachFlow> {
  List<BoardingDepartureDto>? _coaches;

  /// The error itself, not a sentence about it.
  ///
  /// Rendered in `build` rather than at the moment it was caught, so a
  /// conductor who switches language while a refusal is on screen reads the
  /// refusal in the language they just chose — a stored sentence would sit
  /// there in the old one until they did something else.
  Object? _failure;
  String? _pinning;

  BoardingSession? _session;
  BoardingSync? _sync;
  RoadProgress? _road;
  List<SimulatedScan> _simulatedScans = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failure = null);
    try {
      final coaches = await widget.gateway.coachesOn(DateTime.now());
      if (!mounted) return;
      setState(() => _coaches = coaches);
      // This request just proved there is signal, which is the only thing a
      // stranded outbox was waiting for.
      await _drainLeftovers();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _coaches ??= const [];
          _failure = e;
        });
      }
    }
  }

  /// Sends what an earlier boarding left behind.
  ///
  /// A conductor who finished a run and closed the app never taps *send*
  /// again, so the rows would sit on the handset until somebody happened to
  /// re-open that departure. This runs the moment the day's list arrives,
  /// because arriving is proof of a network, and it names what went rather
  /// than doing it silently — an operator asking why a coach shows nobody on
  /// it deserves to have seen this.
  Future<void> _drainLeftovers() async {
    final store = widget.log;
    if (store == null) return;

    var settled = 0;
    // The union of the two queues: a coach can have unsent waypoints and no
    // unsent boardings — a conductor who confirmed Dolisie on a run that
    // boarded in the yard — and that tap would otherwise wait for somebody to
    // re-open that departure.
    for (final departureId in {
      ...store.departuresAwaitingSync(),
      ...store.departuresAwaitingCheckpoints(),
    }) {
      final report = await BoardingSync(
        gateway: widget.gateway,
        outbox: store.forDeparture(departureId),
        road: store.roadFor(departureId),
        departureId: departureId,
      ).drain();
      settled += report.settled;
    }

    if (settled == 0 || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(context.tPlural('scanner.boarding.sentPending', settled)),
      ),
    );
  }

  /// The last request before the door opens.
  Future<void> _pin(BoardingDepartureDto coach) async {
    setState(() {
      _pinning = coach.id;
      _failure = null;
    });

    try {
      final pinned = await widget.gateway.pin(coach.id);
      // Scoped to this coach: a conductor works two runs in a day, and the
      // same seat label boards on both.
      final RedemptionOutbox outbox;
      final RedemptionLog log;
      final CheckpointOutbox road;
      final store = widget.log;
      if (store == null) {
        final memory = MemoryRedemptionLog();
        outbox = memory;
        log = memory;
        road = MemoryCheckpointLog();
      } else {
        final persisted = store.forDeparture(coach.id);
        outbox = persisted;
        log = persisted;
        road = store.roadFor(coach.id);
      }

      if (!mounted) return;
      setState(() {
        _pinning = null;
        _simulatedScans = pinned.simulatedScans;
        _session = BoardingSession(
          manifest: pinned.manifest,
          verifier: TicketVerifier(
            signatures: pinned.signatures,
            mac: const HmacSha256Authenticator(),
            log: log,
          ),
          log: log,
          preparer: pinned.preparer,
          deviceId: widget.deviceId,
          clock: const SystemClock(),
          // A handset killed mid-boarding comes back knowing who is on.
          resumed: outbox.recorded(),
        );
        _sync = BoardingSync(
          gateway: widget.gateway,
          outbox: outbox,
          road: road,
          departureId: coach.id,
        );
        _road = RoadProgress(
          road: pinned.waypoints,
          outbox: road,
          clock: const SystemClock(),
          deviceId: widget.deviceId,
        );
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _pinning = null;
          _failure = e;
        });
      }
    }
  }

  /// Back to the list, but not over the top of an outbox.
  ///
  /// The queue survives now, so this is a nudge rather than a warning: the
  /// far end of the road is where there is signal, and a conductor who is
  /// there is the person who can act on it. Leaving anyway costs nothing —
  /// re-pinning the coach finds the same rows still waiting.
  Future<void> _leave() async {
    final sync = _sync;
    if (sync != null && sync.pendingCount > 0) {
      final send = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.tPlural('scanner.pending.title', sync.pendingCount),
          ),
          content: Text(context.t('scanner.pending.body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.t('scanner.pending.later')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t('scanner.pending.send')),
            ),
          ],
        ),
      );
      // Dismissed rather than answered — a stray tap outside the dialog. It
      // stays on the coach: leaving is what loses the queue.
      if (send == null || !mounted) return;
      if (send) {
        final report = await sync.drain();
        if (!mounted) return;
        if (!report.ok) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(context.t('scanner.boarding.sendFailedShort')),
            ),
          );
        }
      }
    }

    setState(() {
      _session = null;
      _sync = null;
      _road = null;
      _simulatedScans = const [];
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    final session = _session;
    if (session != null) {
      return BoardingPage(
        session: session,
        simulatedScans: _simulatedScans,
        sync: _sync,
        road: _road,
        onLeave: _leave,
      );
    }

    final coaches = _coaches;
    if (coaches == null) {
      return Scaffold(
        backgroundColor: kilo.color.surfaceBase,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return CoachPickerPage(
      coaches: coaches,
      onPick: _pin,
      onRefresh: _load,
      pinning: _pinning,
      failure: _failure == null
          ? null
          : _sentence(context.translator, _failure!),
    );
  }

  /// A sentence a conductor can act on, rather than an exception's toString.
  static String _sentence(CatalogTranslator t, Object error) {
    if (error is ServerRefused) {
      return switch (error.status) {
        401 || 403 => t('scanner.errors.forbidden'),
        503 => t('scanner.errors.unavailable'),
        _ => t('scanner.errors.refused', {'status': error.status}),
      };
    }
    if (error is ApiFailure) {
      return t('scanner.errors.offline');
    }
    return t('scanner.errors.manifest');
  }
}
