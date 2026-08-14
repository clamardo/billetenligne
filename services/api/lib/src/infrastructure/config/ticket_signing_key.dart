import 'dart:convert';

/// The 32 bytes every ticket in this system is signed with.
///
/// **This file exists because the seed was a literal in the source.** ADR-0020
/// says production keys are generated in and never leave a KMS, and the
/// adapter's own comment said swapping one line was the whole change — but
/// nothing swapped it, and `Services.resolve` handed the development signer to
/// the database composition as readily as to the fakes. A deployment against a
/// real Postgres would have signed real tickets with a seed printed in a public
/// repository, and a ticket is only worth what it costs to forge: anybody who
/// can read the source could mint one for any seat on any coach, and the
/// scanner would have gone green on it in front of the conductor.
///
/// So the seed is configuration, and **the absence of it is not silently
/// survivable**:
///
///   * `TICKETS__SIGNINGSEED` is 32 bytes of base64. Any other length is a
///     refusal rather than a truncation — a seed somebody pasted half of is a
///     key nobody can ever reproduce, and tickets signed with it stop
///     verifying the day it is corrected.
///   * **The development seed is refused as a value.** It is in the source, so
///     copying it into a secret manager is the same accident wearing a
///     costume, and the only way to catch that is to name it.
///   * With no seed at all, a process talking to a real database **refuses to
///     start** unless it has been told in as many words that it is a
///     development one (`BEL__ENV=development`, which `infra/dev/.env` sets
///     and no deployment does). The fakes composition keeps the fixed seed
///     with no ceremony: it issues tickets for departures that do not exist.
///
/// The default is the safe one. A missing `BEL__ENV` reads as production —
/// forgetting it fails loudly at boot, which is the failure a person can fix,
/// rather than quietly for the lifetime of the deployment, which is the one
/// they find out about from somebody else.
abstract final class TicketSigningKey {
  /// The seed local runs use on purpose, so a ticket signed by yesterday's run
  /// still verifies today (ADR-0020) and a screenshot keeps scanning.
  static List<int> get development =>
      List<int>.generate(32, (i) => (i * 7 + 13) & 0xff);

  /// The seed this process should sign with, or a [StateError] naming the fix.
  ///
  /// [usingDatabase] is what makes the check strict: a composition serving
  /// invented departures cannot issue a ticket anybody boards on.
  static List<int> from(
    Map<String, String> env, {
    required bool usingDatabase,
    void Function(String message)? announce,
  }) {
    final configured = (env['TICKETS__SIGNINGSEED'] ?? '').trim();

    if (configured.isNotEmpty) {
      final seed = _decode(configured);
      if (seed.length != 32) {
        throw StateError(
          'TICKETS__SIGNINGSEED decodes to ${seed.length} bytes and Ed25519 '
          'takes 32. Generate one with: '
          "dart -e \"import 'dart:convert';import 'dart:math';"
          'print(base64Encode(List<int>.generate(32,(_)=>Random.secure()'
          '.nextInt(256))));"',
        );
      }
      if (_sameBytes(seed, development)) {
        throw StateError(
          'TICKETS__SIGNINGSEED is the development seed, which is printed in '
          'this repository. Every ticket signed with it is forgeable by '
          'anybody who can read the source. Generate a fresh one.',
        );
      }
      return seed;
    }

    if (usingDatabase && (env['BEL__ENV'] ?? 'production') != 'development') {
      throw StateError(
        'TICKETS__SIGNINGSEED is not set and this process is talking to a '
        'real database. Signing tickets with the seed in the source would '
        'make every one of them forgeable. Set the variable, or set '
        'BEL__ENV=development if this is a local stack.',
      );
    }

    if (usingDatabase) {
      // Said out loud, once, for the same reason the second-factor cipher says
      // it: a local stack running without the control should know it is.
      (announce ?? print)(
        'tickets: signing with the development seed (BEL__ENV=development). '
        'Every ticket this process issues is forgeable.',
      );
    }
    return development;
  }

  static List<int> _decode(String value) {
    try {
      return base64Decode(base64.normalize(value));
    } on FormatException {
      throw StateError(
        'TICKETS__SIGNINGSEED is not base64. It is 32 bytes of base64, not a '
        'passphrase and not hex.',
      );
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
