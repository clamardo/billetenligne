import 'package:bel_domain/bel_domain.dart';
import 'package:cryptography/cryptography.dart';

/// Verifies ticket signatures against a set of public keys.
///
/// Ed25519 over ECDSA: 64-byte signatures (which matters when the whole QR
/// must stay under 300 bytes), fast verification on weak ARM cores, and no
/// curve-parameter footguns.
///
/// **Devices carry public keys only.** The signing key never leaves the
/// server's KMS. [keyId] selects among them so rotation is seamless: old keys
/// are retained until the last ticket signed with them has departed.
final class Ed25519TicketVerifier
    implements SignatureVerifier, SignaturePreparer {
  Ed25519TicketVerifier(this._publicKeys);

  /// keyId -> 32-byte public key.
  final Map<int, List<int>> _publicKeys;

  final _algorithm = Ed25519();

  /// Verification is synchronous at the call site because a conductor scanning
  /// sixty passengers cannot wait on a future per scan, and the domain's
  /// verifier is a pure function. The results are precomputed by [warmUp] and
  /// the check itself is a fast in-memory operation.
  final Map<String, bool> _cache = {};

  Set<int> get knownKeyIds => _publicKeys.keys.toSet();

  /// Adds or replaces a public key. Called when the device syncs its key set.
  void trust(int keyId, List<int> publicKey) {
    _publicKeys[keyId] = publicKey;
    _cache.clear();
  }

  /// Ed25519 verification in this package is async, but the domain port is
  /// synchronous by design. [prepare] does the async work for a batch of
  /// scanned payloads up front; [verify] then answers instantly.
  ///
  /// In the scanner this is called on the single payload just decoded, which
  /// keeps the whole scan under the two-second budget while leaving the domain
  /// a pure, testable function.
  @override
  Future<void> prepare({
    required List<int> message,
    required List<int> signature,
    required int keyId,
  }) async {
    final key = _publicKeys[keyId];
    if (key == null) {
      _cache[_cacheKey(message, signature, keyId)] = false;
      return;
    }

    var ok = false;
    try {
      ok = await _algorithm.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      // A malformed signature or key is simply not valid. It must never take
      // the scanner down mid-boarding.
      ok = false;
    }
    _cache[_cacheKey(message, signature, keyId)] = ok;
  }

  @override
  bool verify({
    required List<int> message,
    required List<int> signature,
    required int keyId,
  }) => _cache[_cacheKey(message, signature, keyId)] ?? false;

  static String _cacheKey(List<int> message, List<int> signature, int keyId) {
    var h = 0xcbf29ce484222325;
    for (final b in message) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    for (final b in signature) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return '$keyId:${(h & 0x7FFFFFFFFFFFFFFF).toRadixString(16)}';
  }
}

/// Signs tickets. **Server-side only** — no client ever holds one of these.
final class Ed25519TicketSigner {
  Ed25519TicketSigner({required this.activeKeyId, required SimpleKeyPair pair})
    : _pair = pair;

  final int activeKeyId;
  final SimpleKeyPair _pair;
  final _algorithm = Ed25519();

  Future<List<int>> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _pair);
    return signature.bytes;
  }

  Future<List<int>> publicKeyBytes() async =>
      (await _pair.extractPublicKey()).bytes;

  /// Deterministic from a 32-byte seed, so a local development environment can
  /// hold a fixed key and a ticket signed yesterday still verifies today
  /// (ADR-0020). Production keys are generated in and never leave the KMS.
  static Future<Ed25519TicketSigner> fromSeed(
    List<int> seed, {
    int keyId = 1,
  }) async {
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    return Ed25519TicketSigner(activeKeyId: keyId, pair: pair);
  }
}
