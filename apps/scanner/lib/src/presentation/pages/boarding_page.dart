import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/boarding_session.dart';
import '../../application/simulated_scan.dart';
import '../widgets/camera_view.dart';
import '../widgets/ticket_simulator.dart';
import '../widgets/verdict_screen.dart';
import 'manual_boarding_page.dart';

/// The scanner's only real screen.
///
/// Camera fills it; a verdict replaces it full-bleed. No navigation, no tabs,
/// no settings drawer — a conductor boarding sixty people in ten minutes has
/// no attention to spare for an information architecture.
class BoardingPage extends StatefulWidget {
  const BoardingPage({
    required this.session,
    this.simulatedScans = const [],
    super.key,
  });

  final BoardingSession session;

  /// Canned scans for the debug simulator. Empty in release, and empty here
  /// costs nothing — the sheet renders nothing.
  final List<SimulatedScan> simulatedScans;

  @override
  State<BoardingPage> createState() => _BoardingPageState();
}

class _BoardingPageState extends State<BoardingPage> {
  VerificationOutcome? _verdict;

  /// One entry point for both the camera and the simulator, so a simulated
  /// scan cannot take a different code path from a real one — the moment it
  /// does, the simulator stops proving anything.
  void _handleScan(String raw, {String? code}) {
    final outcome = widget.session.scan(raw, presentedCode: code);
    setState(() => _verdict = outcome);
  }

  void _dismiss() => setState(() => _verdict = null);

  void _override() {
    final stale = _verdict;
    if (stale == null) return;
    setState(() => _verdict = widget.session.overrideStaleCode(stale));
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final verdict = _verdict;

    if (verdict != null) {
      return Scaffold(
        body: VerdictScreen(
          outcome: verdict,
          onDismiss: _dismiss,
          onOverride: verdict.result == VerificationResult.staleCode
              ? _override
              : null,
        ),
      );
    }

    return Scaffold(
      backgroundColor: kilo.color.surfaceBase,
      body: SafeArea(
        child: Column(
          children: [
            _DepartureHeader(session: widget.session),
            Expanded(
              child: Stack(
                children: [
                  CameraView(onDetect: (raw) => _handleScan(raw)),
                  if (TicketSimulator.isAvailable)
                    TicketSimulator(
                      scans: widget.simulatedScans,
                      onScan: (raw, code) => _handleScan(raw, code: code),
                    ),
                ],
              ),
            ),
            _BoardingFooter(session: widget.session, onManual: _openManual),
          ],
        ),
      ),
    );
  }

  Future<void> _openManual() async {
    final outcome = await Navigator.of(context).push<VerificationOutcome>(
      MaterialPageRoute(
        builder: (_) => ManualBoardingPage(session: widget.session),
      ),
    );
    if (outcome != null && mounted) setState(() => _verdict = outcome);
  }
}

class _DepartureHeader extends StatelessWidget {
  const _DepartureHeader({required this.session});

  final BoardingSession session;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final m = session.manifest;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: kilo.space.s4,
        vertical: kilo.space.s3,
      ),
      color: kilo.color.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_hhmm(m.departsAt), style: kilo.text.h2),
              SizedBox(width: kilo.space.s2),
              Expanded(
                child: Text(
                  'BZV → PNR',
                  style: kilo.text.h3.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ),
              // Always visible, because "how many are on" is the number the
              // conductor is tracking the whole time.
              Text(
                session.progress,
                style: kilo.text.amountHero.copyWith(fontSize: 22),
              ),
            ],
          ),
          SizedBox(height: kilo.space.s1),
          _StalenessChip(manifest: m),
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

/// How old the pinned manifest is.
///
/// Shown so a conductor can decide to re-sync *before* departure, rather than
/// discovering at the door that someone who bought a seat ten minutes ago is
/// not on their list.
class _StalenessChip extends StatelessWidget {
  const _StalenessChip({required this.manifest});

  final BoardingManifest manifest;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final age = manifest.ageAt(DateTime.now().toUtc());
    if (age == null) return const SizedBox.shrink();

    final stale = age > const Duration(minutes: 30);
    final color = stale ? kilo.color.warning : kilo.color.contentMuted;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          stale ? Icons.sync_problem : Icons.offline_bolt_outlined,
          size: 14,
          color: color,
        ),
        SizedBox(width: kilo.space.s1),
        Text(
          stale
              ? 'Liste synchronisée il y a ${age.inMinutes} min — actualisez'
              : 'Hors ligne · liste à jour il y a ${age.inMinutes} min',
          style: kilo.text.bodySm.copyWith(color: color),
        ),
      ],
    );
  }
}

class _BoardingFooter extends StatelessWidget {
  const _BoardingFooter({required this.session, required this.onManual});

  final BoardingSession session;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(kilo.space.s4),
      color: kilo.color.surfaceRaised,
      child: SizedBox(
        height: kilo.space.touchTarget + 8,
        child: OutlinedButton.icon(
          onPressed: onManual,
          icon: const Icon(Icons.keyboard_alt_outlined),
          label: const Text('Embarquement manuel'),
          style: OutlinedButton.styleFrom(
            foregroundColor: kilo.color.contentPrimary,
            side: BorderSide(color: kilo.color.borderStrong),
            shape: RoundedRectangleBorder(
              borderRadius: kilo.radius.controlBorder,
            ),
          ),
        ),
      ),
    );
  }
}
