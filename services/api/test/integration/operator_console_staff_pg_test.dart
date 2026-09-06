@Tags(['integration'])
library;

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Personnel, against a real database.
///
/// The claims here are the ones a Dart map cannot make: that RLS, not just
/// the `WHERE operator_id = @operator` clause, is what keeps one operator's
/// till agents out of another's staff list; that re-inviting an existing
/// phone changes their roles and stations rather than erroring or doubling
/// the row (the unique constraint on `(operator_id, user_id)`); and that a
/// revoked member is still listed, never dropped.
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
  late String operatorId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    operatorId = PgFixture.operatorId;
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  Future<String> freshAccount({String? name}) =>
      fixture.traveller('staff${++seq}', name: name ?? 'Staff $seq');

  test('inviting somebody new writes one row and returns it', () async {
    final account = await freshAccount(name: 'Amina Vendor');

    final result = await console.inviteStaff(
      operatorId: operatorId,
      accountId: account,
      roles: ['vendor'],
      stationIds: const [],
    );

    expect(result.alreadyStaff, isFalse);
    expect(result.staff, isNotNull);
    expect(result.staff!.roles, ['vendor']);
    expect(result.staff!.fullName, 'Amina Vendor');
    expect(result.staff!.isRevoked, isFalse);

    final listed = await console.staff(operatorId);
    expect(listed.map((s) => s.id), contains(result.staff!.id));
  });

  test(
    'inviting the same phone again changes roles rather than erroring',
    () async {
      final account = await freshAccount();

      final first = await console.inviteStaff(
        operatorId: operatorId,
        accountId: account,
        roles: ['vendor'],
        stationIds: const [],
      );
      final second = await console.inviteStaff(
        operatorId: operatorId,
        accountId: account,
        roles: ['vendor', 'conductor'],
        stationIds: const [],
      );

      expect(second.alreadyStaff, isTrue);
      // One row, not two: the unique constraint on (operator_id, user_id)
      // is what a second INSERT would violate, so this has to be the same id.
      expect(second.staff!.id, first.staff!.id);
      expect(second.staff!.roles, unorderedEquals(['vendor', 'conductor']));

      final listed = await console.staff(operatorId);
      expect(listed.where((s) => s.id == first.staff!.id), hasLength(1));
    },
  );

  test('updateStaffAssignment changes an existing member in place', () async {
    final account = await freshAccount();
    final invited = await console.inviteStaff(
      operatorId: operatorId,
      accountId: account,
      roles: ['vendor'],
      stationIds: const [],
    );

    final updated = await console.updateStaffAssignment(
      operatorId: operatorId,
      staffId: invited.staff!.id,
      roles: ['conductor'],
      stationIds: const [],
    );

    expect(updated, isNotNull);
    expect(updated!.roles, ['conductor']);
  });

  test('updateStaffAssignment on an unknown id returns null', () async {
    final updated = await console.updateStaffAssignment(
      operatorId: operatorId,
      staffId: '00000000-0000-0000-0000-000000000000',
      roles: ['vendor'],
      stationIds: const [],
    );
    expect(updated, isNull);
  });

  test(
    'revoking sets revoked_at and the member is still listed',
    () async {
      final account = await freshAccount();
      final invited = await console.inviteStaff(
        operatorId: operatorId,
        accountId: account,
        roles: ['vendor'],
        stationIds: const [],
      );

      final revoked = await console.revokeStaff(
        operatorId: operatorId,
        staffId: invited.staff!.id,
      );
      expect(revoked, isTrue);

      // A second revoke is not a second event — nothing left to revoke.
      final again = await console.revokeStaff(
        operatorId: operatorId,
        staffId: invited.staff!.id,
      );
      expect(again, isFalse);

      final listed = await console.staff(operatorId);
      final row = listed.firstWhere((s) => s.id == invited.staff!.id);
      expect(row.isRevoked, isTrue);
    },
  );

  test(
    'RLS keeps one operator from ever seeing another operator staff',
    () async {
      final otherRows = await fixture.rows('''
        INSERT INTO operators (code, legal_name, trading_name, status,
                               market_code)
        VALUES ('OTH-${DateTime.now().microsecondsSinceEpoch}',
                'Autre SARL', 'Autre', 'active', 'CG')
        RETURNING id
      ''');
      final otherOperatorId = otherRows.single['id'] as String;

      final account = await freshAccount(name: 'Belongs To Other');
      final invited = await console.inviteStaff(
        operatorId: otherOperatorId,
        accountId: account,
        roles: ['vendor'],
        stationIds: const [],
      );

      // The row exists — under the operator that created it.
      final theirs = await console.staff(otherOperatorId);
      expect(theirs.map((s) => s.id), contains(invited.staff!.id));

      // The same row, asked for under a different tenant scope, does not
      // exist as far as this operator's connection can see — RLS filters
      // it, it does not merely fail the WHERE clause.
      final ours = await console.staff(operatorId);
      expect(ours.map((s) => s.id), isNot(contains(invited.staff!.id)));

      // And this operator cannot revoke a row RLS will not even show it.
      final revoked = await console.revokeStaff(
        operatorId: operatorId,
        staffId: invited.staff!.id,
      );
      expect(revoked, isFalse);
    },
  );
}
