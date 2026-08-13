import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

/// The full-screen result of a scan.
///
/// Design constraints, all from the door of a coach at 11:00:
///   * **One word**, readable at arm's length in direct sun.
///   * Colour fills the screen, so the conductor reads it peripherally while
///     already looking at the next passenger.
///   * The supporting line is what they need to *say out loud* — a name, a
///     seat, a time — never an error code.
///   * Dismissable by tapping anywhere. Boarding sixty people in ten minutes
///     leaves no room for hunting a button.
class VerdictScreen extends StatelessWidget {
  const VerdictScreen({
    required this.outcome,
    required this.onDismiss,
    this.onOverride,
    super.key,
  });

  final VerificationOutcome outcome;
  final VoidCallback onDismiss;

  /// Offered only for a stale code. The passenger is standing there with a
  /// genuine signed ticket and a slow phone; refusing them is the worse
  /// outcome, so the override exists — and is recorded.
  final VoidCallback? onOverride;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final style = _VerdictStyle.of(outcome.result, kilo.color);
    final payload = outcome.payload;
    final leg = _leg;

    return Semantics(
      liveRegion: true,
      label: _spokenLabel,
      child: GestureDetector(
        onTap: onDismiss,
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          color: style.background,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(kilo.space.s6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Icon(style.icon, size: 96, color: style.foreground),
                  SizedBox(height: kilo.space.s4),
                  Text(
                    style.word,
                    textAlign: TextAlign.center,
                    style: kilo.text.display.copyWith(
                      color: style.foreground,
                      fontSize: 40,
                      height: 1.05,
                      letterSpacing: -0.5,
                    ),
                  ),
                  if (payload != null) ...[
                    SizedBox(height: kilo.space.s6),
                    Text(
                      payload.passengerName,
                      textAlign: TextAlign.center,
                      style: kilo.text.h2.copyWith(color: style.foreground),
                    ),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      // Seat and reference are what a conductor reads aloud.
                      '${payload.seatLabel}  ·  ${payload.bookingRef}',
                      textAlign: TextAlign.center,
                      style: kilo.text.amount.copyWith(
                        color: style.foreground.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                  // Where they get off, when they bought a piece of the road
                  // (ADR-0025). The conductor learns it here, at the door,
                  // rather than at Dolisie when somebody stands up and the
                  // seat behind them has already left empty.
                  if (leg != null) ...[
                    SizedBox(height: kilo.space.s2),
                    Text(
                      leg,
                      textAlign: TextAlign.center,
                      style: kilo.text.h3.copyWith(color: style.foreground),
                    ),
                  ],
                  if (_supportingLine != null) ...[
                    SizedBox(height: kilo.space.s5),
                    Text(
                      _supportingLine!,
                      textAlign: TextAlign.center,
                      style: kilo.text.bodyLg.copyWith(
                        color: style.foreground.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (onOverride != null) ...[
                    _OverrideButton(style: style, onPressed: onOverride!),
                    SizedBox(height: kilo.space.s3),
                  ],
                  Text(
                    'Touchez pour continuer',
                    textAlign: TextAlign.center,
                    style: kilo.text.bodySm.copyWith(
                      color: style.foreground.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Only for a piece of the road. A whole-journey ticket says the two towns
  /// the coach itself is going between, which is the one thing everybody at
  /// this door already knows.
  String? get _leg {
    final entry = outcome.entry;
    if (entry?.alightsAt == null) return null;
    return 'Descend à ${entry!.alightsAt}';
  }

  String? get _supportingLine => switch (outcome.result) {
    VerificationResult.alreadyBoarded =>
      outcome.firstScannedAt == null
          ? 'Ce billet a déjà été scanné.'
          : 'Déjà scanné à ${_hhmm(outcome.firstScannedAt!)}.',
    // The useful answer is which coach to send them to, not "no".
    VerificationResult.wrongDeparture =>
      'Ce billet est pour un autre départ.\nOrientez le passager.',
    VerificationResult.staleCode =>
      'Demandez au passager d\'ouvrir\nson billet et de réessayer.',
    VerificationResult.voided =>
      'Ce billet a été remboursé.\nIl n\'est plus valable.',
    VerificationResult.notOnManifest =>
      'Billet absent de cette liste.\nSynchronisez avant d\'embarquer.',
    VerificationResult.invalid => 'Billet non reconnu.',
    VerificationResult.valid => null,
  };

  String get _spokenLabel {
    final name = outcome.payload?.passengerName ?? '';
    final leg = _leg;
    return '${_VerdictStyle.wordFor(outcome.result)}. $name'
        '${leg == null ? '' : '. $leg'}';
  }

  static String _hhmm(DateTime t) {
    final local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _OverrideButton extends StatelessWidget {
  const _OverrideButton({required this.style, required this.onPressed});

  final _VerdictStyle style;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: style.foreground,
          side: BorderSide(color: style.foreground, width: 2),
          shape: RoundedRectangleBorder(
            borderRadius: kilo.radius.controlBorder,
          ),
        ),
        child: Text(
          'Embarquer quand même',
          style: kilo.text.h3.copyWith(color: style.foreground),
        ),
      ),
    );
  }
}

/// Colour, icon and word per verdict.
///
/// Red is reserved for "this person must not board". Amber means recoverable
/// at the door — a stale code or the wrong coach are usually a slow phone or
/// an honest mistake, and accusing someone in front of a queue is both wrong
/// and bad for the operator.
final class _VerdictStyle {
  const _VerdictStyle({
    required this.word,
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final String word;
  final Color background;
  final Color foreground;
  final IconData icon;

  static String wordFor(VerificationResult r) => switch (r) {
    VerificationResult.valid => 'VALIDE',
    VerificationResult.alreadyBoarded => 'DÉJÀ EMBARQUÉ',
    VerificationResult.wrongDeparture => 'MAUVAIS DÉPART',
    VerificationResult.staleCode => 'CODE PÉRIMÉ',
    VerificationResult.voided => 'BILLET ANNULÉ',
    VerificationResult.notOnManifest => 'ABSENT DE LA LISTE',
    VerificationResult.invalid => 'INVALIDE',
  };

  static _VerdictStyle of(VerificationResult result, KiloColors c) =>
      switch (result) {
        VerificationResult.valid => _VerdictStyle(
          word: wordFor(result),
          background: c.success,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.check_circle_outline,
        ),
        VerificationResult.alreadyBoarded => _VerdictStyle(
          word: wordFor(result),
          background: c.danger,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.do_not_disturb_on_outlined,
        ),
        VerificationResult.wrongDeparture => _VerdictStyle(
          word: wordFor(result),
          background: c.warning,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.swap_horiz,
        ),
        VerificationResult.staleCode => _VerdictStyle(
          word: wordFor(result),
          background: c.warning,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.timer_outlined,
        ),
        VerificationResult.voided => _VerdictStyle(
          word: wordFor(result),
          background: c.danger,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.money_off,
        ),
        VerificationResult.notOnManifest => _VerdictStyle(
          word: wordFor(result),
          background: c.warning,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.help_outline,
        ),
        VerificationResult.invalid => _VerdictStyle(
          word: wordFor(result),
          background: c.danger,
          foreground: const Color(0xFFFFFFFF),
          icon: Icons.close,
        ),
      };
}
