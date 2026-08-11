import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// The passenger's own choice, during a breakdown (`08-disruption.md` §3.2).
///
/// This screen is the reason the disruption subsystem exists. Everything else
/// in it — the dispatcher's five options, the protection agreements, the
/// re-issued tickets — is machinery that ends here, with somebody standing on
/// a roadside deciding what happens to their afternoon.
///
/// Five rules it keeps, each of which is a support call if broken:
///
///   * **One option is already theirs.** The server pre-assigned it and it is
///     rendered first, marked, with "Je garde" rather than "Choisir". Nobody
///     is left with nothing while they think — choice here is an upgrade on a
///     safe state, never a prerequisite for one.
///   * **Every travel row states the arrival time.** That is the question
///     being asked. A screen that answers "when does it leave?" makes
///     somebody do the arithmetic standing up.
///   * **"Sans frais" is said once, at the top.** It is the first question in
///     every passenger's mind and it does not belong buried in a fourth card.
///   * **The refund is last and never hidden.** Behind no support
///     conversation, no phone number, no "contact us".
///   * **The deadline states its own fallback.** "Sans réponse avant 10:30,
///     nous vous gardons sur la place attribuée" — ambiguity at 04:00 is
///     worse than a rule somebody dislikes.
///
/// A closed window still renders the whole screen, with the buttons gone. A
/// passenger who follows an SMS link and finds a blank page assumes the worst,
/// and the worst is usually not what happened.
final class TravelChoiceScreen extends StatelessWidget {
  const TravelChoiceScreen({
    required this.choices,
    required this.onChoose,
    required this.onClose,
    this.busy = false,
    this.failure,
    super.key,
  });

  final TravelChoicesDto choices;
  final void Function(String optionId) onChoose;
  final VoidCallback onClose;

  /// True while one is being taken. Every button goes flat rather than the
  /// screen going blank: somebody who taps twice on a bad connection must be
  /// able to see which row they tapped.
  final bool busy;

  /// A refusal from the last tap, shown above the options rather than instead
  /// of them.
  final ApiFailure? failure;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final fallback = choices.fallback;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onClose),
        title: Text(context.t('travel.choice.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            KCard(
              tone: kilo.color.warningSoft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t('travel.choice.trip', {
                      'origin': choices.originCity,
                      'destination': choices.destinationCity,
                      'date': Format.shortDate(
                        fallback?.departsAt ?? choices.deadline,
                        locale: locale,
                      ),
                      'time': Format.time(
                        fallback?.departsAt ?? choices.deadline,
                      ),
                    }),
                    style: kilo.text.label,
                  ),
                  if (choices.reasonKey != null) ...[
                    SizedBox(height: kilo.space.s1),
                    Text(
                      context.t(choices.reasonKey!),
                      style: kilo.text.bodySm,
                    ),
                  ],
                  // The dispatcher's own words. No catalog holds "le pont est
                  // coupé à Loufoulakari", and that is the part somebody acts
                  // on.
                  if (choices.note != null) ...[
                    SizedBox(height: kilo.space.s1),
                    Text(choices.note!, style: kilo.text.bodySm),
                  ],
                ],
              ),
            ),

            SizedBox(height: kilo.space.s4),

            // What went wrong with the last tap, above the list it changed.
            if (failure != null) ...[
              KCard(
                tone: kilo.color.dangerSoft,
                child: Text(
                  context.t(failure!.messageKey),
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                ),
              ),
              SizedBox(height: kilo.space.s4),
            ],

            if (choices.open)
              Text(context.t('travel.choice.lead'), style: kilo.text.label)
            else
              // Closed. The options below still render, so somebody can see
              // what they were and what they are on, but nothing is tappable.
              Text(
                context.t('travel.choice.closed'),
                style: kilo.text.body.copyWith(color: kilo.color.warning),
              ),

            SizedBox(height: kilo.space.s3),

            for (final option in choices.options) ...[
              _OptionCard(
                option: option,
                seatsNeeded: choices.seatsNeeded,
                onChoose: choices.open && !busy
                    ? () => onChoose(option.id)
                    : null,
              ),
              SizedBox(height: kilo.space.s3),
            ],

            if (choices.open) ...[
              SizedBox(height: kilo.space.s2),
              Text(
                context.t('travel.choice.fallback', {
                  'time': Format.time(choices.deadline),
                }),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One row. Travel and refund render from the same card so the refund cannot
/// drift into looking like an afterthought bolted to the bottom.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.seatsNeeded,
    required this.onChoose,
  });

  final TravelChoiceDto option;
  final int seatsNeeded;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    final covered = option.covered(seatsNeeded);
    // A row that cannot take anybody is shown and disabled rather than
    // dropped: a coach that filled while the screen was open is information,
    // and a list that quietly shortens looks like a bug.
    final full = !option.isRefund && !option.assigned && covered == 0;

    return KCard(
      tone: option.assigned ? kilo.color.brandPrimarySoft : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  option.isRefund
                      ? context.t('travel.choice.refundTitle')
                      : context.t('travel.choice.departsAt', {
                          'time': Format.time(option.departsAt!),
                        }),
                  style: kilo.text.label,
                ),
              ),
              if (option.assigned)
                KChip(
                  context.t('travel.choice.assigned'),
                  tone: KChipTone.brand,
                )
              else if (option.otherOperator)
                KChip(
                  context.t('travel.choice.otherOperator'),
                  tone: KChipTone.neutral,
                ),
            ],
          ),

          SizedBox(height: kilo.space.s1),

          if (option.isRefund)
            Text(
              context.t('travel.choice.refundBody', {
                'amount': Format.money(option.amount!, locale: locale),
              }),
              style: kilo.text.body,
            )
          else ...[
            // The arrival time, first and in the reading style — this is the
            // question the passenger is actually asking.
            if (option.arrivesAt != null)
              Text(
                context.t('travel.choice.arrives', {
                  'time': Format.time(option.arrivesAt!),
                }),
                style: kilo.text.body,
              ),
            SizedBox(height: kilo.space.s1),
            Text(
              _seatLine(context, covered: covered, full: full),
              style: kilo.text.bodySm.copyWith(
                color: full ? kilo.color.danger : kilo.color.contentSecondary,
              ),
            ),
            if (option.operatorName != null)
              Text(
                option.operatorName!,
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
          ],

          SizedBox(height: kilo.space.s3),

          KButton(
            label: option.assigned
                ? context.t('travel.choice.keep')
                : context.t('travel.choice.pick'),
            tone: option.assigned ? KButtonTone.secondary : KButtonTone.primary,
            onPressed: full ? null : onChoose,
          ),
        ],
      ),
    );
  }

  /// "siège 14A" for the seat they hold, "18 places" for a coach with room,
  /// "2 places sur 5" when a party does not all fit — the arithmetic belongs
  /// on the screen, not in the head of somebody standing on a roadside.
  String _seatLine(
    BuildContext context, {
    required int covered,
    required bool full,
  }) {
    if (full) return context.t('travel.choice.full');

    if (option.assigned && option.seatLabels.isNotEmpty) {
      return context.t('travel.choice.seat', {
        'seats': option.seatLabels.join(', '),
      });
    }

    if (covered < seatsNeeded) {
      return context.t('travel.choice.partial', {
        'covered': '$covered',
        'needed': '$seatsNeeded',
      });
    }

    return context.tPlural('travel.choice.seats', option.seatsAvailable ?? 0);
  }
}

