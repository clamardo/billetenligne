import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  DepartureTransitionRefusal? move(
    DepartureState from,
    DepartureState? to, {
    bool isCrew = true,
    bool mayManage = false,
  }) => DepartureLifecycle.transition(
    from: from,
    to: to,
    isCrew: isCrew,
    mayManage: mayManage,
  );

  group('the table, legal', () {
    test('a coach begins boarding, leaves, and arrives', () {
      expect(move(DepartureState.scheduled, DepartureState.boarding), isNull);
      expect(move(DepartureState.boarding, DepartureState.departed), isNull);
      expect(move(DepartureState.departed, DepartureState.arrived), isNull);
    });

    // `boarding` is written by the first scan. A rural service where the
    // conductor takes paper never enters it, and a rule that required the
    // step would refuse the only departure those operators ever have.
    test('and may leave without ever having been boarding', () {
      expect(move(DepartureState.scheduled, DepartureState.departed), isNull);
      expect(move(DepartureState.delayed, DepartureState.departed), isNull);
    });

    test('a delay can happen before boarding or during it', () {
      expect(move(DepartureState.scheduled, DepartureState.delayed), isNull);
      expect(move(DepartureState.boarding, DepartureState.delayed), isNull);
    });

    // A driver tapping "we have left" twice on a bad connection means it
    // once, the same rule the roster follows for a dispatcher.
    test('saying the same thing twice is not a refusal', () {
      for (final state in DepartureState.values) {
        if (state == DepartureState.cancelled) continue;
        expect(move(state, state), isNull, reason: state.name);
      }
    });
  });

  group('the table, illegal', () {
    test('arriving without having departed', () {
      expect(
        move(DepartureState.scheduled, DepartureState.arrived),
        DepartureTransitionRefusal.outOfOrder,
      );
      expect(
        move(DepartureState.boarding, DepartureState.arrived),
        DepartureTransitionRefusal.outOfOrder,
      );
    });

    test('going back to scheduled once anything has happened', () {
      for (final from in const [
        DepartureState.delayed,
        DepartureState.boarding,
        DepartureState.departed,
      ]) {
        expect(
          move(from, DepartureState.scheduled),
          isNotNull,
          reason: from.name,
        );
      }
    });

    // The one that matters most in practice: a scanner outbox emptying three
    // hours late must not put a coach that has arrived back on the road.
    test('a coach that has left cannot un-leave', () {
      expect(
        move(DepartureState.departed, DepartureState.boarding),
        DepartureTransitionRefusal.alreadyClosed,
      );
      expect(
        move(DepartureState.arrived, DepartureState.departed),
        DepartureTransitionRefusal.alreadyClosed,
      );
    });

    test('a cancelled coach is not put back on the road', () {
      expect(
        move(DepartureState.cancelled, DepartureState.departed),
        DepartureTransitionRefusal.cancelled,
      );
      expect(
        move(DepartureState.cancelled, DepartureState.boarding),
        DepartureTransitionRefusal.cancelled,
      );
    });

    test('a name that is not one of the six', () {
      expect(
        move(DepartureState.scheduled, DepartureState.byName('en_route')),
        DepartureTransitionRefusal.unknownState,
      );
      expect(DepartureState.byName('departed'), DepartureState.departed);
      expect(DepartureState.byName(null), isNull);
    });
  });

  group('who may say it', () {
    // A capability alone would let any driver in the company close any coach
    // in it, and closing a departure stops its sales. This is what the roster
    // was built for.
    test('somebody not on this coach, and not a dispatcher', () {
      expect(
        move(DepartureState.scheduled, DepartureState.departed, isCrew: false),
        DepartureTransitionRefusal.notCrew,
      );
    });

    test('a dispatcher, whose crew has no signal', () {
      expect(
        move(
          DepartureState.scheduled,
          DepartureState.departed,
          isCrew: false,
          mayManage: true,
        ),
        isNull,
      );
    });

    // Ordering, and deliberate: a driver holding the wrong handset should
    // read "this is not your coach", not "that coach has already gone".
    test('not your coach is said ahead of already gone', () {
      expect(
        move(DepartureState.arrived, DepartureState.departed, isCrew: false),
        DepartureTransitionRefusal.notCrew,
      );
    });
  });

  group('cancelling is not a state change', () {
    // It has to tell forty-two people, mark their bookings involuntary and
    // open the re-accommodation paths. A crew member tapping a state on a
    // handset must not be able to do a quarter of that.
    test('whoever asks, and from wherever', () {
      for (final from in DepartureState.values) {
        expect(
          move(from, DepartureState.cancelled, mayManage: true),
          DepartureTransitionRefusal.cancelIsADisruption,
          reason: from.name,
        );
      }
    });
  });

  group('what closing does', () {
    // Sales, and nothing else. A passenger who boarded and is sitting down
    // has a valid ticket by definition.
    test('a coach on the road or off it stops selling', () {
      expect(DepartureLifecycle.closesSales(DepartureState.departed), isTrue);
      expect(DepartureLifecycle.closesSales(DepartureState.arrived), isTrue);
    });

    test('and every other state keeps selling', () {
      for (final state in const [
        DepartureState.scheduled,
        DepartureState.delayed,
        DepartureState.boarding,
      ]) {
        expect(
          DepartureLifecycle.closesSales(state),
          isFalse,
          reason: state.name,
        );
      }
    });
  });
}
