import 'package:bel_admin/src/application/ports/admin_gateway.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// A gateway the test drives directly, and which records what it was asked.
///
/// It records the **reason** on every call, because that is the property this
/// surface exists to have: an action with no attributable actor and no stated
/// reason is the thing ADR-0011 forbids, and a test that only checks the
/// screen renders would not notice it going missing.
final class ScriptedAdmin implements AdminGateway {
  ScriptedAdmin({required this.capabilities});

  List<String> capabilities;
  ApiFailure? identityFailure;

  List<AdminOperatorDto> roster = const [];
  List<UnresolvedPaymentDto> queue = const [];
  List<PayoutRunDto> runs = const [];
  FunnelDto funnelResult = const FunnelDto(days: []);
  AdminOperatorDetailDto? file;

  /// `call:argument:…:reason`, in order.
  final calls = <String>[];

  @override
  Future<AdminIdentityDto> identity() async {
    if (identityFailure != null) throw identityFailure!;
    return AdminIdentityDto(
      userId: 'u-1',
      role: 'operations',
      capabilities: capabilities,
      fullName: 'Sarah N.',
    );
  }

  @override
  Future<List<AdminOperatorDto>> operators({
    Set<String> statuses = const {},
    required String reason,
  }) async {
    calls.add('operators:${statuses.length}:$reason');
    return roster;
  }

  @override
  Future<AdminOperatorDetailDto> operatorDetail(
    String id, {
    required String reason,
  }) async {
    calls.add('detail:$id:$reason');
    return file!;
  }

  @override
  Future<AdminOperatorDto> decide({
    required String operatorId,
    required String decision,
    required String reason,
    String? detail,
  }) async {
    calls.add('decide:$operatorId:$decision:$reason:${detail ?? ''}');
    return roster.first;
  }

  @override
  Future<AdminOperatorDto> setCommission({
    required String operatorId,
    required int commissionBps,
    required String reason,
  }) async {
    calls.add('commission:$operatorId:$commissionBps:$reason');
    return roster.first;
  }

  @override
  Future<List<UnresolvedPaymentDto>> unresolvedPayments({
    required String reason,
  }) async {
    calls.add('payments:$reason');
    return queue;
  }

  @override
  Future<FunnelDto> funnel({
    required String reason,
    int days = 14,
    String? operatorId,
  }) async {
    calls.add('funnel:$days:$reason');
    return funnelResult;
  }

  /// Nothing dated by default. A test that wants the calendar sets this.
  List<ComplianceDto> calendar = const [];

  @override
  Future<List<ComplianceDto>> compliance({
    required String reason,
    int withinDays = 60,
  }) async {
    calls.add('compliance:$withinDays:$reason');
    return calendar;
  }

  @override
  Future<List<PayoutRunDto>> payouts({required String reason}) async {
    calls.add('payouts:$reason');
    return runs;
  }

  @override
  Future<PayoutRunDto> preparePayout({
    required String operatorId,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String reason,
  }) async {
    calls.add('prepare:$operatorId:$reason');
    return runs.first;
  }

  @override
  Future<PayoutRunDto> decidePayout({
    required String runId,
    required String decision,
    required String reason,
    String? paymentReference,
  }) async {
    calls.add('payout:$runId:$decision:$reason:${paymentReference ?? ''}');
    return payoutRun(
      state: decision == 'release' ? 'paid' : 'approved',
      reference: paymentReference,
    );
  }

  @override
  Future<UnresolvedPaymentDto> resolvePayment({
    required String intentId,
    required String outcome,
    required String reason,
    String? evidence,
    String? failureCode,
  }) async {
    calls.add(
      'resolve:$intentId:$outcome:$reason:${evidence ?? ''}:'
      '${failureCode ?? ''}',
    );
    return queue.first;
  }
}

PayoutRunDto payoutRun({
  String state = 'draft',
  int net = 3516000,
  String? reference,
}) => PayoutRunDto(
  id: 'pay-1',
  operatorId: 'op-1',
  operatorName: 'Océan du Nord',
  periodStart: DateTime.utc(2026, 8, 1),
  periodEnd: DateTime.utc(2026, 8, 8),
  onlineSalesCount: 412,
  onlineGross: const Money.xaf(3708000),
  cashSalesCount: 188,
  cashGross: const Money.xaf(1692000),
  commission: const Money.xaf(185400),
  serviceFees: const Money.xaf(180000),
  refunds: const Money.xaf(126000),
  payable: const Money.xaf(3708000),
  tills: const Money.xaf(192000),
  net: Money.xaf(net),
  state: state,
  preparedAt: DateTime.utc(2026, 8, 8, 9),
  destination: 'MoMo ****4471',
  reference: reference,
);

AdminOperatorDto adminOperator({
  String status = 'under_review',
  int commissionBps = 500,
  DateTime? createdAt,
  String? riskBand,
  List<String> riskReasons = const [],
}) => AdminOperatorDto(
  id: 'op-1',
  code: 'ODN',
  legalName: 'Océan du Nord SARL',
  tradingName: 'Océan du Nord',
  status: status,
  marketCode: 'CG',
  createdAt: createdAt ?? DateTime.utc(2026, 8, 1),
  commissionBps: commissionBps,
  rccmNumber: 'CG-BZV-01-2019-B12-00042',
  documentCount: 2,
  expiringDocumentCount: 1,
  vehicleCount: 14,
  routeCount: 3,
  staffCount: 9,
  riskBand: riskBand,
  riskReasons: riskReasons,
);

UnresolvedPaymentDto unresolvedPayment() => UnresolvedPaymentDto(
  intentId: 'pi-1',
  state: 'indeterminate',
  railId: 'mtn',
  amount: const Money.xaf(12300),
  payerMsisdn: '+242061234567',
  createdAt: DateTime.utc(2026, 8, 10, 6),
  bookingId: 'bk-1',
  bookingRef: 'BEL-7QK4M2',
  bookingState: 'pending_payment',
  operatorId: 'op-1',
  operatorName: 'Océan du Nord',
  pollAttempts: 4,
  travellerPhone: '+242069876543',
);