/// What happened, after they tapped.
///
/// A screen of its own rather than a banner over the list, because a refund
/// carries a code somebody has to write down and a move carries a new seat
/// somebody has to find at a coach door.
final class TravelChosenScreen extends StatelessWidget {
  const TravelChosenScreen({
    required this.applied,
    required this.onDone,
    super.key,
  });

  final ChoiceAppliedDto applied;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final code = applied.claimCode;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Icon(
              applied.kind == 'refund' ? Icons.payments : Icons.check_circle,
              size: 56,
              color: kilo.color.success,
            ),
            SizedBox(height: kilo.space.s3),
            Text(
              context.t(switch (applied.kind) {
                'refund' => 'travel.choice.refundedTitle',
                'keep' => 'travel.choice.keptTitle',
                _ => 'travel.choice.movedTitle',
              }),
              style: kilo.text.h2,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s2),

            if (applied.kind == 'refund') ...[
              Text(
                context.t('travel.choice.refundedBody', {
                  'amount': applied.refunded == null
                      ? '—'
                      : Format.money(applied.refunded!, locale: locale),
                }),
                style: kilo.text.body,
                textAlign: TextAlign.center,
              ),
              if (code != null) ...[
                SizedBox(height: kilo.space.s4),
                KCard(
                  child: Column(
                    children: [
                      Text(
                        context.t('travel.choice.claimCode'),
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.contentSecondary,
                        ),
                      ),
                      SizedBox(height: kilo.space.s2),
                      // Selectable and spaced, like the agency payment code:
                      // this one is read aloud across a counter too.
                      SelectableText(
                        code.split('').join(' '),
                        textAlign: TextAlign.center,
                        style: kilo.text.display.copyWith(
                          color: kilo.color.brandPrimary,
                          letterSpacing: 2,
                        ),
                      ),
                      SizedBox(height: kilo.space.s2),
                      Text(
                        context.t('travel.choice.claimHelp'),
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.contentSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ] else if (applied.kind == 'keep') ...[
              Text(
                context.t('travel.choice.keptBody'),
                style: kilo.text.body,
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(
                context.t('travel.choice.movedBody', {
                  'time': applied.departsAt == null
                      ? '—'
                      : Format.time(applied.departsAt!),
                  'seats': applied.seatLabels.join(', '),
                }),
                style: kilo.text.body,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s2),
              // Said plainly, because the old QR is still in their photo roll
              // and a conductor rejecting it at the door is our failure.
              Text(
                context.t('travel.choice.movedTicket'),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],

            SizedBox(height: kilo.space.s5),
            KButton(label: context.t('travel.choice.done'), onPressed: onDone),
          ],
        ),
      ),
    );
  }
}
