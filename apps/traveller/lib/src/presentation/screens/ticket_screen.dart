import 'dart:async';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n.dart';
import '../widgets/disruption_strip.dart';
import '../widgets/formatting.dart';

/// The ticket. The thing the whole product exists to hand somebody.
///
/// Four decisions, each of which is a failure at a coach door if taken the
/// other way:
///
///   * **The QR is black on white, in every theme.** Dark mode inverts a QR
///     into something many cheap scanners will not read, and the conductor's
///     phone is exactly that scanner. The card ignores the theme on purpose.
///   * **The six-digit code is rendered here, from a secret, live.** A
///     screenshot still scans — its code is frozen, which is what fails the
///     freshness check and is the entire anti-passback design (ADR-0007).
///     Computing it needs no network.
///   * **Nothing on this screen fetches.** Everything came with the booking.
///     A ticket that needs the network to display is not a ticket (ADR-0003).
///   * **A void ticket says so, loudly, and still shows.** A refunded ticket
///     that silently vanishes reads as our bug at the worst possible moment.
final class TicketScreen extends StatefulWidget {
  const TicketScreen({
    required this.booking,
    required this.ticket,
    required this.seatIndex,
    required this.onClose,
    this.onSeat,
    this.onChoices,
    this.onShare,
    this.clock = const SystemClock(),
    super.key,
  });

  final BookingDto booking;
  final TicketDto ticket;
  final int seatIndex;
  final VoidCallback onClose;

  /// Moves between the tickets of one booking. A family of four is one
  /// booking and four QRs, scanned in turn.
  final void Function(int index)? onSeat;

  /// Opens the choice screen for this booking's disruption.
  final VoidCallback? onChoices;

  /// Opens the share sheet (ADR-0014 §2). Null where there is nothing to
  /// follow — a trip that has already run.
  final VoidCallback? onShare;

  /// Injected so the rotating code can be tested at the moment it rolls over.
  /// The countdown bug this project has already hit twice — in the hold and
  /// in the Firebase session — was `DateTime.now()` inside a widget.
  final Clock clock;

  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  static const _mac = HmacSha256Authenticator();

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // One second, not thirty: the ring under the code has to move, or nobody
    // believes the number is live.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final ticket = widget.ticket;
    final booking = widget.booking;
    final now = widget.clock.now();

