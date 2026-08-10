import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The declaration a dispatcher makes at the roadside.
///
/// Everything the passenger experiences is derived from it, so the rules that
/// matter are the derivations: which status the departure takes, and — the
/// expensive one — which declarations permanently exempt a booking from fees.
void main() {
  final departsAt = DateTime.utc(2026, 8, 15, 6);
  final now = DateTime.utc(2026, 8, 15, 5, 40);

  Disruption declare(
    DisruptionKind kind, {
    DisruptionCause cause = DisruptionCause.mechanical,
    DateTime? revised,
    DateTime? resolution,
    String? note,
    String? location,
  }) {
    final result = declareDisruption(
      kind: kind,
      cause: cause,
      departsAt: departsAt,
      now: now,
      revisedDepartsAt: revised,
      estimatedResolution: resolution,
      note: note,
      location: location,
    );
    expect(
      result.isOk,
      isTrue,
      reason: 'expected a declaration, got ${result.failureOrNull}',
    );
    return result.valueOrNull!;
  }

  group('what a declaration refuses', () {
    test('a delay with no new time is not a declaration', () {
      // It is an apology. A passenger told "delayed" with no number cannot
      // decide anything, which is the one thing this screen exists to let
      // them do.
      final result = declareDisruption(
        kind: DisruptionKind.delay,
        cause: DisruptionCause.lateInbound,
        departsAt: departsAt,
        now: now,
      );

      expect(result.failureOrNull, isA<DelayNeedsARevisedTime>());
    });

    test('a revised time that is not later is refused', () {
      final result = declareDisruption(
        kind: DisruptionKind.delay,
        cause: DisruptionCause.lateInbound,
        departsAt: departsAt,
        now: now,
        revisedDepartsAt: departsAt.subtract(const Duration(minutes: 10)),
      );

      expect(result.failureOrNull, isA<RevisedTimeIsNotLater>());
    });

    test('an estimated resolution already in the past is refused', () {
      // A promise broken at the moment it is made. Worse than no estimate,
      // because the passenger checks it and finds it expired.
      final result = declareDisruption(
        kind: DisruptionKind.breakdownEnRoute,
        cause: DisruptionCause.mechanical,
        departsAt: departsAt,
        now: now,
        estimatedResolution: now.subtract(const Duration(minutes: 1)),
      );

      expect(result.failureOrNull, isA<ResolutionIsInThePast>());
    });

    test('everything else needs one tap and nothing else', () {
      // Six fields on this form would be six fields filled in badly at the
      // roadside. Kind and cause are the whole requirement.
      final result = declareDisruption(
        kind: DisruptionKind.breakdownEnRoute,
        cause: DisruptionCause.mechanical,
        departsAt: departsAt,
        now: now,
      );

      expect(result.isOk, isTrue);
    });
  });

  group('what the departure becomes', () {
    test('a delay delays it and a cancellation cancels it', () {
      expect(
        declare(
          DisruptionKind.delay,
          revised: departsAt.add(const Duration(minutes: 30)),
        ).departureStatus,
        'delayed',
      );
      expect(declare(DisruptionKind.cancellation).departureStatus, 'cancelled');
      expect(
        declare(DisruptionKind.routeSuspension).departureStatus,
        'cancelled',
      );
    });

    test('a coach already on the road is not put back into "not left yet"', () {
      // A breakdown en route and a diversion both leave the status alone. The
      // passengers are already somewhere between two cities, and a board
      // reading `delayed` would tell an agency the coach is still at the gare.
      expect(declare(DisruptionKind.breakdownEnRoute).departureStatus, isNull);
      expect(declare(DisruptionKind.diversion).departureStatus, isNull);
      expect(declare(DisruptionKind.equipmentSwap).departureStatus, isNull);
    });
  });

  group('what it entitles the passenger to', () {
    test('a breakdown is involuntary, and so is everything like it', () {
      for (final kind in [
        DisruptionKind.cancellation,
        DisruptionKind.breakdownEnRoute,
        DisruptionKind.equipmentSwap,
        DisruptionKind.diversion,
        DisruptionKind.routeSuspension,
      ]) {
        expect(declare(kind).marksInvoluntary, isTrue, reason: kind.name);
      }
    });

    test('a quarter of an hour late is not a free cancellation', () {
      // An operator who tells the truth about being fifteen minutes late must
      // not pay more than one who says nothing. That is the behaviour this
      // whole subsystem needs to encourage.
      final short = declare(
        DisruptionKind.delay,
        revised: departsAt.add(const Duration(minutes: 15)),
      );

      expect(short.marksInvoluntary, isFalse);
      expect(short.delay, const Duration(minutes: 15));
    });

    test('an hour late is a different journey, and it is theirs to leave', () {
      final long = declare(
        DisruptionKind.delay,
        revised: departsAt.add(Disruption.delayThatEntitles),
      );

      expect(long.marksInvoluntary, isTrue);
    });

    test('the threshold is one object away, so the app can show it', () {
      // The dispatcher sees what their declaration will cost before they
      // confirm it — which is only possible because the rule is asked, not
      // reimplemented in a screen.
      expect(Disruption.delayThatEntitles, const Duration(hours: 1));
    });
  });

  group('what the passenger is sent', () {
    test('a key, never a sentence', () {
      // ADR-0008: the server emits catalog keys and the prose is rendered in
      // the recipient's own language, from the one reviewed catalog.
      expect(
        declare(DisruptionKind.breakdownEnRoute).summaryKey,
        'disruption.summary.breakdownEnRoute',
      );
    });

    test('"no fees" is only promised when it is true', () {
      // The short delay gets the plain template. Telling somebody fifteen
      // minutes late that they may cancel free is a promise the counter has
      // to refuse to their face.
      final short = declare(
        DisruptionKind.delay,
        revised: departsAt.add(const Duration(minutes: 15)),
      );
      expect(short.messageKey, 'sms.disruptionDeclared.body');

      expect(
        declare(DisruptionKind.cancellation).messageKey,
        'sms.disruptionDeclared.involuntary',
      );
    });

    test('always, including at 03:00', () {
      // Quiet hours never apply to disruption. A 03:00 message about a
      // cancelled 05:00 departure is exactly what the passenger wants.
      expect(declare(DisruptionKind.cancellation).notifiesPassengers, isTrue);
    });

    test('an empty note is no note', () {
      // A blank field typed and cleared must not become an empty line in a
      // message somebody pays to send.
      final blank = declare(DisruptionKind.cancellation, note: '   ');
      expect(blank.note, isNull);

      final real = declare(
        DisruptionKind.cancellation,
        note: '  route coupée  ',
        location: ' km 180, RN1 ',
      );
      expect(real.note, 'route coupée');
      expect(real.location, 'km 180, RN1');
    });
  });

  test('a stored disruption is read back without being re-judged', () {
    // A rule tightened next month must not make last month's row unreadable.
    final stored = Disruption.stored(
      kind: DisruptionKind.delay,
      cause: DisruptionCause.checkpoint,
      departsAt: departsAt,
      declaredAt: now,
      revisedDepartsAt: departsAt.add(const Duration(hours: 2)),
    );

    expect(stored.delay, const Duration(hours: 2));
    expect(stored.marksInvoluntary, isTrue);
  });
}
