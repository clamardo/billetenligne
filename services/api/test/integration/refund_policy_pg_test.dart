@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Refund policies, against a real database.
///
/// Every claim here is a claim about a *constraint* or a *grant*, which is
/// exactly the class of claim a fake cannot make. ADR-0015 rule 1 — a booking
/// is judged by the version it was sold under, forever — is not a rule the
/// adapter enforces; it is a rule the schema enforces and the adapter obeys.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;
  late PostgresBookingStore bookings;
  late String operatorId;
  late String staffId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(11)),
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('policy-actor', name: 'Owner');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  RefundPolicy tiered(List<(int, int)> bands) => RefundPolicy(
    id: 'pending',
    version: 0,
    tiers: [
      for (final (hours, bps) in bands)
        RefundTier(
          minLeadTime: Duration(hours: hours),
          rateBps: bps,
        ),
    ],
  );

  test('saving the same name twice writes a version, never an edit', () async {
    final first = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Souple',
      policy: tiered([(48, 10000), (24, 5000)]),
      actorUserId: staffId,
    );
    final second = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Souple',
      policy: tiered([(48, 9000)]),
      actorUserId: staffId,
    );

    // Same policy, next version — so a booking sold under v1 can still
    // resolve v1's terms after the operator has written v2.
    expect(second.id, first.id);
    expect(first.version, 1);
    expect(second.version, 2);

    final listed = await console.refundPolicies(operatorId);
    final souple = listed.where((p) => p.name == 'Souple');
    expect(souple, hasLength(2));
    // Newest first, because that is the one being read nine times in ten.
    expect(souple.first.version, 2);
    expect(souple.first.policy.tiers.single.rateBps, 9000);
    expect(souple.last.policy.tiers, hasLength(2));
  });

  test('a stored policy comes back exactly as it went in', () async {
    const written = RefundPolicy(
      id: 'pending',
      version: 0,
      tiers: [
        RefundTier(
          minLeadTime: Duration(hours: 72),
          rateBps: 10000,
          flatFeeMinor: 500,
        ),
        RefundTier(minLeadTime: Duration(minutes: 90), rateBps: 2500),
      ],
      destination: RefundDestination.agencyCash,
      processingWindow: Duration(hours: 24),
      refundServiceFee: true,
      nonRefundableFareCodes: {'group', 'promo'},
    );

    final saved = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Complète',
      policy: written,
      actorUserId: staffId,
    );

    final back = saved.policy;
    expect(back.tiers.first.flatFeeMinor, 500);
    // Ninety minutes, not "about two hours". A wire format that rounded here
    // would quietly move the band an operator chose.
    expect(back.tiers.last.minLeadTime, const Duration(minutes: 90));
    expect(back.destination, RefundDestination.agencyCash);
    expect(back.processingWindow, const Duration(hours: 24));
    expect(back.refundServiceFee, isTrue);
    expect(back.nonRefundableFareCodes, {'group', 'promo'});
  });

  test('the database refuses to rewrite a stored policy', () async {
    final saved = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Immuable',
      policy: tiered([(24, 10000)]),
      actorUserId: staffId,
    );

    // Not a rule the adapter follows — a rule the adapter *cannot break*.
    // 0014 revoked UPDATE, so an adapter that tried to edit in place raises
    // instead of silently changing what somebody already paid for.
    await expectLater(
      db.transaction(DbScope.tenant(operatorId), (tx) async {
        await tx.execute(
          Sql.named('''
            UPDATE refund_policies SET name = 'edited'
             WHERE id = @id AND version = @version
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, saved.id),
            'version': TypedValue(Type.integer, saved.version),
          },
          ignoreRows: true,
        );
      }),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'a default points at one version, and only this tenant may set it',
    () async {
      final v1 = await console.saveRefundPolicy(
        operatorId: operatorId,
        name: 'Par défaut',
        policy: tiered([(48, 10000)]),
        actorUserId: staffId,
      );
      final v2 = await console.saveRefundPolicy(
        operatorId: operatorId,
        name: 'Par défaut',
        policy: tiered([(48, 5000)]),
        actorUserId: staffId,
      );

      final set = await console.setDefaultRefundPolicy(
        operatorId: operatorId,
        policyId: v1.id,
        version: v1.version,
      );
      expect(set!.version, 1);

      final listed = await console.refundPolicies(operatorId);
      final defaults = listed.where((p) => p.isDefault);
      // Exactly one version of one policy, ever.
      expect(defaults, hasLength(1));
      expect(defaults.single.version, 1);

      // A version that does not exist is a refusal, not a stored dangling id.
      expect(
        await console.setDefaultRefundPolicy(
          operatorId: operatorId,
          policyId: v2.id,
          version: 99,
        ),
        isNull,
      );

      // And another tenant naming this policy learns nothing: RLS made it
      // invisible, so the answer is "no such policy" rather than a leak.
      expect(
        await console.setDefaultRefundPolicy(
          operatorId: '22222222-2222-2222-2222-222222222222',
          policyId: v1.id,
          version: v1.version,
        ),
        isNull,
      );

      // Clearing it is a legitimate answer: no policy means no self-service
      // refund, not a hidden one.
      expect(
        await console.setDefaultRefundPolicy(
          operatorId: operatorId,
          policyId: null,
          version: null,
        ),
        isNull,
      );
      expect(
        (await console.refundPolicies(operatorId)).where((p) => p.isDefault),
        isEmpty,
      );
    },
  );

  test('a booking copies the terms it was sold under', () async {
    final policy = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Vente',
      policy: tiered([(24, 10000)]),
      actorUserId: staffId,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: policy.id,
      version: policy.version,
    );

    final departureId = await fixture.departure(seatLabels: ['1A', '1B']);
    final sold = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: '1A',
      name: 'Aline M.',
    );

    final stamped = await fixture.bookingPolicy(sold.ref.value);
    expect(stamped.id, policy.id);
    expect(stamped.version, 1);

    // Now the operator writes better terms and points the default at them.
    // The booking already sold must not move.
    final v2 = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Vente',
      policy: tiered([(24, 5000)]),
      actorUserId: staffId,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: v2.id,
      version: v2.version,
    );

    expect(
      (await fixture.bookingPolicy(sold.ref.value)).version,
      1,
      reason: 'ADR-0015 rule 1: yesterday\'s customer keeps yesterday\'s terms',
    );

    // And the console can say how many people that is before the operator
    // wonders whether they can "just change it".
    final listed = await console.refundPolicies(operatorId);
    final v1Row = listed.firstWhere((p) => p.id == policy.id && p.version == 1);
    expect(v1Row.bookingCount, greaterThanOrEqualTo(1));
  });

  test('the change terms are stored and read back with the version', () async {
    final saved = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Reportable',
      policy: tiered([(24, 10000)]),
      change: const ChangePolicy(
        freeBefore: Duration(hours: 48),
        feeBps: 1500,
        cutoff: Duration(hours: 6),
      ),
      actorUserId: staffId,
    );

    expect(saved.change.freeBefore, const Duration(hours: 48));
    expect(saved.change.feeBps, 1500);
    expect(saved.change.cutoff, const Duration(hours: 6));

    // And on the way back out of the list, which is the read the console
    // actually makes — a RETURNING that worked and a SELECT that forgot the
    // columns is exactly the drift this asserts against.
    final listed = await console.refundPolicies(operatorId);
    final row = listed.firstWhere((p) => p.name == 'Reportable');
    expect(row.change.freeBefore, const Duration(hours: 48));
    expect(row.change.feeBps, 1500);
    expect(row.change.cutoff, const Duration(hours: 6));
  });

  test('a policy written without an answer carries D-08', () async {
    final saved = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Silencieuse',
      policy: tiered([(24, 10000)]),
      actorUserId: staffId,
    );

    // The platform's own numbers, not nulls: an operator who never opened
    // the question still sells under terms the traveller can read.
    expect(saved.change.freeBefore, const Duration(hours: 24));
    expect(saved.change.feeBps, 1000);
    expect(saved.change.cutoff, const Duration(hours: 2));
    expect(saved.change.isWellFormed, isTrue);
  });

  test(
    'the database refuses change terms that contradict each other',
    () async {
      // A cutoff later than the free window charges a fee inside a window the
      // same policy has already refused. Every column is individually fine.
      await expectLater(
        db.transaction(DbScope.tenant(operatorId), (tx) async {
          await tx.execute(
            Sql.named('''
            INSERT INTO refund_policies
              (id, version, operator_id, name, tiers, change_free_hours,
               change_cutoff_hours, created_by)
            VALUES (gen_random_uuid(), 1, @operator, 'Contradictoire',
                    '[]'::jsonb, 2, 48, @actor)
          '''),
            parameters: {
              'operator': TypedValue(Type.uuid, operatorId),
              'actor': TypedValue(Type.uuid, staffId),
            },
          );
        }),
        throwsA(anything),
      );
    },
  );
}
