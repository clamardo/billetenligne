import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/review_queue.dart';
import '../db/database.dart';

/// The review queue, as the worker sees it.
///
/// Runs under [DbScope.worker] — cross-tenant, and **without an actor**. That
/// is the whole shape of an automatic approval: nobody decided, so the audit
/// row carries `actor_type = 'system'` and a NULL `actor_id`, and a reviewer
/// reading the trail six months later can tell a policy from a person.
final class PostgresReviewQueue implements ReviewQueue {
  const PostgresReviewQueue(this._db);

  final Database _db;

  @override
  Future<List<PendingApplication>> awaitingAssessment({int limit = 50}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT o.id, o.code,
                   o.legal_name, o.trading_name, o.rccm_number, o.tax_id,
                   a.legal_form, a.registered_address, a.year_founded,
                   a.owner_name, a.owner_id_type, a.owner_id_number,
                   a.owner_phone, a.owner_email,
                   a.transport_licence_number, a.transport_licence_expires,
                   a.insurer_name, a.fleet_insurance_expires,
                   a.routes_served, a.fleet_size, a.station_count,
                   a.daily_departures,
                   a.settlement_kind, a.settlement_account_name,
                   a.settlement_account_ref, a.agreement_accepted_at,
                   -- Same registration number, or the same name written the
                   -- same way. Deliberately crude: this flag sends the file
                   -- to a person, and a person is far better at telling a
                   -- re-application from a clone than any comparison here.
                   EXISTS (
                     SELECT 1 FROM operators d
                      WHERE d.id <> o.id
                        AND ((d.rccm_number IS NOT NULL
                              AND o.rccm_number IS NOT NULL
                              AND upper(trim(d.rccm_number))
                                  = upper(trim(o.rccm_number)))
                          OR lower(trim(d.legal_name))
                             = lower(trim(o.legal_name)))
                   ) AS duplicate,
                   -- The same person, on a company that ended badly. §5.3
                   -- keeps that history precisely so it can be seen here.
                   EXISTS (
                     SELECT 1
                       FROM operator_applications pa
                       JOIN operators p ON p.id = pa.operator_id
                      WHERE p.id <> o.id
                        AND pa.applicant_user_id = a.applicant_user_id
                        AND p.status IN ('offboarded', 'rejected')
                   ) AS prior_offboarding
              FROM operators o
              JOIN operator_applications a ON a.operator_id = o.id
             WHERE o.status = 'under_review'
               AND a.submitted_at IS NOT NULL
               AND o.risk_assessed_at IS NULL
             ORDER BY a.submitted_at
             LIMIT @limit
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return [for (final row in rows) _pending(row.toColumnMap())];
      });

  @override
  Future<void> record({
    required String operatorId,
    required RiskBand band,
    required List<String> reasons,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    await tx.execute(
      Sql.named('''
        UPDATE operators
           SET risk_band = @band,
               risk_reasons = @reasons,
               risk_assessed_at = now()
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, operatorId),
        'band': TypedValue(Type.text, band.name),
        'reasons': TypedValue(Type.textArray, reasons),
      },
      ignoreRows: true,
    );
  });

  @override
  Future<bool> approve({required String operatorId}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        // Conditional on the state we assessed. A reviewer who reached this
        // application first wins the race, and that is the safe direction for
        // it to go: a person's decision is never overwritten by a pass.
        final moved = await tx.execute(
          Sql.named('''
            UPDATE operators
               SET status = 'active',
                   approved_at = COALESCE(approved_at, now())
             WHERE id = @id AND status = 'under_review'
            RETURNING id
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );

        if (moved.isEmpty) return false;

        // Activation is the moment an application becomes a business, and
        // this is what makes that true rather than ceremonial — the same
        // statement the platform console runs, because an operator approved
        // by a pass and one approved by a person must arrive at the same
        // place.
        await tx.execute(
          Sql.named('''
            INSERT INTO operator_staff (operator_id, user_id, roles,
                                        accepted_at)
            SELECT a.operator_id, a.applicant_user_id, ARRAY['org_owner'],
                   now()
              FROM operator_applications a
             WHERE a.operator_id = @id
            ON CONFLICT (operator_id, user_id) DO NOTHING
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
          ignoreRows: true,
        );

        await tx.execute(
          Sql.named('''
            INSERT INTO audit_log
              (actor_id, actor_type, action, subject_type, subject_id,
               operator_id, reason, before_state, after_state)
            VALUES (NULL, 'system', 'operator.approved', 'operator',
                    @id::text, @id, 'onboarding.auto_approved',
                    '{"status":"under_review"}'::jsonb,
                    '{"status":"active"}'::jsonb)
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
          ignoreRows: true,
        );

        // Told, not left to notice. Somebody who submitted an application on
        // Tuesday and heard nothing assumes it is still waiting.
        await tx.execute(
          Sql.named('''
            INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                                dedupe_key)
            VALUES ('operator', @id, 'operator.approved',
                    jsonb_build_object('operatorId', @id::text),
                    'operator.approved:' || @id::text)
            ON CONFLICT (dedupe_key) DO NOTHING
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
          ignoreRows: true,
        );

        return true;
      });

  static PendingApplication _pending(Map<String, dynamic> r) =>
      PendingApplication(
        operatorId: (r['id'] as Object).toString(),
        code: (r['code'] as String?) ?? '',
        legalName: (r['legal_name'] as String?) ?? '',
        duplicate: (r['duplicate'] as bool?) ?? false,
        priorOffboarding: (r['prior_offboarding'] as bool?) ?? false,
        facts: ApplicationFacts(
          legalName: r['legal_name'] as String?,
          tradingName: r['trading_name'] as String?,
          rccmNumber: r['rccm_number'] as String?,
          taxId: r['tax_id'] as String?,
          legalForm: r['legal_form'] as String?,
          registeredAddress: r['registered_address'] as String?,
          yearFounded: r['year_founded'] as int?,
          ownerName: r['owner_name'] as String?,
          ownerIdType: r['owner_id_type'] as String?,
          ownerIdNumber: r['owner_id_number'] as String?,
          ownerPhone: r['owner_phone'] as String?,
          ownerEmail: r['owner_email'] as String?,
          transportLicenceNumber: r['transport_licence_number'] as String?,
          transportLicenceExpires: _date(r['transport_licence_expires']),
          insurerName: r['insurer_name'] as String?,
          fleetInsuranceExpires: _date(r['fleet_insurance_expires']),
          routesServed: r['routes_served'] as String?,
          fleetSize: r['fleet_size'] as int?,
          stationCount: r['station_count'] as int?,
          dailyDepartures: r['daily_departures'] as int?,
          settlementKind: r['settlement_kind'] as String?,
          settlementAccountName: r['settlement_account_name'] as String?,
          settlementAccountRef: r['settlement_account_ref'] as String?,
          agreementAccepted: r['agreement_accepted_at'] != null,
        ),
      );

  static DateTime? _date(Object? v) => switch (v) {
    DateTime d => DateTime.utc(d.year, d.month, d.day),
    String s => DateTime.tryParse(s),
    _ => null,
  };
}
