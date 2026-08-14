import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/road_progress.dart';
import '../l10n.dart';

/// *Où sommes-nous ?* — the road, and one tap to say the coach is past a
/// place (ADR-0014 §1, tier 2).
///
/// A list of names rather than a map. The conductor is on a coach on the RN1
/// with no signal, the places have names everybody uses, and a map would be
/// tiles that cannot load and a dot that cannot be drawn.
///
/// **Nothing here is undoable, and that is deliberate.** Confirming a
/// waypoint is publishing a fact to whoever is waiting at the far end. A
/// confirmation the conductor could take back would be one somebody already
/// left for the station on.
class RoadSheet extends StatefulWidget {
  const RoadSheet({required this.road, super.key});

  final RoadProgress road;

  @override
  State<RoadSheet> createState() => _RoadSheetState();
}

class _RoadSheetState extends State<RoadSheet> {
  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final points = widget.road.points();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('scanner.road.title'), style: kilo.text.h2),
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('scanner.road.body'),
              style: kilo.text.bodySm.copyWith(color: kilo.color.contentMuted),
            ),
            SizedBox(height: kilo.space.s4),

            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: points.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: kilo.color.borderSubtle),
                itemBuilder: (context, i) {
                  final p = points[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      p.isBehind
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: p.isBehind
                          ? kilo.color.success
                          : kilo.color.contentMuted,
                    ),
                    title: Text(p.name, style: kilo.text.body),
                    subtitle: p.isBehind
                        ? Text(
                            context.t('scanner.road.passedAt', {
                              'time': _hhmm(p.passedAt!),
                            }),
                            style: kilo.text.bodySm.copyWith(
                              color: kilo.color.contentMuted,
                            ),
                          )
                        : null,
                    // A confirmed waypoint stops answering. There is no
                    // "unconfirm": see the class comment.
                    onTap: p.isBehind ? null : () => _confirm(p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirm(RoadPoint point) {
    // The sheet stays open. A conductor coming back onto signal after three
    // hours confirms two or three places in a row, and a sheet that closed
    // after each one would make that three trips through the footer.
    setState(() => widget.road.confirm(point.stopId));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          context.t('scanner.road.confirmed', {'place': point.name}),
        ),
      ),
    );
  }

  static String _hhmm(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
