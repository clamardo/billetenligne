import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// Keeps a rolling window of departures on sale, without anybody asking.
///
/// **This is the one pass here that is not tidy-up.** Every other sweeper is
/// an optimisation over a correctness property that already holds; this one
/// creates inventory, and a night it does not run is a night the far edge of
/// the sales window quietly stops moving. It is still not a *correctness*
/// guarantee — a dispatcher can always materialise by hand from the console,
/// which is exactly how it worked before this existed — but it is the
/// difference between a pilot with one operator and ten operators nobody has
/// to remind.
///
/// The horizon is **rolling and fixed**, not "everything the rule allows". A
/// pattern with no end date describes departures until the heat death of the
/// universe, and materialising them would write a million seat rows for a
/// timetable that will be edited next month. Three weeks is roughly how far
/// ahead this market books, and re-running daily is what keeps the far edge
/// moving forward one day at a time.
///
/// Idempotent by construction: `materialise` creates nothing it has already
/// created, so a pass that runs twice, or a pass that overlaps yesterday's
/// window, is a no-op rather than a duplicate coach.
final class TimetableHorizon {
  const TimetableHorizon({
    required Database db,
    required OperatorConsole console,
    required Clock clock,
    this.horizon = const Duration(days: 21),
  }) : _db = db,
       _console = console,
       _clock = clock;

  final Database _db;
  final OperatorConsole _console;
  final Clock _clock;

  /// How far ahead departures are kept on sale.
  final Duration horizon;

  /// One pass over every pattern that could produce a departure in the window.
  ///
  /// [limit] bounds a single run rather than the work: patterns not reached
  /// this pass are reached by the next one, and the report says how many were
  /// left so a scheduler running once a day against a hundred operators is a
  /// visible problem rather than a silent backlog.
  Future<SweepResult> extend({int limit = 200}) async {
    final now = _clock.now();
    final from = DateTime.utc(now.year, now.month, now.day);
    final to = from.add(horizon);

    // Read across tenants under the worker scope, then materialise each
    // pattern under **its own** tenant scope. The alternative — one
    // cross-tenant materialisation — would need this file to re-implement
    // what `PostgresOperatorConsole.materialise` already does, and a second
    // implementation of "turn a timetable into seats" is the last thing this
    // system needs.
    final patterns = await _db.transaction(const DbScope.worker(), (tx) async {
      final rows = await tx.execute(
        Sql.named('''
          SELECT p.id, p.operator_id
            FROM departure_patterns p
            JOIN operators o ON o.id = p.operator_id
           WHERE p.active
             -- A suspended or offboarded operator must not gain inventory
             -- overnight. Their existing departures are handled by the
             -- lifecycle path; this one simply stops adding to them.
             AND o.status = 'active'
             AND p.valid_from <= @to
             AND (p.valid_until IS NULL OR p.valid_until >= @from)
           ORDER BY p.operator_id, p.id
           LIMIT @limit
        '''),
        parameters: {
          'from': TypedValue(Type.date, from),
          'to': TypedValue(Type.date, to),
          'limit': TypedValue(Type.integer, limit + 1),
        },
      );
      return [
        for (final row in rows)
          (
            id: row.toColumnMap()['id'].toString(),
            operatorId: row.toColumnMap()['operator_id'].toString(),
          ),
      ];
    });

    // One more than the limit was fetched, so "there is more" is a fact
    // rather than a guess from a full page.
    final more = patterns.length > limit;
    final due = more ? patterns.take(limit) : patterns;

    var created = 0;
    var skipped = 0;
    var failed = 0;

    for (final pattern in due) {
      try {
        final report = await _console.materialise(
          operatorId: pattern.operatorId,
          patternId: pattern.id,
          from: from,
          to: to,
        );
        created += report.created;
        skipped += report.skipped.length;
      } catch (_) {
        // One operator's broken pattern must not stop another operator's
        // timetable. Counted rather than swallowed, so a pattern that fails
        // every night shows up as a number that never reaches zero.
        failed++;
      }
    }

    return SweepResult(
      name: more
          ? 'departures materialised (more due)'
          : failed > 0 || skipped > 0
          ? 'departures materialised ($skipped skipped, $failed failed)'
          : 'departures materialised',
      affected: created,
    );
  }
}
