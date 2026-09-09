import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/road_progress.dart';
import '../l10n.dart';

/// *Passé Dolisie ?* — the ask, at the moment the timetable says so (J5).
///
/// A strip rather than a dialog, and that is the whole design. Confirming a
/// waypoint is worth one tap and no more; a modal in front of a conductor
/// with a queue at the door is a modal that gets dismissed for four hours and
/// then a handset that stays in a drawer. The pressure to report lives on the
/// dispatcher's screen as a coverage figure, in an office, where somebody can
/// act on it without standing in anybody's way.
///
/// **Both answers are one tap.** "Not yet" is as cheap as "yes", because the
/// prompt is a question and a question whose refusal costs more than its
/// answer is not a question.
class DuePrompt extends StatelessWidget {
  const DuePrompt({
    required this.point,
    required this.onConfirm,
    required this.onWave,
    super.key,
  });

  final RoadPoint point;
  final VoidCallback onConfirm;
  final VoidCallback onWave;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Container(
      width: double.infinity,
      color: kilo.color.surfaceRaised,
      padding: EdgeInsets.fromLTRB(
        kilo.space.s4,
        kilo.space.s3,
        kilo.space.s4,
        0,
      ),
      child: Row(
        children: [
          Icon(Icons.place_outlined, color: kilo.color.brandPrimary, size: 20),
          SizedBox(width: kilo.space.s2),
          Expanded(
            child: Text(
              context.t('scanner.road.due', {'place': point.name}),
              style: kilo.text.body,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: kilo.space.s2),
          TextButton(
            onPressed: onWave,
            child: Text(context.t('scanner.road.dueNot')),
          ),
          SizedBox(width: kilo.space.s1),
          FilledButton(
            onPressed: onConfirm,
            child: Text(context.t('scanner.road.dueYes')),
          ),
        ],
      ),
    );
  }
}
