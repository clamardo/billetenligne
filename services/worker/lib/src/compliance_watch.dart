import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// Enforces the document-expiry ladder (`03-operator-lifecycle.md` §3.3).
///
/// **The only pass here that takes something away.** Every other sweeper
/// tidies a state the request path already treats as gone; this one stops an
/// operator selling, and a week later suspends them. That is the point: an
/// insurance certificate that lapsed in March and a company still selling
/// seats in April is the failure the whole ladder exists to prevent, and it is
/// not a failure a human remembers to catch.
///
/// Graduated on purpose. By the time sales stop, the operator has had a notice
/// at sixty days, another at thirty, one every day of the final week and an
/// SMS to the owner — **nobody is surprised**, which is the difference between
/// enforcement and an outage.
///
/// The thresholds are **not in this file**. They are `DocumentExpiry` in the
/// domain, shared with the console banner and the compliance queue, because a
/// worker computing `interval '30 days'` in SQL while a screen computes thirty
/// days in Dart is two answers to one question.
///
/// What a block does not do: cancel a departure, void a ticket, or stop the
/// scanner. Everything already sold runs — §3.3's 72-hour grace is what falls
/// out of blocking *sales* rather than *departures*.
final class ComplianceWatch {
  const ComplianceWatch(this._db);

  final Database _db;

