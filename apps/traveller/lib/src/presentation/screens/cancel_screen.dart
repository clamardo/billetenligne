import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Cancelling, by the traveller (`01-feature-spec.md` §8.2).
///
/// The screen answers three questions in order, because that is the order
/// somebody asks them: *what am I cancelling*, *what do I get back*, and
/// *where do I get it*. Four rules hold it together:
///
///   * **An unpaid reservation is released, never "refunded".** It is the
///     commonest cancellation in the system — a payment code that was never
///     used — and offering a refund of zero francs for it reads as a bug to
///     the person being told it.
///   * **What is retained is shown beside what comes back.** A traveller who
///     sees only the smaller number assumes a mistake; a traveller who sees
///     both is reading a policy they agreed to.
///   * **"Nothing comes back" is said in words.** The bands may all have
///     elapsed, and `0 FCFA` beside a confirm button is read by nobody.
///   * **The cancellation is still offered when it pays nothing.** Somebody
///     who knows they cannot travel would rather free the seat than no-show,
///     and hiding the button does not give them their money back.
final class CancelScreen extends StatelessWidget {
  const CancelScreen({
    required this.booking,
    required this.offer,
    required this.onConfirm,
    required this.onClose,
    this.busy = false,
    this.failure,
    super.key,
  });

  final BookingDto booking;

  /// Null while the first read is in flight.
  final CancellationOfferDto? offer;

  final VoidCallback onConfirm;
  final VoidCallback onClose;
  final bool busy;

  /// Rendered above the button, never instead of it.
  final ApiFailure? failure;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final quote = offer;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onClose),
        title: Text(context.t('travel.cancel.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: quote == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.all(kilo.space.s4),
                children: [
                  Text(
                    context.t('travel.cancel.lead', {
                      'origin': quote.originCity,
                      'destination': quote.destinationCity,
                      'date': Format.shortDate(quote.departsAt, locale: locale),
                    }),
                    style: kilo.text.body,
                  ),
                  Text(
                    context.tPlural('travel.cancel.seats', quote.seatCount),
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s4),

                  if (failure != null) ...[
                    KCard(
                      tone: kilo.color.dangerSoft,
                      child: Text(
                        context.t(failure!.messageKey),
                        style: kilo.text.body,
                      ),
                    ),
                    SizedBox(height: kilo.space.s4),
                  ],

                  if (!quote.isPossible)
                    KCard(
                      tone: kilo.color.warningSoft,
                      child: Text(
                        context.t('errors.${quote.refusalCode}'),
                        style: kilo.text.body,
                      ),
                    )
                  else if (!quote.owesMoney)
                    ..._release(context)
                  else
                    ..._refund(context, quote, locale),
                ],
              ),
      ),
    );
  }

  /// Nothing was paid. The shortest path on the screen, and the one most
  /// people take.
  List<Widget> _release(BuildContext context) {
    final kilo = context.kilo;
    return [
      KCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t('travel.cancel.releaseTitle'),
              style: kilo.text.label,
            ),
            SizedBox(height: kilo.space.s2),
            Text(context.t('travel.cancel.releaseBody'), style: kilo.text.body),
          ],
        ),
      ),
      SizedBox(height: kilo.space.s4),
      KButton(
        label: context.t('travel.cancel.releaseConfirm'),
        tone: KButtonTone.secondary,
        loading: busy,
        onPressed: busy ? null : onConfirm,
      ),
      SizedBox(height: kilo.space.s2),
      _keepButton(context),
    ];
  }

  List<Widget> _refund(
    BuildContext context,
    CancellationOfferDto quote,
    String locale,
  ) {
    final kilo = context.kilo;
    final refundable = quote.refundable;

    return [
      KCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.t('travel.cancel.refundTitle'),
              style: kilo.text.label,
            ),
            SizedBox(height: kilo.space.s3),
            _row(
              context,
              context.t('travel.cancel.paid'),
              (quote.fare + quote.serviceFee).format(locale: locale),
            ),
            if (quote.givesNothingBack)
              // In words, not as a figure. This is the sentence the whole
              // screen exists to make impossible to miss.
              Padding(
                padding: EdgeInsets.only(top: kilo.space.s3),
                child: Text(
                  context.t('travel.cancel.nothingBack'),
                  style: kilo.text.body,
                ),
              )
            else ...[
              _row(
                context,
                context.t('travel.cancel.refundable'),
                refundable?.format(locale: locale) ?? '',
                strong: true,
              ),
              if (quote.retained != null && quote.retained!.minor > 0)
                // Beside what comes back, never instead of it: a traveller
                // who sees only the smaller number assumes a mistake.
                _row(
                  context,
                  context.t('travel.cancel.retained'),
                  quote.retained!.format(locale: locale),
                ),
            ],
          ],
        ),
      ),

      if (!quote.givesNothingBack) ...[
        SizedBox(height: kilo.space.s3),
        Text(
          quote.kind == 'toSource'
              ? context.t('travel.cancel.toSource', {
                  'hours': '${quote.processingHours ?? 72}',
                })
              : context.t('travel.cancel.atCounter', {
                  'operator': booking.operatorName,
                }),
          style: kilo.text.body,
        ),
      ],

      if (quote.policyLines.isNotEmpty) ...[
        SizedBox(height: kilo.space.s4),
        Text(context.t('travel.cancel.terms'), style: kilo.text.label),
        SizedBox(height: kilo.space.s1),
        // The same sentences shown before purchase, rendered from the terms
        // stamped on the booking rather than from today's policy.
        for (final line in quote.policyLines)
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

      SizedBox(height: kilo.space.s5),
      KButton(
        label: context.t('travel.cancel.confirm'),
        tone: KButtonTone.secondary,
        loading: busy,
        onPressed: busy ? null : onConfirm,
      ),
      SizedBox(height: kilo.space.s2),
      Text(
        context.t('travel.cancel.irreversible'),
        style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
        textAlign: TextAlign.center,
      ),
      SizedBox(height: kilo.space.s3),
      _keepButton(context),
    ];
  }

  Widget _keepButton(BuildContext context) => KButton(
    label: context.t('travel.cancel.keep'),
    tone: KButtonTone.ghost,
    onPressed: busy ? null : onClose,
  );

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool strong = false,
  }) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // The label yields, never the figure: on a 320 px handset "Payé"
          // wrapping is a cosmetic loss and an elided amount is a lie.
          Flexible(child: Text(label, style: kilo.text.bodySm)),
          SizedBox(width: kilo.space.s2),
          Text(value, style: strong ? kilo.text.amount : kilo.text.body),
        ],
      ),
    );
  }
}

