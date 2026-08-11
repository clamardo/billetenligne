import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// Sharing a trip (ADR-0014). The rules that must not drift are about
/// *honesty*: how long a link lives, and never showing more confidence than
/// we have.
void main() {
  final departs = DateTime.utc(2026, 8, 15, 5); // 06:00 Brazzaville
  final arrives = DateTime.utc(2026, 8, 15, 13); // 14:00, eight hours

  group('how long a link lives', () {
    test('arrival plus six hours', () {
      // Long enough that a coach four hours late is still followable — which
      // is exactly when somebody is watching — and short enough that a link
      // forwarded through three WhatsApp groups stops working before it
      // becomes a permanent record of somebody's travel.
      expect(shareExpiry(arrives), DateTime.utc(2026, 8, 15, 19));
    });

    test('a live link opens', () {
      final result = openable(
        now: DateTime.utc(2026, 8, 15, 9),
        expiresAt: shareExpiry(arrives),
      );
      expect(result.failureOrNull, isNull);
    });

    test('past the window it does not', () {
      final result = openable(
        now: DateTime.utc(2026, 8, 15, 19),
        expiresAt: shareExpiry(arrives),
      );
      expect(result.failureOrNull, isA<ShareExpired>());
    });

    test('the boundary is exclusive, so expiry means expired', () {
      // A link that still worked at exactly its expiry would make "expires at
      // 19:00" a sentence somebody has to test to understand.
      expect(
        openable(
          now: shareExpiry(arrives),
          expiresAt: shareExpiry(arrives),
        ).failureOrNull,
        isA<ShareExpired>(),
      );
    });

    test('a revoked link is a different refusal from an expired one', () {
      final result = openable(
        now: DateTime.utc(2026, 8, 15, 9),
        expiresAt: shareExpiry(arrives),
        revokedAt: DateTime.utc(2026, 8, 15, 8),
      );

      // Kept apart so the traveller's own screen can say which happened. The
      // follower is told neither.
      expect(result.failureOrNull, isA<ShareRevoked>());
      expect(result.failureOrNull!.code, 'share.revoked');
    });

    test('revocation wins over a window that is still open', () {
      expect(
        openable(
          now: DateTime.utc(2026, 8, 15, 6),
          expiresAt: shareExpiry(arrives),
          revokedAt: DateTime.utc(2026, 8, 15, 6),
        ).failureOrNull,
        isA<ShareRevoked>(),
      );
    });
  });

  group('progress from the timetable alone', () {
    test('before departure is nothing, not a negative', () {
      final p = scheduledProgress(
        now: DateTime.utc(2026, 8, 15, 3),
        departsAt: departs,
        arrivesAt: arrives,
      );
      expect(p.fraction, 0);
      expect(p.tier, TrackingTier.schedule);
      expect(p.isEstimate, isTrue);
    });

    test('halfway through is halfway along', () {
      final p = scheduledProgress(
        now: DateTime.utc(2026, 8, 15, 9),
        departsAt: departs,
        arrivesAt: arrives,
      );
      expect(p.fraction, closeTo(0.5, 0.001));
    });

    test('a coach running three hours late is not 140% arrived', () {
      final p = scheduledProgress(
        now: DateTime.utc(2026, 8, 15, 16),
        departsAt: departs,
        arrivesAt: arrives,
      );
      expect(p.fraction, 1);
    });

    test('a zero-length trip does not divide by zero', () {
      expect(
        scheduledProgress(
          now: departs,
          departsAt: departs,
          arrivesAt: departs,
        ).fraction,
        1,
      );
      expect(
        scheduledProgress(
          now: departs.subtract(const Duration(hours: 1)),
          departsAt: departs,
          arrivesAt: departs,
        ).fraction,
        0,
      );
    });

    test('the schedule tier carries no observation behind it', () {
      final p = scheduledProgress(
        now: DateTime.utc(2026, 8, 15, 9),
        departsAt: departs,
        arrivesAt: arrives,
      );
      // Null rather than `now`: a timestamp on an estimate reads as a
      // reading, and there is nothing here that was ever observed.
      expect(p.reportedAt, isNull);
      expect(p.checkpointName, isNull);
    });
  });

  group('progress from a checkpoint somebody confirmed', () {
    final dolisie = Checkpoint(
      name: 'Dolisie',
      fraction: 0.66,
      passedAt: DateTime.utc(2026, 8, 15, 9, 42),
    );

    test('the fact is carried, not the arithmetic', () {
      final p = checkpointProgress(
        now: DateTime.utc(2026, 8, 15, 11),
        departsAt: departs,
        arrivesAt: arrives,
        last: dolisie,
      );

      // "Passé Dolisie à 10:42" is what somebody deciding when to leave for
      // the station acts on. The bar is decoration next to it.
      expect(p.tier, TrackingTier.checkpoint);
      expect(p.checkpointName, 'Dolisie');
      expect(p.reportedAt, DateTime.utc(2026, 8, 15, 9, 42));
      expect(p.isEstimate, isFalse);
    });

    test('the bar never walks back behind a confirmed waypoint', () {
      // The coach passed Dolisie early. The timetable says it is only half
      // way; the conductor's tap says otherwise, and the tap is a fact.
      final p = checkpointProgress(
        now: DateTime.utc(2026, 8, 15, 9),
        departsAt: departs,
        arrivesAt: arrives,
        last: dolisie,
      );

      expect(p.fraction, 0.66);
    });

    test('and it does move on afterwards', () {
      final p = checkpointProgress(
        now: DateTime.utc(2026, 8, 15, 12),
        departsAt: departs,
        arrivesAt: arrives,
        last: dolisie,
      );
      expect(p.fraction, greaterThan(0.66));
    });
  });
}