  /// One pass over every operator that has a dated document.
  ///
  /// Idempotent by construction: notices are deduped by the outbox's unique
  /// key, and the block and the suspension are set only when they are not
  /// already set. Running it every ten minutes and running it once a day
  /// produce the same state — only the latency of the block differs.
  Future<SweepResult> watch({int limit = 500}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT o.id, o.status::text AS status,
                   o.sales_blocked_at IS NOT NULL AS blocked,
                   k.doc_type, k.expires_at, now() AS at
              FROM operators o
              JOIN kyb_documents k ON k.operator_id = o.id
             WHERE o.status IN ('approved', 'active', 'suspended')
               AND k.expires_at IS NOT NULL
               -- Verified copies only. An unverified upload is a claim, and a
               -- claim is not what a licence is; a rejected one is not the
               -- operator's standing either. Both are a reviewer's problem,
               -- not the calendar's.
               AND k.verified_at IS NOT NULL
               AND k.rejected_reason IS NULL
             ORDER BY o.id
          '''),
          parameters: {},
        );

        // Grouped in Dart rather than reduced in SQL: which copy of a document
        // counts, and what stage it is at, are both `ComplianceStanding`'s to
        // answer — the console read asks the same object the same question.
        final byOperator = <String, List<DocumentExpiry>>{};
        final status = <String, String>{};
        final blocked = <String, bool>{};
        DateTime? at;

        for (final row in rows) {
          final r = row.toColumnMap();
          final id = (r['id'] as Object).toString();
          at ??= (r['at'] as DateTime).toUtc();
          status[id] = r['status'] as String;
          blocked[id] = (r['blocked'] as bool?) ?? false;
          byOperator
              .putIfAbsent(id, () => [])
              .add(
                DocumentExpiry.of(
                  docType: r['doc_type'] as String,
                  expiresAt: (r['expires_at'] as DateTime).toUtc(),
                  // The database's clock, not this container's. A worker whose
                  // host drifted an hour must not block sales an hour early.
                  now: at,
                ),
              );
        }

        var acted = 0;

        for (final entry in byOperator.entries) {
          final operatorId = entry.key;
          final standing = ComplianceStanding.of(entry.value);

          for (final doc in standing.documents) {
            if (doc.noticeTag == null) continue;
            acted += await _queueNotice(tx, operatorId, doc);
          }

          acted += await _enforce(
            tx,
            operatorId: operatorId,
            standing: standing,
            status: status[operatorId]!,
            alreadyBlocked: blocked[operatorId]!,
          );

          if (acted >= limit) break;
        }

        return SweepResult(name: 'compliance.acted', affected: acted);
      });

  /// One notice, at most once per stage — and once per day in the final week,
  /// which is what `noticeTag` carries the date for.
  ///
  /// The uniqueness of `dedupe_key` **is** the delivery guarantee. A
  /// `reminded_at` column would have to be kept in step with a queue row it
  /// cannot see, and the pass would send twice the first time those two
  /// disagreed after a crash.
  Future<int> _queueNotice(
    TxSession tx,
    String operatorId,
    DocumentExpiry doc,
  ) async {
    final queued = await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('operator', @operator, 'compliance.expiring',
                jsonb_build_object(
                  'operatorId', @operator::text,
                  'docType', @doc,
                  'stage', @stage,
                  'daysLeft', @days
                ),
                @key)
        ON CONFLICT (dedupe_key) DO NOTHING
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'doc': TypedValue(Type.text, doc.docType),
        'stage': TypedValue(Type.text, doc.stage.name),
        'days': TypedValue(Type.integer, doc.daysLeft),
        'key': TypedValue(
          Type.text,
          'compliance:$operatorId:${doc.docType}:${doc.noticeTag}',
        ),
      },
    );

    return queued.length;
  }

  /// Sets the block, clears it, and suspends at T+7.
  ///
  /// **The block undoes itself and the suspension does not.** Upload the
  /// renewed certificate, have it verified, and the next pass turns sales back
  /// on with nobody's approval — the calendar put the block there and the
  /// calendar takes it away. A suspension is a status with a reinstatement
  /// procedure and a named human attached (§4), so this pass only ever enters
  /// it.
  Future<int> _enforce(
    TxSession tx, {
    required String operatorId,
    required ComplianceStanding standing,
    required String status,
    required bool alreadyBlocked,
  }) async {
    var acted = 0;

    if (standing.stopsSales && !alreadyBlocked) {
      await tx.execute(
        Sql.named('''
          UPDATE operators
             SET sales_blocked_at = now(), sales_blocked_doc = @doc
           WHERE id = @id AND sales_blocked_at IS NULL
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, operatorId),
          'doc': TypedValue(Type.text, standing.worst!.docType),
        },
      );
      await _audit(
        tx,
        operatorId: operatorId,
        action: 'operator.sales_blocked',
        reason: 'compliance.document_expired:${standing.worst!.docType}',
      );
      acted++;
    } else if (!standing.stopsSales && alreadyBlocked) {
      await tx.execute(
        Sql.named('''
          UPDATE operators
             SET sales_blocked_at = NULL, sales_blocked_doc = NULL
           WHERE id = @id
        '''),
        parameters: {'id': TypedValue(Type.uuid, operatorId)},
      );
      await _audit(
        tx,
        operatorId: operatorId,
        action: 'operator.sales_unblocked',
        reason: 'compliance.documents_current',
      );
      acted++;
    }

    if (standing.suspends && status != 'suspended') {
      await tx.execute(
        Sql.named('''
          UPDATE operators
             SET status = 'suspended',
                 suspended_at = now(),
                 suspended_reason = @reason
           WHERE id = @id AND status <> 'suspended'
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, operatorId),
          'reason': TypedValue(
            Type.text,
            'compliance.document_expired:${standing.worst!.docType}',
          ),
        },
      );
      await _audit(
        tx,
        operatorId: operatorId,
        action: 'operator.suspended',
        reason: 'compliance.document_expired:${standing.worst!.docType}',
      );
      acted++;
    }

    return acted;
  }

  /// `actor_type = 'system'`, `actor_id` NULL — there is no human to
  /// attribute this to, and inventing one would make the trail lie about who
  /// decided. The reason is a key with the document type appended, so the
  /// admin's fiche renders it in the reader's language (ADR-0008).
  Future<void> _audit(
    TxSession tx, {
    required String operatorId,
    required String action,
    required String reason,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO audit_log
        (actor_id, actor_type, action, subject_type, subject_id,
         operator_id, reason)
      VALUES (NULL, 'system', @action, 'operator', @id::text, @id, @reason)
    '''),
    parameters: {
      'id': TypedValue(Type.uuid, operatorId),
      'action': TypedValue(Type.text, action),
      'reason': TypedValue(Type.text, reason),
    },
  );
}
