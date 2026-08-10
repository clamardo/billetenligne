import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

import '../application/ports/admin_gateway.dart';

/// The real gateway: the shared typed client, nothing more.
///
/// Thin on purpose, exactly like `ApiConsoleGateway`. Retries, trace ids and
/// the offline taxonomy live in `bel_client`, and the `X-Bel-Reason` header
/// is set there too — one place that knows how a reason reaches the server is
/// one place that can be audited for having forgotten.
final class ApiAdminGateway implements AdminGateway {
  const ApiAdminGateway(this._client);

  final BelApiClient _client;

  @override
  Future<AdminIdentityDto> identity() => _client.adminIdentity();

  @override
  Future<List<AdminOperatorDto>> operators({
    Set<String> statuses = const {},
    required String reason,
  }) => _client.adminOperators(statuses: statuses, reason: reason);

  @override
  Future<AdminOperatorDetailDto> operatorDetail(
    String id, {
    required String reason,
  }) => _client.adminOperator(id, reason: reason);

  @override
  Future<AdminOperatorDto> decide({
    required String operatorId,
    required String decision,
    required String reason,
    String? detail,
  }) => _client.decideOperator(
    id: operatorId,
    decision: decision,
    reason: reason,
    detail: detail,
  );

  @override
  Future<AdminOperatorDto> setCommission({
    required String operatorId,
    required int commissionBps,
    required String reason,
  }) => _client.setOperatorCommission(
    id: operatorId,
    commissionBps: commissionBps,
    reason: reason,
  );

  @override
  Future<List<UnresolvedPaymentDto>> unresolvedPayments({
    required String reason,
  }) => _client.unresolvedPayments(reason: reason);

  @override
  Future<UnresolvedPaymentDto> resolvePayment({
    required String intentId,
    required String outcome,
    required String reason,
    String? evidence,
    String? failureCode,
  }) => _client.resolvePayment(
    intentId: intentId,
    outcome: outcome,
    reason: reason,
    evidence: evidence,
    failureCode: failureCode,
  );
}
