import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../infrastructure/demo_data.dart';

/// Feeds ticket payloads to the scanner without a camera.
///
/// The Android emulator's camera renders a virtual room, not a QR you can
/// point at, so the usual way to test boarding is to hold a second phone —
/// which is fine on a desk and useless in CI or on a plane.
///
/// This panel injects the *same strings a camera would decode* straight into
/// the verification path. Nothing about the verdict is faked: these are real
/// Ed25519-signed tickets with real rotating codes, and each entry exercises a
/// verdict a conductor genuinely meets.
///
/// **Debug builds only.** Guarded by [kDebugMode] and asserted in a test — a
/// release build that could inject a ticket would be a way to board free.
class TicketSimulator extends StatelessWidget {
  const TicketSimulator({required this.demo, required this.onScan, super.key});

  final DemoDeparture demo;

  /// Delivers `(payload, presentedCode)` exactly as the camera pipeline does.
  final void Function(String raw, String? code) onScan;

  /// Never true in a release build.
  static bool get isAvailable => kDebugMode;

  @override
  Widget build(BuildContext context) {
    if (!isAvailable) return const SizedBox.shrink();

    final kilo = context.kilo;
    final cases = _SimulatedScan.all(demo);

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
                  'SIMULATEUR — DEBUG',
                  style: kilo.text.label.copyWith(color: kilo.color.warning),
                ),
              ],
            ),
            SizedBox(height: kilo.space.s1),
            Text(
              'Injecte de vrais billets signés dans le lecteur, '
              'sans caméra. Absent des versions publiées.',
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s4),
            for (final c in cases) ...[
              _SimulatedScanTile(
                simulated: c,
                onTap: () => onScan(c.payload, c.code),
              ),
              SizedBox(height: kilo.space.s2),
            ],
          ],
        ),
      ),
    );
  }
}

class _SimulatedScanTile extends StatelessWidget {
  const _SimulatedScanTile({required this.simulated, required this.onTap});

  final _SimulatedScan simulated;
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
              Icon(simulated.icon, color: simulated.tint(kilo.color)),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(simulated.title, style: kilo.text.h3),
                    Text(
                      simulated.subtitle,
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
}

/// One thing a conductor might have presented to them.
final class _SimulatedScan {
  const _SimulatedScan({
    required this.title,
    required this.subtitle,
    required this.payload,
    required this.icon,
    this.code,
    this.tone = _Tone.neutral,
  });

  final String title;
  final String subtitle;
  final String payload;
  final String? code;
  final IconData icon;
  final _Tone tone;

  Color tint(KiloColors c) => switch (tone) {
    _Tone.good => c.success,
    _Tone.warn => c.warning,
    _Tone.bad => c.danger,
    _Tone.neutral => c.contentSecondary,
  };

  static const _mac = HmacSha256Authenticator();

  static List<_SimulatedScan> all(DemoDeparture demo) {
    final now = DateTime.now().toUtc();

    String ticket(String ref, String seat) =>
        demo.tickets[BoardingManifest.keyFor(ref, seat)]!;

    String code(String ref, String seat, DateTime at) => RotatingCode.current(
      secret: demo.secrets[BoardingManifest.keyFor(ref, seat)]!,
      now: at,
      mac: _mac,
    );

    return [
      _SimulatedScan(
        title: 'Billet valide',
        subtitle: 'Aline Mabiala · 14A · code à jour',
        payload: ticket('7QK4M2', '14A'),
        code: code('7QK4M2', '14A', now),
        icon: Icons.check_circle_outline,
        tone: _Tone.good,
      ),
      _SimulatedScan(
        title: 'Deuxième passager',
        subtitle: 'Pascal Nkouka · 14B · même réservation',
        payload: ticket('7QK4M2', '14B'),
        code: code('7QK4M2', '14B', now),
        icon: Icons.check_circle_outline,
        tone: _Tone.good,
      ),
      _SimulatedScan(
        title: 'Capture d\'écran',
        subtitle: 'Le QR est authentique, le code est figé',
        payload: ticket('ZZ1188', '2C'),
        // Frozen ten minutes ago: exactly what a screenshot looks like.
        code: code('ZZ1188', '2C', now.subtract(const Duration(minutes: 10))),
        icon: Icons.screenshot_monitor,
        tone: _Tone.warn,
      ),
      _SimulatedScan(
        title: 'Autre départ',
        subtitle: 'Denis Bouiti · billet du 14:00',
        payload: demo.tickets['WRONG_DEPARTURE']!,
        icon: Icons.swap_horiz,
        tone: _Tone.warn,
      ),
      _SimulatedScan(
        title: 'Billet remboursé',
        subtitle: 'Firmin Massamba · 3A · annulé',
        payload: ticket('T5W2YZ', '3A'),
        code: code('T5W2YZ', '3A', now),
        icon: Icons.money_off,
        tone: _Tone.bad,
      ),
      _SimulatedScan(
        title: 'Billet falsifié',
        subtitle: 'Siège modifié après signature',
        payload: ticket('K2M8PQ', '9D').replaceFirst('9D', '1A'),
        icon: Icons.gpp_bad_outlined,
        tone: _Tone.bad,
      ),
      _SimulatedScan(
        title: 'Code-barres quelconque',
        subtitle: 'Étiquette de bouteille, affiche, autre app',
        payload: 'https://example.cg/promo',
        icon: Icons.qr_code_2,
        tone: _Tone.bad,
      ),
    ];
  }
}

enum _Tone { good, warn, bad, neutral }