/// What happened, after the tap.
///
/// A screen of its own rather than a banner, for the same reason the refund
/// receipt is: a claim code is something somebody has to write down, and it
/// must not disappear because a list scrolled.
final class CancelledScreen extends StatelessWidget {
  const CancelledScreen({
    required this.booking,
    required this.done,
    required this.onClose,
    super.key,
  });

  final BookingDto booking;
  final CancellationDoneDto done;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final refunded = done.refunded;
    final code = done.claimCode;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('travel.cancel.doneTitle'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            if (done.kind == 'release')
              Text(
                context.t('travel.cancel.releaseDone'),
                style: kilo.text.body,
              )
            else if (code != null) ...[
              Text(
                context.t('travel.cancel.doneClaim', {
                  'amount': refunded?.format(locale: locale) ?? '',
                  'operator': booking.operatorName,
                }),
                style: kilo.text.body,
              ),
              SizedBox(height: kilo.space.s3),
              KCard(
                tone: kilo.color.brandPrimarySoft,
                child: Column(
                  children: [
                    // Spaced, because this is read aloud across a counter and
                    // typed by somebody else.
                    Text(
                      code.split('').join(' '),
                      style: kilo.text.codeHero,
                      textAlign: TextAlign.center,
                    ),
                    if (done.claimExpiresAt != null) ...[
                      SizedBox(height: kilo.space.s2),
                      Text(
                        context.t('travel.cancel.doneClaimExpires', {
                          'date': Format.shortDate(
                            done.claimExpiresAt!,
                            locale: locale,
                          ),
                        }),
                        style: kilo.text.bodySm,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: kilo.space.s2),
              Text(
                context.t('travel.cancel.doneSms'),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ] else if ((refunded?.minor ?? 0) > 0)
              Text(
                context.t('travel.cancel.donePending', {
                  'amount': refunded!.format(locale: locale),
                  'hours': '${done.processingHours ?? 72}',
                }),
                style: kilo.text.body,
              )
            else
              // Cancelled, seat freed, nothing owed. Said plainly rather than
              // left as an empty screen somebody reads as a failure.
              Text(
                context.t('travel.cancel.doneNothing'),
                style: kilo.text.body,
              ),

            SizedBox(height: kilo.space.s5),
            KButton(
              label: context.t('travel.cancel.close'),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
