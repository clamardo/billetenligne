import 'dart:async';

import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/boarding_session.dart';
import '../../application/boarding_sync.dart';
import '../../application/departure_close.dart';
import '../../application/road_progress.dart';
import '../../application/simulated_scan.dart';
import '../widgets/camera_view.dart';
import '../widgets/due_prompt.dart';
import '../widgets/road_sheet.dart';
import '../widgets/ticket_simulator.dart';
import '../widgets/verdict_screen.dart';
import '../l10n.dart';
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
    this.close,
    this.road,
    this.onLeave,
    super.key,
  });

  final BoardingSession session;

  /// The road this coach runs, so the conductor can say where it has got to
  /// (ADR-0014 §1, tier 2). Null on a run with no intermediate stops, and the
  /// control disappears rather than opening an empty sheet.
  final RoadProgress? road;

  /// Empties the outbox when the conductor asks. Null on a device with no
  /// server behind it, and the control disappears rather than failing.
  final BoardingSync? sync;

  /// Says the coach has left (J4). Null on a device with no server behind it,
  /// and the control disappears rather than failing — this is the one write
  /// here that cannot be queued, so an offline device must not offer it as
  /// though it could.
  final DepartureClose? close;

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
  var _closing = false;

  /// Re-asks the road whether a waypoint has fallen due (J5).
  ///
  /// A minute, because the answer changes on the timetable's scale and not on
  /// a frame's: the prompt is *"the schedule says Dolisie was twenty minutes
  /// ago"*, and a conductor who sees it sixty seconds later has lost nothing.
  Timer? _dueTick;

  /// The departure as this handset last heard it. Held here rather than read
  /// from the widget each build so a close taken at the roadside is reflected
  /// immediately, without re-pinning a manifest over a connection that was
  /// barely enough to send one request.
  DepartureClose? _close;

  @override
  void initState() {
    super.initState();
    _close = widget.close;
    if (widget.road != null) {
      _dueTick = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _dueTick?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(BoardingPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.close, widget.close)) _close = widget.close;
  }

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
    // Plural through the catalog, not through appending an `s`: the rule is a
    // property of the language, and the next language added will not have it.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          !report.ok
              ? context.t('scanner.boarding.sendFailed', {
                  'pending': report.stillPending,
                })
              : settled == 0
              ? context.t('scanner.boarding.nothingToSend')
              : context.tPlural('scanner.boarding.sent', settled),
        ),
      ),
    );
  }

  /// The coach has left, or has arrived.
  ///
  /// Confirmed first, and the sentence says what it costs: closing stops new
  /// sales at once, which takes seats away from anybody mid-checkout at a
  /// counter. It takes nothing from the forty people already on board, and
  /// the dialog says that too — it is the first thing a conductor asks.
  Future<void> _closeDeparture() async {
    final close = _close;
    final next = close?.next;
    if (close == null || next == null || _closing) return;

    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('scanner.close.${next.name}')),
        content: Text(dialogContext.t('scanner.close.${next.name}Body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.t('scanner.close.back')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t('scanner.close.${next.name}')),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _closing = true);
    try {
      final moved = await close();
      if (!mounted) return;
      setState(() {
        _close = moved;
        _closing = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('scanner.close.${next.name}Done'))),
      );
    } on Object {
      // No network, or the server refused — a coach somebody else already
      // closed, or one this handset is not rostered on. One sentence for all
      // of them: the conductor's next move is the same, which is to try again
      // where there is signal or to ring the office.
      if (!mounted) return;
      setState(() => _closing = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('scanner.close.failed'))),
      );
    }
  }

  /// The conductor answers the prompt: yes, we are past it.
  void _confirmDue(RoadPoint point) {
    final road = widget.road;
    if (road == null) return;
    setState(() => road.confirm(point.stopId));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          context.t('scanner.road.confirmed', {'place': point.name}),
        ),
      ),
    );
  }

  /// Not now. The road counts it, and asks about this place once more before
  /// leaving the conductor alone (§5.3).
  void _waveDue(RoadPoint point) {
    final road = widget.road;
    if (road == null) return;
    setState(() => road.wave(point.stopId));
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
            // Above the footer and below the camera: in the conductor's way
            // enough to be answered, never on top of the thing they are
            // holding the phone for.
            if (widget.road?.due case final point?)
              DuePrompt(
                point: point,
                onConfirm: () => _confirmDue(point),
                onWave: () => _waveDue(point),
              ),
            _BoardingFooter(
              session: widget.session,
              onManual: _openManual,
              road: widget.road?.hasRoad == true ? widget.road : null,
              onRoad: _openRoad,
              closeTo: _close?.next,
              closing: _closing,
              onClose: _closeDeparture,
            ),
          ],
        ),
      ),
    );
  }

  /// The road sheet. Modal rather than a second screen: the camera is the
  /// app, and a conductor who opens this is answering a question, not
  /// navigating.
  Future<void> _openRoad() async {
    final road = widget.road;
    if (road == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RoadSheet(road: road),
    );
    // The footer shows the last place confirmed, and the sheet is where it
    // changes.
    if (mounted) setState(() {});
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
                  tooltip: context.t('scanner.boarding.changeCoach'),
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
      label: Text(
        pending == 0 ? context.t('scanner.boarding.upToDate') : '$pending',
      ),
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
          context.t(
            stale
                ? 'scanner.boarding.staleOnline'
                : 'scanner.boarding.staleOffline',
            {'minutes': age.inMinutes},
          ),
          style: kilo.text.bodySm.copyWith(color: color),
        ),
      ],
    );
  }
}

