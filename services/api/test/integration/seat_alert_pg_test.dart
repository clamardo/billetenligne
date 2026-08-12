@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/seat_alerts.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_alerts.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Waiting for a seat, against the database that decides who is waiting.
///
/// The unit suite cannot make any of these claims, because every one of them
/// is a property of the schema or of the row-level policies:
///
///   * **Asking twice is asking once.** A partial unique index, not a check in
///     a handler — two taps on a flaky connection are the ordinary case, and
///     two rows would be two messages.
///   * **A coach with room refuses the alert.** The honest answer to "tell me
///     when there is room" on a coach with room is "go and book it"; an alert
///     accepted here would be a message about a seat somebody is looking at.
///   * **A held seat whose hold has lapsed counts as free.** The claim path
///     already treats it that way, and an alert that disagreed would refuse
///     to fire on a coach that is, in fact, sellable.
///   * **Withdrawing is idempotent and does not delete.** The row stays,
///     cancelled, because "I asked and was never told" is a support
///     conversation a deleted row cannot answer.
///   * **One traveller cannot see another's.** Read under the traveller
///     surface, so the policy is what is being tested, not a WHERE clause.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresSeatAlerts alerts;
  late String userId;
  late String otherUserId;

  /// This file's own road.
  ///
  /// Not the fixture's shared route, and the reason is worth writing down:
  /// every coach created here is a coach the *rebooking* screen would offer
  /// as an alternative, and that screen takes the first twenty. A dozen
  /// sold-out fixtures on the shared road pushed somebody else's target off
  /// the end of their list, and the failure appeared in a file that had not
  /// changed.
  late String routeId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    alerts = PostgresSeatAlerts(db);
    routeId = await fixture.route(code: 'ALERT-BZV-OYO');
    userId = await fixture.traveller('930011', name: 'Sylvie N.');
    otherUserId = await fixture.traveller('930012', name: 'Prosper K.');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A full coach: every seat held for two hours by a fixture hold.
  Future<String> soldOut() async {
    final id = await fixture.departure(
      seatLabels: const ['1A', '1B'],
      onRoute: routeId,
    );
    await fixture.fillDeparture(id);
    return id;
  }

  test('a full coach can be waited on', () async {
    final departureId = await soldOut();

    final watched = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 2,
    );

    final alert = watched.valueOrNull!;
    expect(alert.departureId, departureId);
    expect(alert.seatsWanted, 2);
    expect(alert.isWaiting, isTrue);
  });

  test('asking twice is asking once', () async {
    // Two taps on a connection that dropped. One row, and the first answer's
    // seat count survives — a second row would be a second message.
    final departureId = await soldOut();

    final first = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 2,
    );
    final second = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );

    expect(second.valueOrNull!.id, first.valueOrNull!.id);
    expect(second.valueOrNull!.seatsWanted, 2);
  });

  test('a coach with room is refused, with the number', () async {
    // Not accepted-and-fired-immediately. The traveller is looking at the
    // seat; the useful answer is "book it", and the count is what makes that
    // sentence true rather than a slogan.
    final departureId = await fixture.departure(
      seatLabels: const ['1A', '1B'],
      onRoute: routeId,
    );

    final watched = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 2,
    );

    final failure = watched.failureOrNull;
    expect(failure, isA<SeatsAreAvailable>());
    expect((failure! as SeatsAreAvailable).available, 2);
  });

  test('a party larger than what is free can still wait', () async {
    // One seat free, four people travelling. The coach is not full, and the
    // alert is still the right answer.
    final departureId = await fixture.departure(
      seatLabels: const ['1A'],
      onRoute: routeId,
    );

    final watched = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 4,
    );

    expect(watched.valueOrNull, isNotNull);
  });

  test('a lapsed hold counts as a free seat, not a full coach', () async {
    // The claim path already sells these. An alert that disagreed would
    // refuse to fire on a coach that is, in fact, sellable.
    final departureId = await soldOut();
    await fixture.lapseHolds(departureId);

    final watched = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );

    expect(watched.failureOrNull, isA<SeatsAreAvailable>());
  });

  test('a coach that has left is not worth waiting for', () async {
    final departureId = await soldOut();
    await fixture.departLongAgo(departureId, const Duration(hours: 3));

    final watched = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );

    expect(watched.failureOrNull, isA<NotWorthWaitingFor>());
  });

  test('a departure nobody is selling is not worth waiting for', () async {
    final watched = await alerts.watch(
      departureId: '00000000-0000-0000-0000-0000000000ff',
      userId: userId,
      seatsWanted: 1,
    );

    expect(watched.failureOrNull, isA<NotWorthWaitingFor>());
  });

  test('withdrawing ends it, and withdrawing twice is fine', () async {
    final departureId = await soldOut();
    await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );

    await alerts.forget(departureId: departureId, userId: userId);
    await alerts.forget(departureId: departureId, userId: userId);

    final waiting = await alerts.waitingFor(userId);
    expect(waiting.map((a) => a.departureId), isNot(contains(departureId)));
  });

  test('withdrawing frees the slot to ask again', () async {
    // The unique index is over *live* alerts only. Somebody who changed their
    // mind twice is a normal person, not a constraint violation.
    final departureId = await soldOut();
    final first = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );
    await alerts.forget(departureId: departureId, userId: userId);
    final again = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 3,
    );

    expect(again.valueOrNull, isNotNull);
    expect(again.valueOrNull!.id, isNot(first.valueOrNull!.id));
    expect(again.valueOrNull!.seatsWanted, 3);
  });

  test('two travellers wait on the same coach independently', () async {
    final departureId = await soldOut();

    final mine = await alerts.watch(
      departureId: departureId,
      userId: userId,
      seatsWanted: 1,
    );
    final theirs = await alerts.watch(
      departureId: departureId,
      userId: otherUserId,
      seatsWanted: 2,
    );

    expect(mine.valueOrNull!.id, isNot(theirs.valueOrNull!.id));

    // And neither can see the other. Read under the traveller surface, so
    // this is the row-level policy answering, not a WHERE clause.
    final ours = await alerts.waitingFor(userId);
    expect(ours.map((a) => a.id), contains(mine.valueOrNull!.id));
    expect(ours.map((a) => a.id), isNot(contains(theirs.valueOrNull!.id)));
  });

  test('the list is soonest coach first', () async {
    final later = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(days: 6),
      onRoute: routeId,
    );
    final sooner = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(days: 5),
      onRoute: routeId,
    );
    await fixture.fillDeparture(later);
    await fixture.fillDeparture(sooner);

    final mine = await fixture.traveller('930013', name: 'Order T.');
    await alerts.watch(departureId: later, userId: mine, seatsWanted: 1);
    await alerts.watch(departureId: sooner, userId: mine, seatsWanted: 1);

    final waiting = await alerts.waitingFor(mine);
    // An alert for tomorrow morning is the one about to stop mattering.
    expect(waiting.map((a) => a.departureId), [sooner, later]);
  });
}
