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
import 'src/application/simulated_scan.dart';
import 'src/infrastructure/api_boarding_gateway.dart';
import 'src/infrastructure/demo_boarding_gateway.dart';
import 'src/infrastructure/memory_redemption_log.dart';
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
  const apiUrl = String.fromEnvironment('BEL_API_URL');

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

/// Which Firebase, and how to reach it. The API key is not a secret — it
/// identifies a project rather than authorising anything.
FirebaseClientConfig _firebaseConfig() {
  const emulator = String.fromEnvironment('BEL_FIREBASE_EMULATOR');
  const projectId = String.fromEnvironment(
    'BEL_FIREBASE_PROJECT',
    defaultValue: 'demo-billetenligne',
  );

  if (emulator.isNotEmpty) {
    return FirebaseClientConfig.emulator(projectId: projectId, host: emulator);
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

  @override
  Widget build(BuildContext context) => Localized(
    catalog: catalog,
    child: MaterialApp(
      title: 'BilletEnLigne — Embarquement',
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
        title: 'Embarquement',
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
  String? _failure;
  String? _pinning;

  BoardingSession? _session;
  BoardingSync? _sync;
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
          _failure = _sentence(e);
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
    for (final departureId in store.departuresAwaitingSync()) {
      final report = await BoardingSync(
        gateway: widget.gateway,
        outbox: store.forDeparture(departureId),
        departureId: departureId,
      ).drain();
      settled += report.settled;
    }

    if (settled == 0 || !mounted) return;
    final plural = settled > 1 ? 's' : '';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('$settled embarquement$plural en attente envoyé$plural.'),
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
      final store = widget.log;
      if (store == null) {
        final memory = MemoryRedemptionLog();
        outbox = memory;
        log = memory;
      } else {
        final persisted = store.forDeparture(coach.id);
        outbox = persisted;
        log = persisted;
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
          departureId: coach.id,
        );
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _pinning = null;
          _failure = _sentence(e);
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
          title: Text('${sync.pendingCount} embarquements non envoyés'),
          content: const Text(
            'Ils restent sur le téléphone. Envoyez-les maintenant si vous '
            'avez du réseau.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Plus tard'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Envoyer'),
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
            const SnackBar(
              content: Text('Envoi impossible. Ils restent en attente.'),
            ),
          );
        }
      }
    }

    setState(() {
      _session = null;
      _sync = null;
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
      failure: _failure,
    );
  }

  /// A sentence a conductor can act on, rather than an exception's toString.
  static String _sentence(Object error) {
    if (error is ServerRefused) {
      return switch (error.status) {
        401 || 403 =>
          "Votre compte n'a pas le droit d'embarquer sur ce car. "
              'Demandez à votre exploitant.',
        503 => 'Le serveur est indisponible. Réessayez dans un instant.',
        _ => 'Le serveur a refusé la demande (${error.status}).',
      };
    }
    if (error is ApiFailure) {
      return 'Pas de réseau. Rapprochez-vous du bureau et réessayez.';
    }
    return 'Impossible de charger la liste des passagers.';
  }
}
