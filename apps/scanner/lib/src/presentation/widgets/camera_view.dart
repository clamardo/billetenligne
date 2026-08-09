import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The camera, and the reticle over it.
///
/// Two behaviours matter more than they look:
///
///   * **A cooldown between scans.** MLKit fires continuously while a code is
///     in frame, so without this the same ticket produces a strobe of verdicts
///     and the conductor sees nothing readable.
///   * **The torch is a first-class control**, not buried in a menu. Boarding
///     happens at 04:00 and at 11:00, and a conductor with one hand already on
///     a passenger's phone cannot go hunting for it.
class CameraView extends StatefulWidget {
  const CameraView({required this.onDetect, super.key});

  /// Delivers the decoded string. The verdict is decided upstream, offline.
  final void Function(String raw) onDetect;

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    // The scanner runs for a ten-minute burst on the cheapest handset the
    // operator owns. Full-rate detection buys nothing for a QR held at arm's
    // length and costs frames and battery.
    detectionTimeoutMs: 250,
  );

  DateTime? _lastDetection;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handle(BarcodeCapture capture) {
    final raw = capture.barcodes.isEmpty
        ? null
        : capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;

    // One verdict per presentation, not one per frame.
    final now = DateTime.now();
    if (_lastDetection != null &&
        now.difference(_lastDetection!) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastDetection = now;

    widget.onDetect(raw);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _handle,
          errorBuilder: (context, error, child) => const _CameraUnavailable(),
        ),
        // Corners only. A full frame competes with the QR for the conductor's
        // attention, and the QR is what they are aiming at.
        Center(
          child: SizedBox(
            width: 240,
            height: 240,
            child: CustomPaint(
              painter: _ReticlePainter(color: kilo.color.brandPrimary),
            ),
          ),
        ),
        Positioned(
          right: kilo.space.s4,
          bottom: kilo.space.s4,
          child: _TorchButton(
            on: _torchOn,
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _torchOn = !_torchOn);
            },
          ),
        ),
      ],
    );
  }
}

class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.on, required this.onPressed});

  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Semantics(
      button: true,
      label: on ? 'Éteindre la lampe' : 'Allumer la lampe',
      child: Material(
        color: on ? kilo.color.warning : kilo.color.surfaceOverlay,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            // Comfortably above the 48 dp floor: pressed with gloves, in a
            // hurry, on a coach that is already moving.
            width: 64,
            height: 64,
            child: Icon(
              on ? Icons.flashlight_on : Icons.flashlight_off,
              color: on ? kilo.color.contentPrimary : kilo.color.contentInverse,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable();

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    // A dead camera must never mean a stranded coach. Manual boarding is one
    // tap below this, and saying so beats showing a black rectangle.
    return ColoredBox(
      color: kilo.color.surfaceSunken,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.no_photography_outlined,
                size: 48,
                color: kilo.color.contentMuted,
              ),
              SizedBox(height: kilo.space.s3),
              Text(
                'Caméra indisponible',
                style: kilo.text.h3,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s2),
              Text(
                'Utilisez l\'embarquement manuel ci-dessous.\n'
                'Personne ne reste à quai.',
                textAlign: TextAlign.center,
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  const _ReticlePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const arm = 36.0;
    final w = size.width;
    final h = size.height;

    for (final corner in [
      (Offset.zero, const Offset(arm, 0), const Offset(0, arm)),
      (Offset(w, 0), Offset(w - arm, 0), Offset(w, arm)),
      (Offset(0, h), Offset(arm, h), Offset(0, h - arm)),
      (Offset(w, h), Offset(w - arm, h), Offset(w, h - arm)),
    ]) {
      canvas.drawLine(corner.$1, corner.$2, paint);
      canvas.drawLine(corner.$1, corner.$3, paint);
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.color != color;
}
