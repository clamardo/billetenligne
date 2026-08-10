import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/operator_directory.dart';

/// Operator terms held in memory, for tests and for the demo server.
final class MemoryOperatorDirectory implements OperatorDirectory {
  MemoryOperatorDirectory({Map<String, CommissionTerm>? commissions})
    : _commissions = {...?commissions};

  final Map<String, CommissionTerm> _commissions;

  /// Sets what one operator negotiated. Named `agree` rather than `set`
  /// because that is what it models — the number arrives from a contract, not
  /// from a config file.
  void agree(String operatorId, CommissionTerm term) =>
      _commissions[operatorId] = term;

  @override
  Future<CommissionTerm?> commissionFor(String operatorId) async =>
      _commissions[operatorId];
}
