import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/operator_directory.dart';
import '../db/database.dart';

/// The operator's own row, read under the operator's own scope.
final class PostgresOperatorDirectory implements OperatorDirectory {
  const PostgresOperatorDirectory(this._db);

  final Database _db;

  @override
  Future<CommissionTerm?> commissionFor(String operatorId) => _db.transaction(
    DbScope.tenant(operatorId),
    (tx) async {
      final rows = await tx.execute(
        Sql.named('SELECT commission_bps FROM operators WHERE id = @id'),
        parameters: {'id': TypedValue(Type.uuid, operatorId)},
      );
      if (rows.isEmpty) return null;
      // The column is NOT NULL with a CHECK between 0 and 3000, so a value
      // this constructor would refuse cannot be in the table — and if one
      // ever is, throwing here is right: netting an invented rate against
      // somebody's money is the worse failure.
      return CommissionTerm(rows.first.toColumnMap()['commission_bps'] as int);
    },
  );
}
