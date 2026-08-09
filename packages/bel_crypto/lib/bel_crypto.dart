/// Real cryptographic primitives behind the ports `bel_domain` declares.
///
/// Separate package so the domain stays dependency-free (ADR-0001): the
/// *decisions* — is this ticket for this coach, has it boarded, is its code
/// stale — remain pure and fast to test, while the primitives live somewhere
/// they can be audited on their own.
library;

export 'src/ed25519_verifier.dart';
export 'src/hmac_authenticator.dart';
