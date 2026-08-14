import 'package:bel_design/bel_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/simulated_scan.dart';
import '../l10n.dart';

/// Feeds ticket payloads to the scanner without a camera.
///
/// The Android emulator renders a virtual room, not a QR you can aim at, so
/// the usual way to test boarding is to hold a second phone — fine at a desk,
/// useless in CI.
///
/// Each entry carries the *same string a camera would decode*, straight into
/// the same code path. Nothing about the verdict is faked: these are real
/// Ed25519-signed tickets with real rotating codes, and each one exercises a
/// verdict a conductor genuinely meets.
///
/// **Debug builds only.** Guarded by [kDebugMode] — a release build that could
/// inject a ticket would be a way to board for free.
///
/// Takes plain [SimulatedScan] values rather than the departure that produced
/// them: presentation never reaches into infrastructure, and the layer check
/// enforces it.
class TicketSimulator extends StatelessWidget {
  const TicketSimulator({required this.scans, required this.onScan, super.key});

  final List<SimulatedScan> scans;

  /// Delivers `(payload, presentedCode)` exactly as the camera pipeline does.
  final void Function(String raw, String? code) onScan;

  /// Never true in a release build.
  static bool get isAvailable => kDebugMode;

  @override
  Widget build(BuildContext context) {
    if (!isAvailable || scans.isEmpty) return const SizedBox.shrink();

    final kilo = context.kilo;

    return DraggableScrollableSheet(
      initialChildSize: 0.42,
      minChildSize: 0.12,
      maxChildSize: 0.85,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: kilo.color.surfaceRaised,
          borderRadius: BorderRadius.vertical(top: kilo.radius.xl),
          border: Border.all(color: kilo.color.borderStrong),
        ),
        child: ListView(
          controller: controller,
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: kilo.color.borderStrong,
                  borderRadius: kilo.radius.cardBorder,
                ),
              ),
            ),
            SizedBox(height: kilo.space.s3),
            Row(
              children: [
                Icon(
                  Icons.science_outlined,
                  size: 18,
                  color: kilo.color.warning,
                ),
                SizedBox(width: kilo.space.s2),
                Text(
                  context.t('scanner.simulator.title'),
                  style: kilo.text.label.copyWith(color: kilo.color.warning),
                ),
              ],
            ),
            SizedBox(height: kilo.space.s1),
            Text(
              context.t('scanner.simulator.body'),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s4),
            for (final scan in scans) ...[
              _ScanTile(
                scan: scan,
                onTap: () => onScan(scan.payload, scan.code),
              ),
              SizedBox(height: kilo.space.s2),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.scan, required this.onTap});

  final SimulatedScan scan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Material(
      color: kilo.color.surfaceBase,
      borderRadius: kilo.radius.cardBorder,
      child: InkWell(
        onTap: onTap,
        borderRadius: kilo.radius.cardBorder,
        child: Container(
          padding: EdgeInsets.all(kilo.space.s3),
          decoration: BoxDecoration(
            border: Border.all(color: kilo.color.borderSubtle),
            borderRadius: kilo.radius.cardBorder,
          ),
          child: Row(
            children: [
              Icon(_iconFor(scan.kind), color: _tintFor(scan.kind, kilo.color)),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(scan.title, style: kilo.text.h3),
                    Text(
                      scan.subtitle,
                      style: kilo.text.bodySm.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.play_arrow, color: kilo.color.contentMuted),
            ],
          ),
        ),
      ),
    );
  }

  /// Presentation decides how a semantic kind looks. Infrastructure never
  /// names an icon.
  static IconData _iconFor(SimulatedScanKind kind) => switch (kind) {
    SimulatedScanKind.genuine => Icons.check_circle_outline,
    SimulatedScanKind.screenshot => Icons.screenshot_monitor,
    SimulatedScanKind.otherDeparture => Icons.swap_horiz,
    SimulatedScanKind.refunded => Icons.money_off,
    SimulatedScanKind.forged => Icons.gpp_bad_outlined,
    SimulatedScanKind.foreign => Icons.qr_code_2,
  };

  static Color _tintFor(SimulatedScanKind kind, KiloColors c) => switch (kind) {
    SimulatedScanKind.genuine => c.success,
    SimulatedScanKind.screenshot ||
    SimulatedScanKind.otherDeparture => c.warning,
    SimulatedScanKind.refunded ||
    SimulatedScanKind.forged ||
    SimulatedScanKind.foreign => c.danger,
  };
}
