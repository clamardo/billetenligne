import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Changing departure, by the traveller (`01-feature-spec.md` §8.1).
///
/// Four rules, and the first is the one the spec is emphatic about:
///
///   * **Every row is priced before selection.** Somebody scanning a list is
///     comparing prices; a screen that prices only the row you tapped makes
///     them tap five times on a connection that drops.
///   * **Every row states the arrival time.** The question being asked is
///     when they get there, not when they leave.
///   * **A row that cannot be taken is shown with its reason**, not dropped.
///     A departure missing from a list is a departure somebody telephones an
///     agency to ask about.
///   * **A cheaper departure gives nothing back, and the screen says so
///     before anybody taps.** Discovering it afterwards is the version of
///     this that generates a complaint.
final class ChangeScreen extends StatelessWidget {
  const ChangeScreen({
    required this.booking,
    required this.options,
    required this.onTake,
    required this.onPay,
    required this.onClose,
    this.busy = false,
    this.failure,
    super.key,
  });

  final BookingDto booking;

  /// Null while the first read is in flight.
  final ChangeOptionsDto? options;

  final void Function(String departureId) onTake;

  /// A row that owes money. Holds the seats and hands over to the payment
  /// funnel — which is why it is a different callback from [onTake] even
  /// though the button beside them looks the same.
  final void Function(String departureId) onPay;

  final VoidCallback onClose;
  final bool busy;

  /// Rendered above the rows, never instead of them.
  final ApiFailure? failure;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final screen = options;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onClose),
        title: Text(context.t('travel.change.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: screen == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.all(kilo.space.s4),
                children: [
                  Text(
                    context.t('travel.change.lead', {
                      'origin': screen.originCity,
                      'destination': screen.destinationCity,
                      'time': Format.time(screen.currentDepartsAt),
                      'date': Format.shortDate(
                        screen.currentDepartsAt,
                        locale: locale,
                      ),
                    }),
                    style: kilo.text.body,
                  ),
                  Text(
                    context.tPlural('travel.change.seats', screen.seatsNeeded),
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s3),

                  if (failure != null) ...[
                    KCard(
                      tone: kilo.color.dangerSoft,
                      child: Text(
                        context.t(failure!.messageKey),
                        style: kilo.text.body,
                      ),
                    ),
                    SizedBox(height: kilo.space.s3),
                  ],

                  if (screen.involuntary) ...[
                    KCard(
                      tone: kilo.color.warningSoft,
                      child: Text(
                        context.t('travel.change.involuntary'),
                        style: kilo.text.body,
                      ),
                    ),
                    SizedBox(height: kilo.space.s3),
                  ],

                  if (!screen.isOpen)
                    KCard(
                      tone: kilo.color.warningSoft,
                      child: Text(
                        context.t(
                          'errors.${screen.refusalCode}',
                          screen.refusalParams,
                        ),
                        style: kilo.text.body,
                      ),
                    )
                  else if (screen.options.isEmpty)
                    Text(context.t('travel.change.none'), style: kilo.text.body)
                  else ...[
                    // Said once, above the list, because it is true of every
                    // row and repeating it eight times is noise.
                    Text(
                      context.t('travel.change.cheaperKeepsFare'),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                    SizedBox(height: kilo.space.s2),
                    for (final option in screen.options)
                      _Row(
                        option: option,
                        locale: locale,
                        busy: busy,
                        onTake: onTake,
                        onPay: onPay,
                      ),
                  ],

                  if (screen.policyLines.isNotEmpty) ...[
                    SizedBox(height: kilo.space.s4),
                    Text(
                      context.t('travel.change.terms'),
                      style: kilo.text.label,
                    ),
                    SizedBox(height: kilo.space.s1),
                    for (final line in screen.policyLines)
                      Padding(
                        padding: EdgeInsets.only(bottom: kilo.space.s1),
                        child: Text(
                          '· ${context.tEncoded(line)}',
                          style: kilo.text.caption.copyWith(
                            color: kilo.color.contentSecondary,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

final class _Row extends StatelessWidget {
  const _Row({
    required this.option,
    required this.locale,
    required this.busy,
    required this.onTake,
    required this.onPay,
  });

  final ChangeOptionDto option;
  final String locale;
  final bool busy;
  final void Function(String departureId) onTake;
  final void Function(String departureId) onPay;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final owed = option.owed;
    final costsMoney = (owed?.minor ?? 0) > 0;

    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s3),
      child: KCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(Format.time(option.departsAt), style: kilo.text.h3),
                SizedBox(width: kilo.space.s3),
                Flexible(
                  child: Text(
                    context.t('travel.change.arrives', {
                      'time': Format.time(option.arrivesAt),
                    }),
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ),
                const Spacer(),
                // The price of this row, on this row. §8.1's mock, and the
                // reason the whole screen is one request.
                Text(
                  option.isTakeable && !costsMoney
                      ? context.t('travel.change.free')
                      : context.t('travel.change.plus', {
                          'amount': (owed ?? option.fare).format(
                            locale: locale,
                          ),
                        }),
                  style: kilo.text.amount,
                ),
              ],
            ),

            if (costsMoney && (option.fee?.minor ?? 0) > 0) ...[
              SizedBox(height: kilo.space.s1),
              Text(
                context.t('travel.change.feeLine', {
                  'amount': option.fee!.format(locale: locale),
                }),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ],

            SizedBox(height: kilo.space.s2),

            if (!option.isTakeable)
              Text(
                context.t('errors.${option.refusalCode}', option.refusalParams),
                style: kilo.text.bodySm,
              )
            else if (costsMoney) ...[
              // The difference is settled before anything moves — the seats
              // are held while the prompt is on the handset, and the booking
              // stays where it is until the money lands.
              Text(
                context.tPlural(
                  'travel.change.seatsLeft',
                  option.seatsAvailable,
                ),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s2),
              KButton(
                // The amount is on the button, not just above it. Somebody
                // about to be asked for a PIN should read the figure on the
                // thing they are pressing.
                label: context.t('travel.change.pay', {
                  'amount': owed!.format(locale: locale),
                }),
                loading: busy,
                onPressed: busy ? null : () => onPay(option.departureId),
              ),
            ] else ...[
              Text(
                context.tPlural(
                  'travel.change.seatsLeft',
                  option.seatsAvailable,
                ),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s2),
              KButton(
                label: context.t('travel.change.confirm'),
                loading: busy,
                onPressed: busy ? null : () => onTake(option.departureId),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What happened, after the tap.
final class DepartureChangedScreen extends StatelessWidget {
  const DepartureChangedScreen({
    required this.applied,
    required this.onClose,
    super.key,
  });

  final ChangeAppliedDto applied;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('travel.change.doneTitle'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Text(
              context.t('travel.change.doneBody', {
                'time': Format.time(applied.departsAt),
                'date': Format.shortDate(applied.departsAt, locale: locale),
              }),
              style: kilo.text.body,
            ),
            if (applied.seatLabels.isNotEmpty) ...[
              SizedBox(height: kilo.space.s3),
              KCard(
                tone: kilo.color.brandPrimarySoft,
                child: Text(
                  context.t('travel.change.doneSeats', {
                    'seats': applied.seatLabels.join(', '),
                  }),
                  style: kilo.text.body,
                ),
              ),
            ],
            SizedBox(height: kilo.space.s3),
            // Said out loud: somebody who screenshotted their QR yesterday has
            // a picture that will not scan, and finding that out at a coach
            // door is the failure this sentence prevents.
            Text(
              context.t('travel.change.doneTicket'),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s5),
            KButton(
              label: context.t('travel.change.close'),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
