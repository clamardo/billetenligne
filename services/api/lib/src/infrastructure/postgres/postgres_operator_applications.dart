import 'dart:math';

import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/operator_applications.dart';
import '../db/database.dart';

/// Self-signup, on the **public** surface.
///
/// Every statement here runs as `bel_public` with the applicant's verified
/// user id, which is the point rather than an inconvenience: the caller is a
/// member of the public who belongs to no tenant, and the alternative — doing
/// this work under the platform role because it is easier — would run an
/// internet request with our own back office's authority.
///
/// What that costs is one ergonomic quirk, and it is worth stating where it
/// is felt: `INSERT … RETURNING id` is unavailable, because RETURNING
/// evaluates the SELECT policy and the applicant's read is granted by the
/// application row that does not exist yet. So [start] generates the id.
final class PostgresOperatorApplications implements OperatorApplications {
  PostgresOperatorApplications(this._db, {Random? random})
    : _random = random ?? Random.secure();

  final Database _db;
  final Random _random;

  @override
  Future<OperatorApplication?> mine({required String userId}) =>
      _db.transaction(DbScope.traveller(userId), (tx) => _mine(tx, userId));

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> start({
    required String userId,
    required String legalName,
    required String marketCode,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final existing = await _mine(tx, userId);

    // One in flight at a time. A rejected application is deliberately not a
    // blocker — §2.3 allows re-application, and the thirty-day wait is a
    // decision somebody explains, not a unique violation.
    if (existing != null && existing.status != 'rejected') {
      return const Err(ApplicationRefusal.alreadyApplied);
    }

    final id = await _newId(tx);

    // The code is a stem plus three characters, and the stem is the first six
    // letters of the name — which on this market is a genuine collision
    // source rather than a theoretical one: half the companies on the
    // Brazzaville–Pointe-Noire road are called *Trans* something. So a
    // duplicate is **retried**, not raised. The alternative is a 500 on the
    // signup form of the second company to be named like the first, and a
    // support conversation nobody can explain.
    //
    // A savepoint per attempt because a failed statement poisons the whole
    // transaction otherwise, and everything after this insert — the
    // application row, the applicant's read — is part of it.
    var attempts = 0;
    while (true) {
      attempts++;
      await tx.execute('SAVEPOINT operator_code');
      try {
        await tx.execute(
          Sql.named('''
            INSERT INTO operators (id, code, legal_name, market_code, status)
            VALUES (@id, @code, @name, @market, 'application_draft')
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, id),
            'code': operatorCodeFrom(legalName, _entropy()),
            'name': legalName.trim(),
            'market': marketCode,
          },
          ignoreRows: true,
        );
        break;
      } on ServerException catch (e) {
        // 23505 is a unique violation. Anything else is not ours to swallow.
        if (e.code != '23505' || attempts >= 8) rethrow;
        await tx.execute('ROLLBACK TO SAVEPOINT operator_code');
      }
    }

    await tx.execute(
      Sql.named('''
        INSERT INTO operator_applications (operator_id, applicant_user_id)
        VALUES (@id, @user)
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'user': TypedValue(Type.uuid, userId),
      },
    );

    final started = await _mine(tx, userId);
    return started == null
        ? const Err(ApplicationRefusal.noApplication)
        : Ok(started);
  });

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> save({
    required String userId,
    required ApplicationFacts facts,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final current = await _mine(tx, userId);
    if (current == null) return const Err(ApplicationRefusal.noApplication);
    if (!current.isEditable) return const Err(ApplicationRefusal.locked);

    // The four columns the public role is granted, and no others. The grant
    // in migration 0015 is what actually enforces that; this statement simply
    // does not try.
    await tx.execute(
      Sql.named('''
        UPDATE operators
           SET legal_name = COALESCE(@name, legal_name),
               trading_name = @trading,
               rccm_number = @rccm,
               tax_id = @tax
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, current.operatorId),
        'name': _clean(facts.legalName),
        'trading': _clean(facts.tradingName),
        'rccm': _clean(facts.rccmNumber),
        'tax': _clean(facts.taxId),
      },
    );

    await tx.execute(
      Sql.named('''
        UPDATE operator_applications
           SET legal_form = @legalForm,
               registered_address = @address,
               year_founded = @founded,
               owner_name = @ownerName,
               owner_id_type = @ownerIdType,
               owner_id_number = @ownerIdNumber,
               owner_phone = @ownerPhone,
               owner_email = @ownerEmail,
               transport_licence_number = @licence,
               transport_licence_expires = @licenceExpires,
               insurer_name = @insurer,
               fleet_insurance_expires = @insuranceExpires,
               routes_served = @routes,
               fleet_size = @fleet,
               station_count = @stations,
               daily_departures = @departures,
               settlement_kind = @settlementKind,
               settlement_account_name = @settlementName,
               settlement_account_ref = @settlementRef,
               agreement_accepted_at = CASE
                 WHEN @agreed THEN COALESCE(agreement_accepted_at, now())
                 ELSE NULL
               END,
               updated_at = now()
         WHERE operator_id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, current.operatorId),
        'legalForm': _clean(facts.legalForm),
        'address': _clean(facts.registeredAddress),
        'founded': facts.yearFounded,
        'ownerName': _clean(facts.ownerName),
        'ownerIdType': _clean(facts.ownerIdType),
        'ownerIdNumber': _clean(facts.ownerIdNumber),
        'ownerPhone': _clean(facts.ownerPhone),
        'ownerEmail': _clean(facts.ownerEmail),
        'licence': _clean(facts.transportLicenceNumber),
        'licenceExpires': _date(facts.transportLicenceExpires),
        'insurer': _clean(facts.insurerName),
        'insuranceExpires': _date(facts.fleetInsuranceExpires),
        'routes': _clean(facts.routesServed),
        'fleet': facts.fleetSize,
        'stations': facts.stationCount,
        'departures': facts.dailyDepartures,
        'settlementKind': _clean(facts.settlementKind),
        'settlementName': _clean(facts.settlementAccountName),
        'settlementRef': _clean(facts.settlementAccountRef),
        'agreed': facts.agreementAccepted,
      },
    );

    final saved = await _mine(tx, userId);
    return saved == null
        ? const Err(ApplicationRefusal.noApplication)
        : Ok(saved);
  });

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> submit({
    required String userId,
    required DateTime asOf,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final current = await _mine(tx, userId);
    if (current == null) return const Err(ApplicationRefusal.noApplication);
    if (!current.isEditable) return const Err(ApplicationRefusal.locked);

    // The client already ran this exact check — the rule lives in the domain
    // and both sides compile it (ADR-0004). Running it again here is not
    // duplication: it is the difference between a rule and a suggestion.
    if (!current.facts.isSubmittable(asOf: asOf)) {
      return const Err(ApplicationRefusal.incomplete);
    }

    await tx.execute(
      Sql.named('''
        UPDATE operator_applications
           SET submitted_at = now(), updated_at = now()
         WHERE operator_id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, current.operatorId)},
    );

    // `status` is not writable by this role, and this is the one transition
    // an applicant genuinely causes. It happens through a SECURITY DEFINER
    // function whose whole body is one UPDATE with one legal source state and
    // one legal target — a hole the width of exactly this transition.
    await tx.execute(
      Sql.named('SELECT submit_operator_application(@id)'),
      parameters: {'id': TypedValue(Type.uuid, current.operatorId)},
    );

    final submitted = await _mine(tx, userId);
    return submitted == null
        ? const Err(ApplicationRefusal.noApplication)
        : Ok(submitted);
  });

  Future<OperatorApplication?> _mine(TxSession tx, String userId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT o.id, o.code, o.legal_name, o.trading_name, o.rccm_number,
               o.tax_id, o.status::text AS status, o.created_at,
               o.suspended_reason,
               a.legal_form, a.registered_address, a.year_founded,
               a.owner_name, a.owner_id_type, a.owner_id_number,
               a.owner_phone, a.owner_email,
               a.transport_licence_number, a.transport_licence_expires,
               a.insurer_name, a.fleet_insurance_expires,
               a.routes_served, a.fleet_size, a.station_count,
               a.daily_departures,
               a.settlement_kind, a.settlement_account_name,
               a.settlement_account_ref,
               a.agreement_accepted_at, a.submitted_at
          FROM operator_applications a
          JOIN operators o ON o.id = a.operator_id
         WHERE a.applicant_user_id = @user
         ORDER BY a.created_at DESC
         LIMIT 1
      '''),
      parameters: {'user': TypedValue(Type.uuid, userId)},
    );

    if (rows.isEmpty) return null;
    final r = rows.first.toColumnMap();

    return OperatorApplication(
      operatorId: r['id'].toString(),
      code: r['code'] as String,
      status: r['status'] as String,
      createdAt: r['created_at'] as DateTime,
      submittedAt: r['submitted_at'] as DateTime?,
      decisionReason: r['suspended_reason'] as String?,
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
        transportLicenceExpires: _readDate(r['transport_licence_expires']),
        insurerName: r['insurer_name'] as String?,
        fleetInsuranceExpires: _readDate(r['fleet_insurance_expires']),
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
  }

  /// A uuid from the database rather than from Dart, because this package
  /// carries no uuid dependency and `gen_random_uuid()` reads no table — so
  /// it is the one statement here that no policy has an opinion about.
  Future<String> _newId(TxSession tx) async {
    final rows = await tx.execute('SELECT gen_random_uuid()');
    return rows.first.first.toString();
  }

  String _entropy() {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    return [
      for (var i = 0; i < 3; i++) alphabet[_random.nextInt(alphabet.length)],
    ].join();
  }

  static String? _clean(String? v) {
    final t = (v ?? '').trim();
    return t.isEmpty ? null : t;
  }

  /// Postgres `DATE` wants a date, and the wizard's picker hands us an
  /// instant. Truncated here rather than in the DTO, because "expires on the
  /// 30th" is a day in the operator's country and not a moment in UTC.
  static TypedValue? _date(DateTime? v) => v == null
      ? null
      : TypedValue(Type.date, DateTime.utc(v.year, v.month, v.day));

  static DateTime? _readDate(Object? v) => switch (v) {
    DateTime d => DateTime.utc(d.year, d.month, d.day),
    String s => DateTime.tryParse(s),
    _ => null,
  };
}
