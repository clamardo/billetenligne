import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Everything this traveller has bought.
///
/// Two sections, and the order inside them is the whole design: **soonest
/// first among what is ahead**. Somebody opening this app at 05:40 at a
/// station wants the 06:00 coach at the top of the screen and nothing else in
/// their way, and every extra tap between them and their QR is a tap taken at
/// a coach door with a queue behind them.
///
/// An unpaid reservation appears here too, marked, with its code and its
/// deadline — because "where is the code I was given?" is the other question
/// this screen exists to answer.
final class TicketsScreen extends StatelessWidget {
  const TicketsScreen({
    required this.upcoming,
    required this.past,
    required this.onOpen,
    required this.onChoices,
    required this.onCancel,
    required this.onBack,
    required this.onRefresh,
    this.stale = false,
    this.onSearch,
    super.key,
  });

  final List<BookingDto> upcoming;
  final List<BookingDto> past;
  final void Function(BookingDto booking) onOpen;

  /// Opens the choice screen for a disrupted booking, straight from the list.
  /// One tap rather than two: during a breakdown this list is what somebody
  /// opens, and the ticket underneath is not what they came for.
  final void Function(BookingDto booking) onChoices;

  /// Opens the cancellation sheet (§8.2). On the list rather than only on the
  /// ticket, because the commonest thing anybody cancels is a reservation
  /// that was never paid for — and that one has no ticket to open.
  final void Function(BookingDto booking) onCancel;

  final VoidCallback onBack;
  final Future<void> Function() onRefresh;

  /// Loaded before this session. Said out loud rather than implied: a stale
  /// list is useful, a silently stale one is a lie.
  final bool stale;

  final VoidCallback? onSearch;

  bool get _isEmpty => upcoming.isEmpty && past.isEmpty;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        title: Text(context.t('travel.tickets.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: _isEmpty
            ? KStateView(
                KEmpty(
                  title: context.t('travel.tickets.emptyTitle'),
                  body: context.t('travel.tickets.emptyBody'),
                  actionLabel: onSearch == null
                      ? null
                      : context.t('travel.tickets.emptyAction'),
                  onAction: onSearch,
                ),
              )
            : RefreshIndicator(
                onRefresh: onRefresh,
                child: ListView(
                  padding: EdgeInsets.all(kilo.space.s4),
                  children: [
                    if (stale) ...[
                      KCard(
                        tone: kilo.color.warningSoft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t('travel.tickets.staleTitle'),
                              style: kilo.text.body.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: kilo.space.s1),
                            Text(
                              context.t('travel.tickets.staleBody'),
                              style: kilo.text.bodySm,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: kilo.space.s4),
                    ],

                    if (upcoming.isNotEmpty) ...[
                      _SectionHeading(context.t('travel.tickets.upcoming')),
                      for (final booking in upcoming)
                        _BookingCard(
                          booking: booking,
                          onOpen: onOpen,
                          onChoices: onChoices,
                          onCancel: onCancel,
                        ),
                    ],

                    if (past.isNotEmpty) ...[
                      SizedBox(height: kilo.space.s4),
                      _SectionHeading(context.t('travel.tickets.past')),
                      for (final booking in past)
                        _BookingCard(
                          booking: booking,
                          onOpen: onOpen,
                          onChoices: onChoices,
                          onCancel: onCancel,
                          past: true,
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s2),
      child: Text(
        label,
        style: kilo.text.h3.copyWith(color: kilo.color.contentSecondary),
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.booking,
    required this.onOpen,
    required this.onChoices,
    required this.onCancel,
    this.past = false,
  });

  final BookingDto booking;
  final void Function(BookingDto booking) onOpen;
  final void Function(BookingDto booking) onChoices;

  /// Opens the cancellation sheet (§8.2). On the list rather than only on the
  /// ticket, because the commonest thing anybody cancels is a reservation
  /// that was never paid for — and that one has no ticket to open.
  final void Function(BookingDto booking) onCancel;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final hasTicket = booking.tickets.isNotEmpty;
    final allVoid = hasTicket && booking.tickets.every((t) => t.isVoid);

    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s3),
      child: KCard(
        // Tappable only when there is something to open. A card that responds
        // to a tap by doing nothing is worse than one that does not respond.
        onTap: hasTicket ? () => onOpen(booking) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${booking.originCity} → ${booking.destinationCity}',
                    style: kilo.text.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                // Ahead of every other badge on purpose. A traveller opening
                // this list during a breakdown is looking for one thing, and
                // "annulé" or "impayé" is not it.
                if (booking.disruption != null)
                  KChip(
                    context.t(booking.disruption!.kindKey),
                    tone: KChipTone.warning,
                  )
                else if (allVoid)
                  KChip(
                    context.t('travel.tickets.voided'),
                    tone: KChipTone.danger,
                  )
                else if (booking.state == 'cancelled' ||
                    booking.state == 'expired')
                  KChip(
                    context.t('travel.tickets.cancelled'),
                    tone: KChipTone.neutral,
                  )
                else if (!booking.isPaid)
                  KChip(
                    context.t('travel.tickets.unpaid'),
                    tone: KChipTone.warning,
                  ),
              ],
            ),
            SizedBox(height: kilo.space.s1),
            Text(
              context.t('travel.tickets.departsOn', {
                'date': Format.shortDate(booking.departsAt, locale: locale),
                'time': Format.time(booking.departsAt),
              }),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s1),
            Text(
              '${booking.operatorName} · '
              '${context.tPlural('travel.tickets.seatsLabel', booking.passengers.length)}'
              ' · ${booking.ref}',
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),

            // The code and the deadline, for a reservation still waiting to be
            // paid. This is the other question the screen exists to answer.
            if (!booking.isPaid && booking.paymentCode != null) ...[
              SizedBox(height: kilo.space.s2),
              Text(
                context.t('travel.tickets.unpaidHint', {
                  'code': booking.paymentCode!,
                  'time': booking.paymentDeadline == null
                      ? '—'
                      : Format.time(booking.paymentDeadline!),
                }),
                style: kilo.text.bodySm.copyWith(color: kilo.color.warning),
              ),
            ],

            // Above "voir le billet", and only while the coach is still
            // ahead. A disrupted trip that has already left is history, and
            // there is nothing left to choose.
            if (booking.disruption?.marksInvoluntary == true && !past) ...[
              SizedBox(height: kilo.space.s3),
              KButton(
                label: context.t('travel.choice.open'),
                onPressed: () => onChoices(booking),
              ),
            ],

            if (hasTicket && !past) ...[
              SizedBox(height: kilo.space.s3),
              KButton(
                label: context.t('travel.tickets.show'),
                icon: Icons.qr_code_2,
                tone: booking.disruption?.marksInvoluntary == true
                    ? KButtonTone.secondary
                    : KButtonTone.primary,
                onPressed: () => onOpen(booking),
              ),
            ],

            // Last, and quiet. Cancelling is a real thing people do and
            // hiding it behind a phone call is how a seat travels empty —
            // but it is never the action this card is inviting.
            if (!past) ...[
              SizedBox(height: kilo.space.s2),
              KButton(
                label: context.t('travel.cancel.action'),
                tone: KButtonTone.ghost,
                onPressed: () => onCancel(booking),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
