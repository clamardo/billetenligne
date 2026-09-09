/// Switching an approved company on (`03-operator-lifecycle.md` §2.4, J2).
///
/// Approval and activation are two different sentences and the difference is
/// the whole of this file. **Approved** means a reviewer read the paperwork
/// and believes this is a real transport company. **Active** means we are
/// selling their seats and taking their passengers' money — which is a
/// promise to two parties, and both preconditions here are about one of them.
///
/// Neither of these facts is new. `operator_payment_accounts.verified_at` has
/// existed since 0011 and `operator_applications.agreement_accepted_at` since
/// 0015; nothing consulted either at the moment they matter, so the state
/// "selling, with nowhere for the money to land" was reachable by pressing a
/// green button.
library;

/// What stops an approved company being switched on.
enum ActivationBlock {
  /// No verified collection account. We would be taking money on their behalf
  /// with nowhere to send it — a payout run that produces a statement nobody
  /// can be paid against, and a fortnight later a company owed real money by
  /// a platform that never had an account for them.
  ///
  /// **Verified**, not merely present. An unverified number is one somebody
  /// typed; the whole point of the column is that a number nobody has proved
  /// belongs to the operator must not receive money.
  needsVerifiedAccount,

  /// No recorded acceptance of the platform agreement. Selling on behalf of a
  /// company that never accepted our terms is not a paperwork problem, it is
  /// the absence of the thing that says what happens when something goes
  /// wrong.
  ///
  /// A company onboarded by hand, with no application row, has no recorded
  /// acceptance either — and is refused for exactly the same reason. There is
  /// no route here that says "signed on paper, trust me": if consent was
  /// given, it is recordable.
  needsAgreement,
}

/// Null when the company may be switched on.
///
/// **The account is reported first**, and the order is about the reviewer's
/// next move rather than about which failure is worse. Verifying an account
/// is a button on the screen they are already looking at; chasing an
/// acceptance is an email and a wait. Naming the one they can act on now is
/// the difference between a refusal and a support call.
///
/// This is the whole rule, and it is deliberately not a checklist of
/// everything a reviewer looked at. Licences, insurance and the RCCM number
/// are what **approval** is; re-testing them here would be a second gate
/// disagreeing with the first one the day somebody changes only one of them.
ActivationBlock? activationBlock({
  required bool hasVerifiedCollectionAccount,
  required bool agreementAccepted,
}) {
  if (!hasVerifiedCollectionAccount) {
    return ActivationBlock.needsVerifiedAccount;
  }
  if (!agreementAccepted) return ActivationBlock.needsAgreement;
  return null;
}
