import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Authenticated encryption for the few secrets this system stores that it
/// must later be able to *read* — today, exactly one: the TOTP seed.
///
/// **Why this is not hashing.** Every other secret here is stored as a digest
/// — a sign-in code, a recovery code, a password if one ever exists — because
/// the server only ever needs to answer "is this the same value?". A TOTP seed
/// is different in kind: the server has to recompute a code from it every
/// thirty seconds, so it must hold the value itself. That is the whole reason
/// this file exists, and the reason it is the only one of its kind.
///
/// **What it is worth, stated honestly.** A key that lives in the same
/// environment as the database does not protect against somebody who has the
/// environment. It protects against the far commoner thing: a copy of the
/// data leaving without the environment — a backup on a laptop, a restore into
/// a staging cluster, a read-only injection, a disk sold with a filesystem
/// still on it. Those are separate events, and separating them is the control.
/// Believing it defends against a compromised process would be worse than not
/// having it.
///
/// **AES-256-GCM.** Authenticated, so a ciphertext somebody edited is a
/// failure rather than a different secret. The nonce is random per write and
/// stored beside the value; GCM's nonce-reuse cliff is real, but a seed is
/// written once per enrolment rather than per request, and a 96-bit random
/// nonce is far the other side of any birthday bound at that rate.
///
/// **The stored form is self-describing**: `v1.<nonce>.<ciphertext+tag>`,
/// each part base64. The prefix is what makes an already-populated table
/// readable — a row without it is plaintext from before this existed, and is
/// returned as-is rather than failing (see [decrypt]). Any later scheme is
/// `v2.` and the same reader keeps working.
final class SecretCipher {
  const SecretCipher(this._key);

  /// The 32-byte key. Derived rather than taken raw, so the environment can
  /// carry a passphrase — see [fromPassphrase].
  final List<int> _key;

  static const _prefix = 'v1.';
  static final _aes = AesGcm.with256bits();

  /// Derives a key from whatever the environment holds.
  ///
  /// SHA-256 over the passphrase: a KMS would hand over 32 bytes directly and
  /// an environment variable will not, and refusing anything that is not
  /// already 32 raw bytes would push somebody into base64-decoding by hand at
  /// three in the morning. The length floor is the same 32 characters
  /// `AUTH_CODE_KEY` asks for, and for the same reason — it is a lower bound
  /// on effort, not on entropy, but a short one is always a mistake.
  static SecretCipher? fromPassphrase(String? passphrase) {
    if (passphrase == null || passphrase.length < 32) return null;
    return SecretCipher(_sha256(utf8.encode(passphrase)));
  }

  /// Encrypts, returning the stored form.
  Future<String> encrypt(String plaintext) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(_key),
      nonce: nonce,
    );
    // Tag concatenated with the ciphertext rather than stored apart: it is
    // never useful on its own, and one field is one thing to get wrong.
    final sealed = <int>[...box.cipherText, ...box.mac.bytes];
    return '$_prefix${base64.encode(nonce)}.${base64.encode(sealed)}';
  }

  /// Decrypts a stored value.
  ///
  /// **A value without the version prefix is returned unchanged.** That is not
  /// laziness: this control is being added to a table that already holds rows,
  /// and a reader that threw on them would lock out every person enrolled
  /// before the deploy. The adapter re-writes what it reads, so a row upgrades
  /// the next time its owner signs in.
  ///
  /// A value that *does* carry the prefix and fails to authenticate throws.
  /// The wrong key must be loud — quietly treating an undecryptable seed as
  /// absent would enrol somebody a second time and hand an attacker a factor.
  Future<String> decrypt(String stored) async {
    if (!stored.startsWith(_prefix)) return stored;

    final parts = stored.substring(_prefix.length).split('.');
    if (parts.length != 2) {
      throw const FormatException('malformed sealed secret');
    }

    final sealed = base64.decode(parts[1]);
    final macLength = _aes.macAlgorithm.macLength;
    if (sealed.length < macLength) {
      throw const FormatException('sealed secret is too short to carry a tag');
    }

    final clear = await _aes.decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - macLength),
        nonce: base64.decode(parts[0]),
        mac: Mac(sealed.sublist(sealed.length - macLength)),
      ),
      secretKey: SecretKey(_key),
    );
    return utf8.decode(clear);
  }

  /// Whether a stored value is already sealed. The adapter uses this to decide
  /// whether reading one should also re-write it.
  static bool isSealed(String stored) => stored.startsWith(_prefix);
}

List<int> _sha256(List<int> input) =>
    Uint8List.fromList(Sha256().toSync().hashSync(input).bytes);
