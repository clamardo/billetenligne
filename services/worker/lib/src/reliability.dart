import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// The on-time figure operators are judged by (`08-disruption.md` §6).
///
/// **A departure counts as on time when nobody declared anything about it.**
/// Not "left within fifteen minutes" — we have no departure timestamps to
/// compare against, only what a dispatcher told us, and inventing a threshold
/// on top of data we do not have would produce a confident number that means
/// nothing. What this figure honestly says is: *of the coaches that ran, how
/// many ran without the company having to tell anybody something had gone
/// wrong.* That is a fact about the operator, it is one they control, and it
/// is the one passengers care about.
///
/// **Below the sample floor there is no figure at all.** An operator with
/// three departures and one breakdown is not "67 % on time"; they are an
/// operator nobody knows about yet. A percentage computed from four data
/// points is worse than a blank, because a blank is honest and a number is
/// read as a judgement.
///
/// Written to a column once a night rather than computed per search: a join
/// over ninety days of departures on every keystroke is how a results screen
/// gets slow, for a figure that moves once a day.
final class Reliability {
  const Reliability(
    this._db, {
    this.window = const Duration(days: 90),
    this.floor = 20,
  });

  final Database _db;

  /// How far back the figure looks. A quarter: long enough that one bad week
  /// does not define a company, short enough that last year's fleet does not
  /// flatter this year's.
  final Duration window;

  /// The fewest departures that can produce a figure at all.
  final int floor;

  Future<SweepResult> recompute() => _db.transaction(const DbScope.worker(), (
    tx,
  ) async {
    // Departures that have actually left. A cancelled one still counts
    // against the operator — it is the disruption passengers remember
    // most — but one that has not happened yet says nothing either way.
    final updated = await tx.execute(
      Sql.named('''
            WITH ran AS (
              SELECT d.operator_id,
                     count(*) AS total,
                     count(*) FILTER (
                       WHERE NOT EXISTS (SELECT 1 FROM disruptions x
                                          WHERE x.departure_id = d.id)
                     ) AS clean
                FROM departures d
               WHERE d.departs_at < now()
                 AND d.departs_at >= now() - make_interval(secs => @window)
               GROUP BY d.operator_id
            )
            UPDATE operators o
               SET reliability_sample = COALESCE(ran.total, 0),
                   reliability_computed_at = now(),
                   -- The floor lives here, in one place, rather than in every
                   -- reader deciding for itself what too small looks like.
                   on_time_rate = CASE
                     WHEN COALESCE(ran.total, 0) >= @floor
                     THEN round(100.0 * ran.clean / ran.total)::smallint
                     ELSE NULL END
              FROM (SELECT id FROM operators) AS every
              LEFT JOIN ran ON ran.operator_id = every.id
             WHERE o.id = every.id
            RETURNING o.id
          '''),
      parameters: {
        'window': TypedValue(Type.double, window.inSeconds.toDouble()),
        'floor': TypedValue(Type.integer, floor),
      },
    );

    return SweepResult(name: 'reliability.computed', affected: updated.length);
  });
}