class _BoardingFooter extends StatelessWidget {
  const _BoardingFooter({
    required this.session,
    required this.onManual,
    required this.onRoad,
    required this.onClose,
    this.road,
    this.closeTo,
    this.closing = false,
  });

  final BoardingSession session;
  final VoidCallback onManual;
  final VoidCallback onRoad;
  final RoadProgress? road;

  /// What the coach can still be told, or null when there is nothing left.
  final DepartureState? closeTo;
  final bool closing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final road = this.road;
    final last = road?.lastConfirmed;

    final outlined = OutlinedButton.styleFrom(
      foregroundColor: kilo.color.contentPrimary,
      side: BorderSide(color: kilo.color.borderStrong),
      shape: RoundedRectangleBorder(borderRadius: kilo.radius.controlBorder),
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(kilo.space.s4),
      color: kilo.color.surfaceRaised,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: kilo.space.touchTarget + 8,
            child: OutlinedButton.icon(
              onPressed: onManual,
              icon: const Icon(Icons.keyboard_alt_outlined),
              label: Text(context.t('scanner.boarding.manual')),
              style: outlined,
            ),
          ),
          // Second, and smaller. The door is what this app is for; the road is
          // something the same person does four hours later, and putting it
          // first would cost a tap sixty times a morning to save one twice.
          if (road != null) ...[
            SizedBox(height: kilo.space.s2),
            SizedBox(
              height: kilo.space.touchTarget,
              child: OutlinedButton.icon(
                onPressed: onRoad,
                icon: const Icon(Icons.place_outlined),
                label: Text(
                  last == null
                      ? context.t('scanner.road.title')
                      : context.t('scanner.road.report', {'place': last.name}),
                ),
                style: outlined,
              ),
            ),
          ],
          // Last, and smallest of the three. It is tapped once a run, at the
          // end of it, and every pixel it takes from the manual-entry button
          // is a pixel taken from the thing this app does sixty times a
          // morning.
          if (closeTo != null) ...[
            SizedBox(height: kilo.space.s2),
            SizedBox(
              height: kilo.space.touchTarget,
              child: OutlinedButton.icon(
                onPressed: closing ? null : onClose,
                icon: closing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.flag_outlined),
                label: Text(context.t('scanner.close.${closeTo!.name}')),
                style: outlined,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
