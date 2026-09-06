import 'package:bel_domain/bel_domain.dart';

import '../application/ports/platform_billing_rail.dart';

/// Our own settlement account, read out to an operator over the phone or
/// wired to from theirs. No external call, ever — there is nothing to call.
///
/// Configured at startup from this deployment's own bank details, the same
/// way the card rail is configured from a PSP's credentials — the difference
/// is that these details are never absent. A platform with no bank account at
/// all cannot receive money by any rail, so unlike the card rail there is no
/// "not configured" state to represent: this adapter is always [available].
final class BankTransferBillingRail implements PlatformBillingRail {
  const BankTransferBillingRail({
    required this.bankName,
    required this.accountName,
    required this.accountNumber,
  });

  final String bankName;
  final String accountName;
  final String accountNumber;

  @override
  String get paymentType => 'bank_transfer';

  @override
  Future<PlatformBillingInstruction> instructionsFor({
    required String operatorId,
    required Money amountDue,
    required String reference,
  }) async => PlatformBillingInstruction(
    available: true,
    bankName: bankName,
    accountName: accountName,
    accountNumber: accountNumber,
    reference: reference,
  );
}
