import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

/// A fixed instant, so "sixty days out" is a date and not a mood.
final now = DateTime.utc(2026, 3, 1, 9);

DocumentExpiry at(Duration fromNow, {String type = 'insurance'}) =>
    DocumentExpiry.of(docType: type, expiresAt: now.add(fromNow), now: now);

void main() {
  group('the ladder', () {
    test('a document good for a year says nothing', () {
      final d = at(const Duration(days: 365));
      expect(d.stage, ExpiryStage.clear);
      expect(d.noticeTag, isNull);
      expect(d.stopsSales, isFalse);
    });

    test('sixty days out is the first word', () {
      expect(at(const Duration(days: 59)).stage, ExpiryStage.noticed);
      expect(at(const Duration(days: 61)).stage, ExpiryStage.clear);
    });

    test('thirty days out is when the console starts saying so', () {
      expect(at(const Duration(days: 30)).stage, ExpiryStage.warned);
      expect(at(const Duration(days: 31)).stage, ExpiryStage.noticed);
    });

    test('the last week is urgent', () {
      expect(at(const Duration(days: 7)).stage, ExpiryStage.urgent);
      expect(at(const Duration(days: 8)).stage, ExpiryStage.warned);
    });

    test('eleven hours left is zero days left, and still not expired', () {
      final d = at(const Duration(hours: 11));
      expect(d.daysLeft, 0);
      expect(d.stage, ExpiryStage.urgent);
      // The one that would cost an operator an evening of sales if the
      // boundary were read off `daysLeft` instead of the instant.
      expect(d.stopsSales, isFalse);
    });

    test('the moment it lapses, sales stop', () {
      final d = at(const Duration(minutes: -1));
      expect(d.stage, ExpiryStage.blocked);
      expect(d.stopsSales, isTrue);
      expect(d.daysLeft, 0);
    });

    test('a week past is a suspension', () {
      expect(at(const Duration(days: -6)).stage, ExpiryStage.blocked);
      expect(at(const Duration(days: -7)).stage, ExpiryStage.suspended);
      expect(at(const Duration(days: -40)).daysLeft, -40);
    });
  });

  group('notices', () {
    test('each stage before the last week speaks once', () {
      expect(at(const Duration(days: 45)).noticeTag, 'notice60');
      expect(at(const Duration(days: 20)).noticeTag, 'notice30');
      expect(at(const Duration(days: -2)).noticeTag, 'blocked');
      expect(at(const Duration(days: -9)).noticeTag, 'suspended');
    });

    test('the final week speaks once a day, and the tag says which day', () {
      final today = DocumentExpiry.of(
        docType: 'insurance',
        expiresAt: now.add(const Duration(days: 3)),
        now: now,
      );
      final tomorrow = DocumentExpiry.of(
        docType: 'insurance',
        expiresAt: now.add(const Duration(days: 3)),
        now: now.add(const Duration(days: 1)),
      );

      expect(today.noticeTag, 'final:2026-03-01');
      expect(tomorrow.noticeTag, 'final:2026-03-02');
      expect(today.noticeTag, isNot(tomorrow.noticeTag));
    });

    test('a pass that runs twice in an hour still says it once', () {
      final first = at(const Duration(days: 3));
      final second = DocumentExpiry.of(
        docType: 'insurance',
        expiresAt: now.add(const Duration(days: 3)),
        now: now.add(const Duration(hours: 6)),
      );
      expect(first.noticeTag, second.noticeTag);
    });
  });

  group('an operator, from its documents', () {
    test('nothing dated is not the same as non-compliant', () {
      expect(ComplianceStanding.clear.stage, ExpiryStage.clear);
      expect(ComplianceStanding.of(const []).stopsSales, isFalse);
    });

    test('the standing is the worst document', () {
      final standing = ComplianceStanding.of([
        at(const Duration(days: 200), type: 'rccm'),
        at(const Duration(days: 12), type: 'transport_licence'),
        at(const Duration(days: -1), type: 'insurance'),
      ]);

      expect(standing.stage, ExpiryStage.blocked);
      expect(standing.stopsSales, isTrue);
      expect(standing.worst?.docType, 'insurance');
      expect(standing.lapsed.map((d) => d.docType), ['insurance']);
    });

    test('last year\'s lapsed certificate is history, not a block', () {
      final standing = ComplianceStanding.of([
        at(const Duration(days: -400), type: 'insurance'),
        at(const Duration(days: 300), type: 'insurance'),
      ]);

      expect(standing.documents, hasLength(1));
      expect(standing.stage, ExpiryStage.clear);
      expect(standing.stopsSales, isFalse);
    });

    test('worst first, then soonest', () {
      final standing = ComplianceStanding.of([
        at(const Duration(days: 5), type: 'b'),
        at(const Duration(days: 3), type: 'a'),
        at(const Duration(days: 90), type: 'c'),
      ]);

      expect(standing.documents.map((d) => d.docType), ['a', 'b', 'c']);
    });

    test('a suspension outranks a block', () {
      final standing = ComplianceStanding.of([
        at(const Duration(days: -2), type: 'insurance'),
        at(const Duration(days: -30), type: 'transport_licence'),
      ]);

      expect(standing.suspends, isTrue);
      expect(standing.worst?.docType, 'transport_licence');
      expect(standing.lapsed, hasLength(2));
    });
  });
}
