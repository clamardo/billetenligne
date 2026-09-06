@Tags(['integration'])
library;

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// An operator's own roles, against a real database.
///
/// The claims here are the ones a Dart map cannot make: that the name is
/// unique **per operator, case-insensitively** — a Postgres unique index, not
/// an application-side check that a race could slip past; that RLS, not just
/// the `WHERE operator_id = @operator` clause, keeps one operator's roles out
/// of another's list; and that deleting a role still worn by an active staff
/// member is refused by a real join against `operator_staff`, not by an
/// in-memory guess about who holds what.
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
  String freshName() => 'ticket_seller_${++seq}';

  test('creating a role writes one row and returns it', () async {
    final name = freshName();
    final created = await console.createCustomRole(
      operatorId: operatorId,
      name: name,
      capabilities: const ['booking.read', 'booking.sell'],
      clonedFromRole: 'vendor',
    );

    expect(created, isNotNull);
    expect(created!.name, name);
    expect(
      created.capabilities,
      unorderedEquals(['booking.read', 'booking.sell']),
    );
    expect(created.clonedFromRole, 'vendor');

    final listed = await console.customRoles(operatorId);
    expect(listed.map((r) => r.id), contains(created.id));
  });

  test('the same name twice, same case, is refused', () async {
    final name = freshName();
    final first = await console.createCustomRole(
      operatorId: operatorId,
      name: name,
      capabilities: const ['booking.read'],
    );
    expect(first, isNotNull);

    final second = await console.createCustomRole(
      operatorId: operatorId,
      name: name,
      capabilities: const ['booking.sell'],
    );
    expect(second, isNull);
  });

  test('the same name in a different case is still refused', () async {
    final name = freshName();
    final first = await console.createCustomRole(
      operatorId: operatorId,
      name: name,
      capabilities: const ['booking.read'],
    );
    expect(first, isNotNull);

    final second = await console.createCustomRole(
      operatorId: operatorId,
      name: name.toUpperCase(),
      capabilities: const ['booking.read'],
    );
    expect(
      second,
      isNull,
      reason: 'operator_custom_roles_operator_id_lower_idx is case-folding',
    );
  });

  test('updateCustomRole renames and replaces the capability set', () async {
    final created = await console.createCustomRole(
      operatorId: operatorId,
      name: freshName(),
      capabilities: const ['booking.read'],
    );

    final renamed = freshName();
    final result = await console.updateCustomRole(
      operatorId: operatorId,
      roleId: created!.id,
      name: renamed,
      capabilities: const ['booking.read', 'booking.sell'],
    );

    expect(result.nameConflict, isFalse);
    expect(result.role, isNotNull);
    expect(result.role!.name, renamed);
    expect(
      result.role!.capabilities,
      unorderedEquals(['booking.read', 'booking.sell']),
    );
  });

  test(
    'updateCustomRole refuses a name already used by another role',
    () async {
      final taken = await console.createCustomRole(
        operatorId: operatorId,
        name: freshName(),
        capabilities: const ['booking.read'],
      );
      final other = await console.createCustomRole(
        operatorId: operatorId,
        name: freshName(),
        capabilities: const ['booking.read'],
      );

      final result = await console.updateCustomRole(
        operatorId: operatorId,
        roleId: other!.id,
        name: taken!.name,
        capabilities: const ['booking.read'],
      );

      expect(result.nameConflict, isTrue);
      expect(result.role, isNull);

      // And the row was not renamed out from under it.
      final listed = await console.customRoles(operatorId);
      expect(listed.firstWhere((r) => r.id == other.id).name, other.name);
    },
  );

  test(
    'updateCustomRole on an unknown id reports neither found nor a conflict',
    () async {
      final result = await console.updateCustomRole(
        operatorId: operatorId,
        roleId: '00000000-0000-0000-0000-000000000000',
        name: freshName(),
        capabilities: const ['booking.read'],
      );
      expect(result.role, isNull);
      expect(result.nameConflict, isFalse);
    },
  );

  test('deleteCustomRole removes an unused role', () async {
    final created = await console.createCustomRole(
      operatorId: operatorId,
      name: freshName(),
      capabilities: const ['booking.read'],
    );

    final deleted = await console.deleteCustomRole(
      operatorId: operatorId,
      roleId: created!.id,
    );
    expect(deleted, isTrue);

    final listed = await console.customRoles(operatorId);
    expect(listed.map((r) => r.id), isNot(contains(created.id)));
  });

  test('deleteCustomRole on an unknown id returns null', () async {
    final deleted = await console.deleteCustomRole(
      operatorId: operatorId,
      roleId: '00000000-0000-0000-0000-000000000000',
    );
    expect(deleted, isNull);
  });

  test(
    'deleteCustomRole refuses a role still worn by an active staff member',
    () async {
      final name = freshName();
      final created = await console.createCustomRole(
        operatorId: operatorId,
        name: name,
        capabilities: const ['booking.read'],
      );

      final account = await fixture.traveller(
        'role${seq}a',
        name: 'Role Holder',
      );
      await console.inviteStaff(
        operatorId: operatorId,
        accountId: account,
        roles: [name],
        stationIds: const [],
      );

      final deleted = await console.deleteCustomRole(
        operatorId: operatorId,
        roleId: created!.id,
      );
      expect(deleted, isFalse);

      // And it is still there, unremoved.
      final listed = await console.customRoles(operatorId);
      expect(listed.map((r) => r.id), contains(created.id));
    },
  );

  test('deleteCustomRole allows it once the last holder is revoked', () async {
    final name = freshName();
    final created = await console.createCustomRole(
      operatorId: operatorId,
      name: name,
      capabilities: const ['booking.read'],
    );

    final account = await fixture.traveller('role${seq}b', name: 'Role Holder');
    final invited = await console.inviteStaff(
      operatorId: operatorId,
      accountId: account,
      roles: [name],
      stationIds: const [],
    );

    await console.revokeStaff(
      operatorId: operatorId,
      staffId: invited.staff!.id,
    );

    final deleted = await console.deleteCustomRole(
      operatorId: operatorId,
      roleId: created!.id,
    );
    expect(deleted, isTrue);
  });

  test(
    'RLS keeps one operator from ever seeing another operator\'s roles',
    () async {
      final otherRows = await fixture.rows('''
        INSERT INTO operators (code, legal_name, trading_name, status,
                               market_code)
        VALUES ('OTH-${DateTime.now().microsecondsSinceEpoch}',
                'Autre SARL', 'Autre', 'active', 'CG')
        RETURNING id
      ''');
      final otherOperatorId = otherRows.single['id'] as String;

      final created = await console.createCustomRole(
        operatorId: otherOperatorId,
        name: freshName(),
        capabilities: const ['booking.read'],
      );

      final theirs = await console.customRoles(otherOperatorId);
      expect(theirs.map((r) => r.id), contains(created!.id));

      final ours = await console.customRoles(operatorId);
      expect(ours.map((r) => r.id), isNot(contains(created.id)));

      // And this operator cannot delete a row RLS will not even show it.
      final deleted = await console.deleteCustomRole(
        operatorId: operatorId,
        roleId: created.id,
      );
      expect(deleted, isNull);
    },
  );
}
