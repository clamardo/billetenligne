import 'dart:async';

import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/boarding_session.dart';
import '../../application/boarding_sync.dart';
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
    this.sync,
    this.onLeave,
    super.key,
  });

  final BoardingSession session;

  /// Empties the outbox when the conductor asks. Null on a device with no
  /// server behind it, and the control disappears rather than failing.
  final BoardingSync? sync;

  /// Back to the list of today's coaches. Null when there is no list to go
  /// back to — a scanner that pinned the only departure it knows about.
  final VoidCallback? onLeave;

  /// Canned scans for the debug simulator. Empty in release, and empty here
  /// costs nothing — the sheet renders nothing.
  final List<SimulatedScan> simulatedScans;

  @override
  State<BoardingPage> createState() => _BoardingPageState();
}

class _BoardingPageState extends State<BoardingPage> {
  VerificationOutcome? _verdict;
  var _syncing = false;

  /// One entry point for both the camera and the simulator, so a simulated
  /// scan cannot take a different code path from a real one — the moment it
  /// does, the simulator stops proving anything.
  ///
  /// The await is the async half of the signature check on this one payload,
  /// and it is the only await between a camera frame and a verdict. Without
  /// it the device has never seen this signature and every genuine ticket in
  /// the field would read as forged.
  Future<void> _handleScan(String raw, {String? code}) async {
    await widget.session.warm(raw);
    if (!mounted) return;
    final outcome = widget.session.scan(raw, presentedCode: code);
    setState(() => _verdict = outcome);
  }

  /// Sends what the door recorded while the radio was off.
  ///
  /// Never automatic on a scan. The queue is emptied when somebody asks,
  /// which on this network is when the coach is somewhere with signal.
  Future<void> _drain() async {
    final sync = widget.sync;
    if (sync == null || _syncing) return;

    setState(() => _syncing = true);
    final report = await sync.drain();
    if (!mounted) return;
    setState(() => _syncing = false);

    final settled = report.settled;
    final plural = settled > 1 ? 's' : '';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          !report.ok
              ? "Envoi impossible. ${report.stillPending} en attente — "
                    'le car peut partir, ils repartiront plus tard.'
              : settled == 0
              ? 'Rien à envoyer.'
              : '$settled embarquement$plural envoyé$plural.',
        ),
      ),
    );
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
            _DepartureHeader(
              session: widget.session,
              pending: widget.sync?.pendingCount ?? 0,
              syncing: _syncing,
              onSync: widget.sync == null ? null : _drain,
              onLeave: widget.onLeave,
            ),
            Expanded(
              child: Stack(
                children: [
                  CameraView(onDetect: (raw) => unawaited(_handleScan(raw))),
                  if (TicketSimulator.isAvailable)
                    TicketSimulator(
                      scans: widget.simulatedScans,
                      onScan: (raw, code) =>
                          unawaited(_handleScan(raw, code: code)),
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
  const _DepartureHeader({
    required this.session,
    required this.pending,
    required this.syncing,
    this.onSync,
    this.onLeave,
  });

  final BoardingSession session;
  final int pending;
  final bool syncing;
  final Future<void> Function()? onSync;
  final VoidCallback? onLeave;

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
              if (onLeave != null)
                IconButton(
                  onPressed: onLeave,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Changer de car',
                  visualDensity: VisualDensity.compact,
                ),
              Text(_hhmm(m.departsAt), style: kilo.text.h2),
              SizedBox(width: kilo.space.s2),
              Expanded(
                child: Text(
                  (m.routeCode ?? '').replaceAll('>', ' → '),
                  style: kilo.text.h3.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ),
              if (onSync != null)
                _SyncButton(
                  pending: pending,
                  syncing: syncing,
                  onSync: onSync!,
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

/// What is still on the device, and the way to send it.
///
/// A count rather than a spinner that runs by itself: the conductor decides
/// when this happens, because they are the one who knows whether there is
/// signal and whether the door is still busy.
class _SyncButton extends StatelessWidget {
  const _SyncButton({
    required this.pending,
    required this.syncing,
    required this.onSync,
  });

  final int pending;
  final bool syncing;
  final Future<void> Function() onSync;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return TextButton.icon(
      onPressed: syncing ? null : onSync,
      icon: syncing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              pending == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload,
              size: 20,
            ),
      label: Text(pending == 0 ? 'À jour' : '$pending'),
      style: TextButton.styleFrom(
        foregroundColor: pending == 0
            ? kilo.color.contentMuted
            : kilo.color.brandPrimary,
        visualDensity: VisualDensity.compact,
      ),
    );
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
