/// Where a compliance document stands against the calendar
/// (`03-operator-lifecycle.md` §3.3).
///
/// Ordered by severity, and the order is load-bearing: an operator's standing
/// is the worst stage among its documents, and "worst" is `index`.
enum ExpiryStage {
  /// More than sixty days out. Nothing to say.
  clear,

  /// T−60. One reminder, and nothing else changes.
  noticed,

  /// T−30. A reminder, and the console starts carrying a banner — the first
  /// stage the operator sees without opening a message.
  warned,

  /// T−7. A reminder every day, an SMS to the owner rather than an email to
  /// whoever uploaded it, and a row on our own compliance queue. This is the
  /// last stage at which the operator can fix it without losing a day's
  /// sales.
  urgent,

  /// T−0. **No new sales.** Selling a seat on a coach whose insurance lapsed
  /// this morning is the liability this whole ladder exists to avoid.
  /// Existing tickets are untouched and departures already sold still run.
  blocked,

  /// T+7. The operator is suspended, which is a decision with a reversal
  /// procedure attached (§4) rather than a state a worker quietly leaves them
  /// in forever.
  suspended;

  /// Sales stop here and at everything worse.
  bool get stopsSales => index >= ExpiryStage.blocked.index;
}

/// One document's position on the ladder.
///
/// **Pure.** Given an expiry date and an instant it answers every question
/// the worker, the console banner and the compliance queue ask, and it is the
/// only place the thresholds are written down. A worker that computed
/// `interval '30 days'` in SQL and a console that computed 30 days in Dart
/// would drift the day somebody argued about whether the boundary is
/// inclusive.
final class DocumentExpiry {
  const DocumentExpiry._({
    required this.docType,
    required this.expiresAt,
    required this.stage,
    required this.daysLeft,
    required this.noticeTag,
  });

  /// Where [expiresAt] sits relative to [now].
  ///
  /// [daysLeft] counts **whole** days and is signed: 3 means it lapses in
  /// three days and change, −3 that it lapsed three days ago. Truncation is
  /// deliberate — a document with eleven hours left has zero days left, which
  /// is what an operator reading a banner means by it.
  factory DocumentExpiry.of({
    required String docType,
    required DateTime expiresAt,
    required DateTime now,
  }) {
    final expired = !now.isBefore(expiresAt);
    final days = expired
        ? -now.difference(expiresAt).inDays
        : expiresAt.difference(now).inDays;

    final stage = switch (days) {
      // Boundaries are computed from the instant, not from `days`: a document
      // that lapses in eleven hours is not yet expired even though it has
      // zero days left, and it must not block sales an evening early.
      _ when expired && days <= -7 => ExpiryStage.suspended,
      _ when expired => ExpiryStage.blocked,
      <= 7 => ExpiryStage.urgent,
      <= 30 => ExpiryStage.warned,
      <= 60 => ExpiryStage.noticed,
      _ => ExpiryStage.clear,
    };

    return DocumentExpiry._(
      docType: docType,
      expiresAt: expiresAt,
      stage: stage,
      daysLeft: days,
      noticeTag: _tagFor(stage, now),
    );
  }

  /// Whatever the operator called it: `insurance`, `transport_licence`,
  /// `rccm`. Free text on purpose — the set differs by market, and a CHECK
  /// constraint here would be a migration every time a ministry renames a
  /// form.
  final String docType;

  final DateTime expiresAt;
  final ExpiryStage stage;
  final int daysLeft;

  /// What makes a notice fire **once**, or once a day in the final week.
  ///
  /// Null when there is nothing to say. Everything else is a stable string
  /// that goes into the outbox's `dedupe_key`, so the pass can run every ten
  /// minutes and the operator still gets one message: the uniqueness of the
  /// queue row is the whole delivery guarantee, and no `reminded_at` column
  /// has to be kept in step with it.
  final String? noticeTag;

  bool get stopsSales => stage.stopsSales;

  static String? _tagFor(ExpiryStage stage, DateTime now) => switch (stage) {
    ExpiryStage.clear => null,
    ExpiryStage.noticed => 'notice60',
    ExpiryStage.warned => 'notice30',
    // Daily, and dated for it. The last week is the one where a message a
    // day is proportionate: after it, they stop selling.
    ExpiryStage.urgent => 'final:${_day(now)}',
    ExpiryStage.blocked => 'blocked',
    ExpiryStage.suspended => 'suspended',
  };

  static String _day(DateTime now) {
    final d = now.toUtc();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

/// One operator's compliance standing, read from its documents.
///
/// **The latest copy of each kind wins.** An operator that renews its
/// insurance every year has a row per year, and the lapsed one from 2024 is
/// history rather than a reason to stop selling. Reducing by `doc_type` here
/// rather than in SQL keeps that rule in one place: the console read, the
/// admin queue and the worker all ask this object.
final class ComplianceStanding {
  const ComplianceStanding._(this.documents);

  static const clear = ComplianceStanding._([]);

  /// Latest copy per kind, worst stage first.
  final List<DocumentExpiry> documents;

  /// [documents] may contain several copies of the same `docType`; only the
  /// one expiring furthest out counts.
  static ComplianceStanding of(Iterable<DocumentExpiry> documents) {
    final latest = <String, DocumentExpiry>{};
    for (final d in documents) {
      final held = latest[d.docType];
      if (held == null || d.expiresAt.isAfter(held.expiresAt)) {
        latest[d.docType] = d;
      }
    }

    final ordered = latest.values.toList()
      ..sort((a, b) {
        final byStage = b.stage.index.compareTo(a.stage.index);
        return byStage != 0 ? byStage : a.expiresAt.compareTo(b.expiresAt);
      });

    return ComplianceStanding._(List.unmodifiable(ordered));
  }

  /// The worst stage anything is at. `clear` when there is nothing to watch:
  /// an operator with no dated documents is not thereby non-compliant — that
  /// is a review question, not a calendar one.
  ExpiryStage get stage =>
      documents.isEmpty ? ExpiryStage.clear : documents.first.stage;

  bool get stopsSales => stage.stopsSales;
  bool get suspends => stage == ExpiryStage.suspended;

  /// What to name in the banner and in the suspension reason. The worst one,
  /// because listing five is a sentence nobody reads.
  DocumentExpiry? get worst => documents.isEmpty ? null : documents.first;

  /// Everything that has actually lapsed, for a queue that lists causes.
  List<DocumentExpiry> get lapsed =>
      documents.where((d) => d.stopsSales).toList();
}
