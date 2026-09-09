import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

/// J2 — activation waits for the money to have somewhere to land.
///
/// The rule is three lines and the reason it exists is not. **Approved** and
/// **active** were the same green button as far as this code was concerned,
/// which meant a reviewer could switch on a company whose passengers' money
/// had nowhere to go, and find out a fortnight later at the first payout run.
void main() {
  group('what stops an approved company being switched on', () {
    test('a verified account and a recorded acceptance switch it on', () {
      expect(
        activationBlock(
          hasVerifiedCollectionAccount: true,
          agreementAccepted: true,
        ),
        isNull,
      );
    });

    test('no collection account at all', () {
      expect(
        activationBlock(
          hasVerifiedCollectionAccount: false,
          agreementAccepted: true,
        ),
        ActivationBlock.needsVerifiedAccount,
      );
    });

    test('no recorded acceptance of the agreement', () {
      expect(
        activationBlock(
          hasVerifiedCollectionAccount: true,
          agreementAccepted: false,
        ),
        ActivationBlock.needsAgreement,
      );
    });

    test('missing both names the one the reviewer can act on now', () {
      // The order is about the reviewer's next click, not about which failure
      // is worse. Verifying an account is a button on the screen they are
      // already looking at; chasing an acceptance is an email and a wait.
      expect(
        activationBlock(
          hasVerifiedCollectionAccount: false,
          agreementAccepted: false,
        ),
        ActivationBlock.needsVerifiedAccount,
      );
    });
  });
}