    final code = RotatingCode.current(
      secret: ticket.rotatingSecretBytes,
      now: now,
      mac: _mac,
    );
    final remaining = RotatingCode.secondsRemaining(now);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onClose),
        title: Text(context.t('travel.ticket.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            // Above the void notice and above the QR. A passenger opening
            // their ticket during a breakdown is looking for one thing, and
            // it is not the code.
            if (booking.disruption != null) ...[
              DisruptionStrip(
                disruption: booking.disruption!,
                operatorName: booking.operatorName,
                onChoices: widget.onChoices,
              ),
              SizedBox(height: kilo.space.s4),
            ],

            if (ticket.isVoid) ...[
              KCard(
                tone: kilo.color.dangerSoft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('travel.ticket.voidedTitle'),
                      style: kilo.text.h3.copyWith(color: kilo.color.danger),
                    ),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      context.t('travel.ticket.voidedBody'),
                      style: kilo.text.bodySm,
                    ),
                  ],
                ),
              ),
              SizedBox(height: kilo.space.s4),
            ],

            // The ticket is the one screen somebody holds up to another
            // human being, and it used to open on two lines of centred grey
            // text. A paper ticket is recognisable from across a yard; this
            // buys some of that back — the colour, the woven motif and a torn
            // edge, before anybody has read a word.
            KTicketHeader(
              origin: booking.originCity,
              destination: booking.destinationCity,
              subtitle:
                  '${Format.shortDate(booking.departsAt, locale: locale)} · '
                  '${Format.time(booking.departsAt)}',
              footnote: booking.operatorName,
            ),

            // Where to stand, above the QR rather than below it. This is the
            // line somebody reads the night before and again in a taxi, and
            // "Brazzaville" is not an instruction at half past five in the
            // morning. The directions the operator wrote come with it,
            // because a yard's name is only half of finding it.
            if (booking.originStation != null) ...[
              SizedBox(height: kilo.space.s3),
              KCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.place_outlined,
                          size: 16,
                          color: kilo.color.contentSecondary,
                        ),
                        SizedBox(width: kilo.space.s2),
                        Expanded(
                          child: Text(
                            booking.originStation!.name,
                            style: kilo.text.h3,
                          ),
                        ),
                      ],
                    ),
                    if (booking.originStation!.boardingNotes != null) ...[
                      SizedBox(height: kilo.space.s1),
                      Text(
                        booking.originStation!.boardingNotes!,
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.contentSecondary,
                        ),
                      ),
                    ],
                    if (booking.destinationStation != null) ...[
                      SizedBox(height: kilo.space.s2),
                      Text(
                        context.t('travel.ticket.arrivesAtStation', {
                          'station': booking.destinationStation!.name,
                        }),
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.contentSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            SizedBox(height: kilo.space.s4),

            _QrCard(payload: ticket.qrPayload, dimmed: ticket.isVoid),

            SizedBox(height: kilo.space.s3),

            Text(
              context.t('travel.ticket.showToConductor'),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),

            SizedBox(height: kilo.space.s4),

            // The freshness code. Big, tabular, with the ring that proves it
            // is alive — a static number would be indistinguishable from a
            // screenshot, which is the one thing it exists to distinguish.
            KCard(
              child: Column(
                children: [
                  Text(
                    context.t('travel.ticket.codeLabel'),
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        // Grouped in threes: six digits read aloud across a
                        // noisy platform are read in two halves.
                        '${code.substring(0, 3)} ${code.substring(3)}',
                        style: kilo.text.amountHero.copyWith(letterSpacing: 3),
                      ),
                      SizedBox(width: kilo.space.s3),
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          value: remaining / RotatingCode.windowSeconds,
                          strokeWidth: 3,
                          color: kilo.color.brandPrimary,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: kilo.space.s2),
                  Text(
                    context.t('travel.ticket.codeHelp'),
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s4),

            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _line(
                    context,
                    context.t('travel.ticket.passenger'),
                    ticket.passengerName,
                  ),
                  _line(
                    context,
                    context.t('common.labels.seat'),
                    ticket.seatLabel,
                  ),
                  _line(
                    context,
                    context.t('common.labels.reference'),
                    ticket.bookingRef,
                  ),
                ],
              ),
            ),

            if (booking.tickets.length > 1) ...[
              SizedBox(height: kilo.space.s3),
              Text(
                context.t('travel.ticket.seatOf', {
                  'index': widget.seatIndex + 1,
                  'total': booking.tickets.length,
                }),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s2),
              KButton(
                label: context.t('travel.ticket.nextPassenger'),
                tone: KButtonTone.secondary,
                icon: Icons.chevron_right,
                onPressed: widget.onSeat == null
                    ? null
                    : () => widget.onSeat!(widget.seatIndex + 1),
              ),
            ],

            // Below the QR, because the ticket is what this screen is for.
            // Above the offline note, because sharing is the thing somebody
            // does next — usually while still standing at the coach door.
            if (widget.onShare != null) ...[
              SizedBox(height: kilo.space.s3),
              KButton(
                label: context.t('travel.share.action'),
                tone: KButtonTone.ghost,
                icon: Icons.share,
                onPressed: widget.onShare,
              ),
            ],

            SizedBox(height: kilo.space.s3),
            Text(
              context.t('travel.ticket.offlineNote'),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: kilo.text.bodySm.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
          Text(value, style: kilo.text.body),
        ],
      ),
    );
  }
}

/// Black modules on white, whatever the theme says.
///
/// A QR rendered in a dark theme is a QR many cheap scanners refuse, and the
/// conductor's handset is exactly that scanner. The quiet zone is padding
/// around it: without one, a decoder has nothing to lock onto.
class _QrCard extends StatelessWidget {
  const _QrCard({required this.payload, this.dimmed = false});

  final String payload;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Center(
      child: Opacity(
        opacity: dimmed ? 0.35 : 1,
        child: Container(
          padding: EdgeInsets.all(kilo.space.s4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF),
            borderRadius: kilo.radius.cardBorder,
            border: Border.all(color: kilo.color.borderSubtle),
          ),
          child: QrImageView(
            data: payload,
            version: QrVersions.auto,
            size: 240,
            // Medium recovers about 15% of a damaged code, which is the right
            // trade for a screen: higher correction means denser modules, and
            // density is what kills a scan on a cracked screen in sunlight
            // (ADR-0007).
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            backgroundColor: const Color(0xFFFFFFFF),
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Color(0xFF000000),
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Color(0xFF000000),
            ),
          ),
        ),
      ),
    );
  }
}
