import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import 'src/application/boarding_session.dart';
import 'src/application/simulated_scan.dart';
import 'src/infrastructure/demo_data.dart';
import 'src/infrastructure/memory_redemption_log.dart';
import 'src/presentation/pages/boarding_page.dart';

/// BilletEnLigne boarding scanner.
///
/// A standalone, operator-owned app (ADR-0022). It exists to answer one
/// question in under two seconds, with the radio switched off: does this
/// person board?
void main() => runApp(const ScannerApp());

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BilletEnLigne — Embarquement',
    debugShowCheckedModeBanner: false,
    // `plein soleil` is the DEFAULT here, not an option. A conductor
    // validating sixty tickets in direct equatorial sun is our least
    // forgiving user, and the one whose failure is most visible.
    theme: KiloTheme.materialTheme(brightness: KiloBrightness.pleinSoleil),
    home: const _Bootstrap(),
  );
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  BoardingSession? _session;
  List<SimulatedScan> _simulatedScans = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _pinManifest();
  }

  /// Pins a departure's manifest, then never needs the network again.
  ///
  /// Against the API this is one small GET. Here it builds a real signed
  /// departure locally, so the app can be run and demonstrated with no server
  /// at all — through the same verification path production uses.
  Future<void> _pinManifest() async {
    try {
      final demo = await DemoDeparture.build();
      final log = MemoryRedemptionLog();

      if (!mounted) return;
      setState(() {
        _simulatedScans = demo.simulatedScans();
        _session = BoardingSession(
          manifest: demo.manifest,
          verifier: TicketVerifier(
            signatures: demo.verifier,
            mac: const HmacSha256Authenticator(),
            log: log,
          ),
          log: log,
          deviceId: 'demo-device',
          clock: const SystemClock(),
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    if (_error != null) {
      return Scaffold(
        backgroundColor: kilo.color.surfaceBase,
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(kilo.space.s6),
            child: Text(
              'Impossible de charger la liste des passagers.\n'
              'Reconnectez-vous et réessayez.',
              textAlign: TextAlign.center,
              style: kilo.text.bodyLg,
            ),
          ),
        ),
      );
    }

    final session = _session;
    if (session == null) {
      return Scaffold(
        backgroundColor: kilo.color.surfaceBase,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return BoardingPage(session: session, simulatedScans: _simulatedScans);
  }
}
