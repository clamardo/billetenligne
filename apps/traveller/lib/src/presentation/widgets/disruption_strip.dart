import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'formatting.dart';

/// What is happening to this coach, on the traveller's own ticket.
///
/// During a breakdown the ticket *is* the information channel
/// (`08-disruption.md` §3.3), and a passenger who has to phone the agency to
/// find out why nothing has moved is the cost this whole subsystem exists to
/// remove. So it sits above everything, in the operator's own words where
/// there are any.
///
/// Three rules it keeps:
///
///   * **"Aucun frais" appears only when it is true.** The server decides
///     that — it froze the entitlement at declaration — and this widget
///     renders what it was told rather than recomputing a threshold that can
///     change.
///   * **The dispatcher's note is shown verbatim.** "Le pont est coupé à
///     Loufoulakari" is the part no catalog can hold and the part somebody
///     acts on.
///   * **A new time is stated as a time**, not as a delay. "+2 h" is
///     arithmetic somebody does standing at a roadside at 04:00.
final class DisruptionStrip extends StatelessWidget {
  const DisruptionStrip({
    required this.disruption,
    required this.operatorName,
    super.key,
  });

  final DisruptionDto disruption;
  final String operatorName;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      tone: kilo.color.warningSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t('travel.ticket.disrupted', {
              'kind': context.t(disruption.kindKey),
              'operator': operatorName,
            }),
            style: kilo.text.h3,
          ),
          SizedBox(height: kilo.space.s1),
          Text(context.t(disruption.causeKey), style: kilo.text.bodySm),
          if (disruption.location != null)
            Text(
              context.t('travel.ticket.disruptedAt', {
                'place': disruption.location!,
              }),
              style: kilo.text.bodySm,
            ),
          if (disruption.revisedDepartsAt != null)
            Text(
              context.t('travel.ticket.disruptedNewTime', {
                'time': Format.time(disruption.revisedDepartsAt!),
              }),
              style: kilo.text.body,
            ),
          if (disruption.note != null) ...[
            SizedBox(height: kilo.space.s2),
            Text(disruption.note!, style: kilo.text.bodySm),
          ],
          if (disruption.marksInvoluntary) ...[
            SizedBox(height: kilo.space.s2),
            // The first question in every passenger's mind, answered once and
            // prominently.
            Text(
              context.t('travel.ticket.disruptedFree'),
              style: kilo.text.body,
            ),
            Text(
              context.t('travel.ticket.disruptedCounter', {
                'operator': operatorName,
              }),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
