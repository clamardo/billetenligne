import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Who is on this coach.
///
/// A dialog rather than a page, because it is read next to a departure rather
/// than instead of one — a dispatcher checking a load factor wants to glance
/// at the list and get back to the day.
///
/// Two things it is careful about:
///
///   * **Only confirmed passengers are here**, because the server only sends
///     those. A reservation nobody has paid for is not a passenger, and
///     printing one is how a conductor ends up arguing at the roadside with
///     somebody holding a phone.
///   * **Boarded is a fact.** It comes from `redemptions`, one row per ticket
///     ever, so this is what the scanner actually did rather than what
///     anybody expects it to do.
final class ManifestSheet extends StatelessWidget {
  const ManifestSheet({required this.manifest, super.key});

  final ManifestDto manifest;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.all(kilo.space.s4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(manifest.routeCode, style: kilo.text.h3),
                        Text(
                          context.t('console.manifest.summary', {
                            'sold': manifest.sold,
                            'boarded': manifest.boarded,
                            'capacity': manifest.capacity,
                          }),
                          style: kilo.text.bodySm.copyWith(
                            color: kilo.color.contentSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Who is driving it, above who is on it. A manifest that names
            // forty-two passengers and nobody in the cab cannot answer the
            // first question asked when a coach is late.
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: kilo.space.s4,
                vertical: kilo.space.s3,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      context.t('console.manifest.crew'),
                      style: kilo.text.label,
                    ),
                  ),
                  Expanded(
                    child: manifest.crew.isEmpty
                        // Said plainly rather than left blank: a missing line
                        // reads as a page that did not finish loading.
                        ? Text(
                            context.t('console.manifest.noCrew'),
                            style: kilo.text.bodySm.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                          )
                        : Wrap(
                            spacing: kilo.space.s3,
                            runSpacing: kilo.space.s2,
                            children: [
                              for (final member in manifest.crew)
                                Text(
                                  _crewLine(context, member),
                                  style: kilo.text.bodySm,
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            Flexible(
              child: manifest.passengers.isEmpty
                  ? Padding(
                      padding: EdgeInsets.all(kilo.space.s6),
                      child: Text(
                        context.t('console.manifest.empty'),
                        style: kilo.text.body,
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: manifest.passengers.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = manifest.passengers[i];
                        return ListTile(
                          leading: SizedBox(
                            width: 48,
                            child: Text(p.seatLabel, style: kilo.text.amountSm),
                          ),
                          title: Text(p.passengerName),
                          // The leg beside the reference, and only when there
                          // is one: a passenger who bought a piece of the road
                          // gets off before the terminus, and the conductor
                          // reading this list is the person who has to know
                          // that seat comes free at Dolisie (ADR-0025).
                          subtitle: Text(
                            p.boardsAt == null
                                ? p.bookingRef
                                : '${p.bookingRef} · '
                                      '${p.boardsAt} → ${p.alightsAt}',
                            style: kilo.text.code,
                          ),
                          trailing: Icon(
                            p.boarded
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: p.boarded
                                ? kilo.color.success
                                : kilo.color.borderStrong,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The job, the name, and the operator's own number when they have one —
  /// which is what somebody reads aloud in a yard. No phone: this document is
  /// behind `booking.read`, which a counter clerk holds.
  String _crewLine(BuildContext context, ManifestCrewDto member) {
    final job = context.t('enum.CrewRole.${member.role}');
    final name = member.fullName ?? '—';
    return member.staffRef == null
        ? '$job · $name'
        : '$job · $name · ${member.staffRef}';
  }
}
