import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/compliance_desk.dart';
import '../db/database.dart';

/// Reads the expiry calendar. The ladder itself is `DocumentExpiry`.
///
/// **Every stage is computed in Dart, none in SQL.** The temptation to write
/// `expires_at < now() + interval '30 days'` here is strong and it is the
/// mistake: the worker that blocks sales would then be agreeing with this
/// screen only by coincidence, and the day they disagreed an operator would
/// be reading "30 days left" on a console that had already stopped their
/// sales. One object answers both.
final class PostgresComplianceDesk implements ComplianceDesk {
  const PostgresComplianceDesk(this._db);

  final Database _db;

  /// Verified, unrejected, dated. An upload nobody has looked at yet is a
  /// claim rather than a licence, and it neither reassures the operator nor
  /// blocks them.
  static const _documents = '''
    SELECT k.operator_id, k.doc_type, k.expires_at
      FROM kyb_documents k
     WHERE k.expires_at IS NOT NULL
       AND k.verified_at IS NOT NULL
       AND k.rejected_reason IS NULL
  ''';

  @override
  Future<ComplianceDto> standing(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final header = await tx.execute(
          Sql.named('''
            SELECT sales_blocked_at, sales_blocked_doc
              FROM operators WHERE id = @id
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );

        final rows = await tx.execute(
          Sql.named('$_documents AND k.operator_id = @id'),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );

        final now = DateTime.now().toUtc();
        final h = header.isEmpty
            ? const <String, Object?>{}
            : header.first.toColumnMap();

        return _dto(
          operatorId: operatorId,
          blockedAt: h['sales_blocked_at'] as DateTime?,
          blockedDoc: h['sales_blocked_doc'] as String?,
          documents: _read(rows, now),
        );
      });

  @override
  Future<List<ComplianceDto>> calendar({
    required String actorUserId,
    int withinDays = 60,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    // One statement for every operator rather than one per operator: the
    // screen is a calendar, and a per-row query behind it is the shape that
    // makes an admin list slow once there are two hundred companies.
    final rows = await tx.execute(
      Sql.named('''
        $_documents
           AND EXISTS (
                 SELECT 1 FROM operators o
                  WHERE o.id = k.operator_id
                    AND o.status IN ('approved', 'active', 'suspended')
               )
           -- The window picks the **operator**, never the document. Filtering
           -- documents was the first version and it was wrong: an operator
           -- whose insurance lapsed last year and was renewed for another year
           -- has one copy inside the window and one outside, and dropping the
           -- renewal at the SQL level left the lapsed copy looking like their
           -- standing. Every copy comes back; `ComplianceStanding` decides
           -- which one counts.
           AND k.operator_id IN (
                 SELECT k2.operator_id
                   FROM kyb_documents k2
                  WHERE k2.expires_at IS NOT NULL
                    AND k2.verified_at IS NOT NULL
                    AND k2.rejected_reason IS NULL
                    AND k2.expires_at < now() + make_interval(days => @days)
               )
      '''),
      parameters: {'days': TypedValue(Type.integer, withinDays)},
    );

    final header = await tx.execute(
      Sql.named('''
        SELECT id, COALESCE(trading_name, legal_name) AS name,
               sales_blocked_at, sales_blocked_doc
          FROM operators
         WHERE status IN ('approved', 'active', 'suspended')
      '''),
      parameters: {},
    );

    final names = <String, Map<String, Object?>>{
      for (final row in header)
        (row.toColumnMap()['id'] as Object).toString(): row.toColumnMap(),
    };

    final byOperator = <String, List<DocumentExpiry>>{};
    final now = DateTime.now().toUtc();
    for (final row in rows) {
      final r = row.toColumnMap();
      final id = (r['operator_id'] as Object).toString();
      byOperator
          .putIfAbsent(id, () => [])
          .add(
            DocumentExpiry.of(
              docType: r['doc_type'] as String,
              expiresAt: (r['expires_at'] as DateTime).toUtc(),
              now: now,
            ),
          );
    }

    final out = <ComplianceDto>[];
    for (final entry in byOperator.entries) {
      final standing = ComplianceStanding.of(entry.value);
      // The reduction can move an operator back out of the window: their
      // lapsed copy is what matched in SQL, and their renewal is what counts.
      if (!standing.documents.any((d) => d.daysLeft < withinDays)) continue;

      final h = names[entry.key] ?? const {};
      out.add(
        _dto(
          operatorId: entry.key,
          name: h['name'] as String?,
          blockedAt: h['sales_blocked_at'] as DateTime?,
          blockedDoc: h['sales_blocked_doc'] as String?,
          documents: standing,
        ),
      );
    }

    // Worst first, then soonest: the top of this screen is the day's work.
    out.sort((a, b) {
      final rank = _rank(b.stage).compareTo(_rank(a.stage));
      if (rank != 0) return rank;
      final ad = a.documents.isEmpty ? 1 << 20 : a.documents.first.daysLeft;
      final bd = b.documents.isEmpty ? 1 << 20 : b.documents.first.daysLeft;
      return ad.compareTo(bd);
    });

    return out;
  });

  ComplianceStanding _read(Iterable<ResultRow> rows, DateTime now) =>
      ComplianceStanding.of([
        for (final row in rows)
          DocumentExpiry.of(
            docType: row.toColumnMap()['doc_type'] as String,
            expiresAt: (row.toColumnMap()['expires_at'] as DateTime).toUtc(),
            now: now,
          ),
      ]);

  static ComplianceDto _dto({
    required String operatorId,
    required ComplianceStanding documents,
    String? name,
    DateTime? blockedAt,
    String? blockedDoc,
  }) => ComplianceDto(
    operatorId: operatorId,
    operatorName: name,
    stage: documents.stage.name,
    salesBlockedAt: blockedAt?.toUtc(),
    blockedDoc: blockedDoc,
    documents: [
      for (final d in documents.documents)
        ComplianceDocDto(
          docType: d.docType,
          expiresAt: d.expiresAt,
          stage: d.stage.name,
          daysLeft: d.daysLeft,
        ),
    ],
  );

  static int _rank(String stage) => ExpiryStage.values
      .firstWhere((s) => s.name == stage, orElse: () => ExpiryStage.clear)
      .index;
}
