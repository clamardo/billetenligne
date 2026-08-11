import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Sharing a trip with somebody who is not a customer (ADR-0014 §2).
///
/// The ask is specific and very common here: a relative travelling the 512 km
/// of the RN1, and somebody at the far end deciding when to leave for the
/// station. Today that costs phone credit and repeated calls.
///
/// Four rules the screen keeps:
///
///   * **Opening it shares nothing.** The link is minted by a button, never
///     by arriving here. A traveller who taps "partager" to see what it does
///     must not discover afterwards that they published their journey.
///   * **It says what the follower will see, before they send it.** Route,
///     company, times, progress — and it says out loud that the seat, the
///     price and the phone number are not on that page. Somebody deciding
///     whether to send a link to a group chat is asking exactly that.
///   * **The count is shown.** "3 personnes ont ouvert ce lien" tells
///     somebody their message arrived, and tells somebody who sent it to the
///     wrong group that it did too — while there is still time to revoke.
///   * **Revoking is one tap and immediate.** The sheet stays open
///     afterwards, because somebody who has just revoked wants to see that it
///     is gone rather than be returned to a list.
final class ShareTripScreen extends StatelessWidget {
  const ShareTripScreen({
    required this.booking,
    required this.share,
    required this.onShare,
    required this.onRevoke,
    required this.onClose,
    this.busy = false,
    super.key,
  });

  final BookingDto booking;

  /// Null when nothing has been shared yet.
  final TripShareDto? share;

  final VoidCallback onShare;
  final VoidCallback onRevoke;
  final VoidCallback onClose;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final live = share;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onClose),
        title: Text(context.t('travel.share.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Text(
              context.t('travel.share.lead', {
                'origin': booking.originCity,
                'destination': booking.destinationCity,
                'date': Format.shortDate(booking.departsAt, locale: locale),
              }),
              style: kilo.text.body,
            ),
            SizedBox(height: kilo.space.s4),

            if (live == null) ...[
              KCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('travel.share.whatTheySee'),
                      style: kilo.text.label,
                    ),
                    SizedBox(height: kilo.space.s2),
                    for (final key in const [
                      'travel.share.seeRoute',
                      'travel.share.seeProgress',
                      'travel.share.seeDisruption',
                    ])
                      Padding(
                        padding: EdgeInsets.only(bottom: kilo.space.s1),
                        child: Text(
                          '· ${context.t(key)}',
                          style: kilo.text.bodySm,
                        ),
                      ),
                    SizedBox(height: kilo.space.s2),
                    // The reassurance somebody actually wants before sending
                    // a link to a group chat.
                    Text(
                      context.t('travel.share.neverSee'),
                      style: kilo.text.bodySm.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: kilo.space.s4),
              KButton(
                label: context.t('travel.share.create'),
                icon: Icons.share,
                loading: busy,
                onPressed: busy ? null : onShare,
              ),
            ] else ...[
              KCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.t('travel.share.linkLabel'),
                      style: kilo.text.bodySm.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                    SizedBox(height: kilo.space.s2),
                    SelectableText(
                      live.url ?? context.t('travel.share.linkHidden'),
                      style: kilo.text.body.copyWith(
                        color: kilo.color.brandPrimary,
                      ),
                    ),
                    SizedBox(height: kilo.space.s3),
                    KButton(
                      label: context.t('common.actions.copy'),
                      tone: KButtonTone.ghost,
                      onPressed: live.url == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: live.url!),
                            ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: kilo.space.s3),

              Text(
                context.tPlural('travel.share.opens', live.opens),
                style: kilo.text.body,
              ),
              SizedBox(height: kilo.space.s1),
              Text(
                context.t('travel.share.expires', {
                  'date': Format.shortDate(live.expiresAt, locale: locale),
                  'time': Format.time(live.expiresAt),
                }),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),

              SizedBox(height: kilo.space.s5),
              KButton(
                label: context.t('travel.share.revoke'),
                tone: KButtonTone.secondary,
                loading: busy,
                onPressed: busy ? null : onRevoke,
              ),
              SizedBox(height: kilo.space.s2),
              Text(
                context.t('travel.share.revokeHint'),
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
