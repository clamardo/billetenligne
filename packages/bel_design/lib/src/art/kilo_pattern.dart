import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../kilo_theme.dart';

/// The header motifs an operator may choose for their storefront
/// (`05-design-system.md` §10), drawn from Congolese woven textile.
///
/// Patterns are geometry rather than artwork, so unlike the illustrations
/// under `assets/` they are painted rather than authored as SVG: a motif has
/// to tile at any width without stretching, stay crisp at any density, and
/// survive being 24 px tall behind a logo. Stretching a fixed-size drawing to
/// fit does none of those.
enum KPatternMotif {
  /// No motif. A confident flat field is a legitimate choice and the default.
  flat,
  diagonale,
  vagues,
  kuba;

  static KPatternMotif byName(String? raw) {
    for (final m in values) {
      if (m.name == raw) return m;
    }
    return flat;
  }
}

/// A tinted, tiling motif band. Used behind storefront headers, section
/// dividers and the top of the traveller's home screen.
class KPattern extends StatelessWidget {
  const KPattern({
    super.key,
    this.motif = KPatternMotif.kuba,
    this.color,
    this.background,
    this.opacity = 0.16,
    this.scale = 1,
    this.height,
    this.child,
  });

  final KPatternMotif motif;

  /// The motif's ink. Defaults to the brand hue; a storefront passes the
  /// operator's own accent.
  final Color? color;
  final Color? background;
  final double opacity;
  final double scale;
  final double? height;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final ink = color ?? kilo.color.brandPrimary;
    return SizedBox(
      height: height,
      width: height == null ? null : double.infinity,
      child: CustomPaint(
        painter: _PatternPainter(
          motif: motif,
          ink: ink,
          background: background,
          opacity: opacity,
          scale: scale,
        ),
        child: child,
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  const _PatternPainter({
    required this.motif,
    required this.ink,
    required this.background,
    required this.opacity,
    required this.scale,
  });

  final KPatternMotif motif;
  final Color ink;
  final Color? background;
  final double opacity;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    if (background != null) {
      canvas.drawRect(rect, Paint()..color = background!);
    }
    if (motif == KPatternMotif.flat) return;

    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..color = ink.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..strokeCap = StrokeCap.round;

    switch (motif) {
      case KPatternMotif.flat:
        break;
      case KPatternMotif.diagonale:
        _diagonale(canvas, size, paint);
      case KPatternMotif.vagues:
        _vagues(canvas, size, paint);
      case KPatternMotif.kuba:
        _kuba(canvas, size, paint);
    }
    canvas.restore();
  }

  void _diagonale(Canvas canvas, Size size, Paint paint) {
    final step = 14.0 * scale;
    for (var x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  void _vagues(Canvas canvas, Size size, Paint paint) {
    final wave = 26.0 * scale;
    final amp = 5.0 * scale;
    for (var y = wave / 2; y < size.height + amp; y += wave / 2) {
      final path = Path()..moveTo(0, y);
      for (var x = 0.0; x < size.width; x += wave) {
        path
          ..relativeQuadraticBezierTo(wave / 4, -amp, wave / 2, 0)
          ..relativeQuadraticBezierTo(wave / 4, amp, wave / 2, 0);
      }
      canvas.drawPath(path, paint);
    }
  }

  /// Kuba cloth: nested chevrons that invert tile to tile, so each one keys
  /// into its neighbours. The inversion is the whole motif — a field of
  /// chevrons all pointing the same way reads as mountains or as bunting;
  /// interlocking them reads as weave.
  void _kuba(Canvas canvas, Size size, Paint paint) {
    final tile = 34.0 * scale;
    final rows = (size.height / tile).ceil() + 1;
    final cols = (size.width / tile).ceil() + 2;
    final dot = Paint()..color = ink.withValues(alpha: opacity * 1.5);

    for (var row = -1; row < rows; row++) {
      for (var col = -1; col < cols; col++) {
        final o = Offset(col * tile, row * tile);
        final up = (row + col).isEven;
        for (final inset in const [0.20, 0.40, 0.60]) {
          final w = tile * inset;
          final h = tile * inset * 0.62;
          final cy = o.dy + tile / 2 + (up ? h / 2 : -h / 2);
          canvas.drawPath(
            Path()
              ..moveTo(o.dx + tile / 2 - w, cy)
              ..lineTo(o.dx + tile / 2, cy + (up ? -h : h))
              ..lineTo(o.dx + tile / 2 + w, cy),
            paint,
          );
        }
        canvas.drawCircle(
          Offset(
            o.dx + tile / 2,
            o.dy + tile / 2 + (up ? -tile * 0.3 : tile * 0.3),
          ),
          math.max(1, 1.5 * scale),
          dot,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.motif != motif ||
      old.ink != ink ||
      old.background != background ||
      old.opacity != opacity ||
      old.scale != scale;
}
