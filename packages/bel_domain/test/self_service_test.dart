import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The passenger's own choice (`08-disruption.md` §3.2).
///
/// What is proved here is the part that has to be true on both sides of the
/// wire: which options exist, when they stop existing, and what a passenger
/// is entitled to. The app draws the screen from these answers and the server
/// commits from the same ones, which is the whole reason they live in one
/// function (ADR-0004).
void main() {
  final noon = DateTime.utc(2026, 8, 15, 12);

  TravelChoice keeping({DateTime? departsAt}) => TravelChoice(
    kind: TravelChoiceKind.keep,
    id: 'keep',
    assigned: true,
    departureId: 'dep-rescue',
    departsAt: departsAt ?? DateTime.utc(2026, 8, 15, 14),
    arrivesAt: DateTime.utc(2026, 8, 15, 22),
    seatLabels: const ['14A'],
  );

  TravelChoice moving({int seats = 18}) => TravelChoice(
    kind: TravelChoiceKind.move,
    id: 'dep-later',
    assigned: false,
    departureId: 'dep-later',
    departsAt: DateTime.utc(2026, 8, 15, 16),
    arrivesAt: DateTime.utc(2026, 8, 16),
    seatsAvailable: seats,
  );

  group('the deadline', () {
    test('is measured from the coach, not from the declaration', () {
      // A conductor needs a manifest that stops changing while people are
      // boarding, and that is an hour before *their* coach leaves — whatever
      // time the breakdown was called in.
      expect(
        choiceDeadline(assignedDepartsAt: DateTime.utc(2026, 8, 15, 11, 30)),
        DateTime.utc(2026, 8, 15, 10, 30),
      );
    });

    test('closes the screen once it passes', () {
      final deadline = choiceDeadline(assignedDepartsAt: noon);
      expect(
        refuseChoice(
          involuntary: true,
          disruptionOpen: true,
          deadline: deadline,
          now: deadline.add(const Duration(minutes: 1)),
        ),
        isA<ChoiceWindowClosed>(),
      );
    });

    test('and is open right up to it', () {
      final deadline = choiceDeadline(assignedDepartsAt: noon);
      expect(
        refuseChoice(
          involuntary: true,
          disruptionOpen: true,
          deadline: deadline,
          now: deadline.subtract(const Duration(seconds: 1)),
        ),
        isNull,
      );
    });

    test('a disruption declared too late never opens it at all', () {
      // Called in forty minutes before the rescue coach leaves. The honest
      // answer is that the choice was never open — not that it closed, and
      // certainly not a screen that accepts a tap and then refuses.
      final deadline = choiceDeadline(
        assignedDepartsAt: noon.add(const Duration(minutes: 40)),
      );
      expect(
        refuseChoice(
          involuntary: true,
          disruptionOpen: true,
          deadline: deadline,
          now: noon,
        ),
        isA<ChoiceWindowClosed>(),
      );
    });
  });

  group('who may choose', () {
    test('somebody the operator disrupted', () {
      expect(
        refuseChoice(
          involuntary: true,
          disruptionOpen: true,
          deadline: noon.add(const Duration(hours: 2)),
          now: noon,
        ),
        isNull,
      );
    });

    test('and nobody else, however open the disruption is', () {
      // The passenger who bought a seat on the replacement coach this
      // morning. Somebody else's coach failing does not entitle them to a
      // free refund, and the entitlement lives on their booking rather than
      // on the departure they happen to share.
      expect(
        refuseChoice(
          involuntary: false,
          disruptionOpen: true,
          deadline: noon.add(const Duration(hours: 2)),
          now: noon,
        ),
        isA<NothingDisrupted>(),
      );
    });

    test('a resolved disruption closes the screen', () {
      expect(
        refuseChoice(
          involuntary: true,
          disruptionOpen: false,
          deadline: noon.add(const Duration(hours: 2)),
          now: noon,
        ),
        isA<NothingDisrupted>(),
      );
    });
  });

  group('choosing one', () {
    ChoiceRefusal? choose(TravelChoice choice, {int seats = 1}) => refuseChoice(
      involuntary: true,
      disruptionOpen: true,
      deadline: noon.add(const Duration(hours: 2)),
      now: noon,
      choice: choice,
      seatsNeeded: seats,
    );

    test('keeping what you already have needs no seats', () {
      // They are already sitting in them. A seat count check here would
      // refuse the one option that is always safe.
      expect(choose(keeping()), isNull);
    });

    test('the refund is always available, whatever is left on the road', () {
      // ADR-0015 rule 4: the platform floor. No operator policy configures it
      // away, and no sold-out afternoon removes it.
      const refund = TravelChoice(
        kind: TravelChoiceKind.refund,
        id: 'refund',
        assigned: false,
        amount: Money.xaf(9300),
      );
      expect(choose(refund, seats: 4), isNull);
    });

    test('a departure with room is taken', () {
      expect(choose(moving()), isNull);
    });

    test('one that sold out while they were reading is refused as such', () {
      expect(choose(moving(seats: 0)), isA<ChoiceNoLongerAvailable>());
    });

    test('a party is never split to make the arithmetic work', () {
      // The same rule the dispatcher's wave follows, said this time to the
      // family who would otherwise be the ones split.
      final refusal = choose(moving(seats: 2), seats: 3);
      expect(refusal, isA<PartyDoesNotFit>());
      expect(refusal!.params, {'seatsNeeded': 3, 'seatsAvailable': 2});
    });
  });

  group('what may be offered at all', () {
    bool offer({
      String candidateStatus = 'scheduled',
      DateTime? candidateDepartsAt,
      String candidateRouteId = 'route-1',
      int seatsAvailable = 18,
      int seatsNeeded = 1,
    }) => offerableToPassenger(
      departureId: 'dep-later',
      currentDepartureId: 'dep-broken',
      routeId: 'route-1',
      candidateRouteId: candidateRouteId,
      candidateStatus: candidateStatus,
      departsAt: DateTime.utc(2026, 8, 15, 6),
      candidateDepartsAt: candidateDepartsAt ?? DateTime.utc(2026, 8, 15, 16),
      now: noon,
      seatsAvailable: seatsAvailable,
      seatsNeeded: seatsNeeded,
    );

    test('a later coach on the same road, with room', () {
      expect(offer(), isTrue);
    });

    test('one that has already gone is not an option', () {
      expect(
        offer(candidateDepartsAt: noon.subtract(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('a coach that broke down at 09:00 can still take the 08:00', () {
      // Judged against **now**, not against the original 06:00. Comparing to
      // the broken departure's own time refuses the 08:00 for a reason
      // nobody could explain to the passenger standing there — except that
      // the 08:00 must not itself have left.
      expect(
        offer(candidateDepartsAt: noon.add(const Duration(minutes: 30))),
        isTrue,
      );
    });

    test('a cancelled coach is not an option', () {
      expect(offer(candidateStatus: 'cancelled'), isFalse);
    });

    test('another road is a different journey, not a replacement', () {
      expect(offer(candidateRouteId: 'route-2'), isFalse);
    });

    test('and a full one is never drawn', () {
      // An option the server would refuse is worse than one never shown: by
      // the time the passenger finds out, they have already told somebody
      // they have a coach.
      expect(offer(seatsAvailable: 0), isFalse);
      expect(offer(seatsAvailable: 2, seatsNeeded: 3), isFalse);
    });
  });
}
