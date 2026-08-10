/// Cryptography the domain needs but must not implement.
///
/// `bel_domain` has zero dependencies (ADR-0001), and Ed25519 and HMAC both
/// require one. Keeping them behind ports means the *decisions* — is this
/// ticket for this departure, has it already boarded, is its code stale — stay
/// pure and testable at thousands of tests a second, while the primitives live
/// in an adapter.
abstract interface class SignatureVerifier {
  /// True when [signature] is a valid signature over [message] for [keyId].
  ///
  /// Devices carry **public keys only** — the signing key never leaves the
  /// server's KMS. [keyId] selects among them, so rotation is seamless and
  /// old tickets keep verifying until their departure has passed.
  bool verify({
    required List<int> message,
    required List<int> signature,
    required int keyId,
  });
}

abstract interface class MessageAuthenticator {
  List<int> hmacSha256({required List<int> key, required List<int> message});

  /// HMAC-SHA1, for RFC 6238 only.
  ///
  /// Present because authenticator apps read RFC 6238 as it was deployed and
  /// nothing else. It is not an invitation to use SHA-1 anywhere else in this
  /// codebase, and there is exactly one caller: [Totp].
  List<int> hmacSha1({required List<int> key, required List<int> message});
}

/// Signs tickets. Server-side only — no client implements this.
abstract interface class TicketSigner {
  List<int> sign({required List<int> message, required int keyId});
  int get activeKeyId;
}
