-- 0013_second_factor — TOTP for the people who can move other people's money.
--
-- ADR-0013 asks for email + password + mandatory TOTP on both back-office
-- surfaces. What shipped instead was the traveller's one-time-code sign-in,
-- documented as a deviation with a stated ordering: TOTP lands before refunds
-- and payouts do, and before the admin app leaves the pilot. This is that.
--
-- Three decisions are visible in the shape of these tables.
--
-- **The secret lives on the identity surface and nowhere else.** Resolving a
-- second factor happens during sign-in, before the request has a tenant or a
-- surface — the same reason `auth_challenges` lives there (0007) and the same
-- reason `platform_staff` reads happen there (0012). `bel_app`, `bel_admin`
-- and `bel_public` get nothing at all, so a compromised operator console
-- cannot read the seed that protects the back office.
--
-- **`last_window` is not bookkeeping, it is the replay control.** A TOTP code
-- is valid for thirty seconds, which is thirty seconds during which somebody
-- reading over a shoulder can use it too. Recording the window a code was
-- spent in, and refusing any window at or below it, is what makes a code
-- single-use. Without this column the second factor is materially weaker than
-- it looks.
--
-- **Recovery codes are hashed, single-use and few.** A phone is lost, dropped
-- in a river, or wiped by an IT department. Eight codes, stored as HMACs the
-- same way a sign-in code is, so a dump of this table lets nobody in.

BEGIN;

CREATE TABLE user_totp (
  user_id       UUID PRIMARY KEY REFERENCES user_accounts(id) ON DELETE CASCADE,

  -- Base32, because that is what an authenticator app scans. Encrypting it at
  -- rest is the obvious next control and is deliberately not claimed here:
  -- a KMS key that lives in the same environment as the database is
  -- reassurance rather than a control, and pretending otherwise is worse than
  -- naming the gap.
  secret_base32 TEXT NOT NULL,

  -- Null until the enrolling person has proven they can compute a code. An
  -- unconfirmed row must never be treated as a second factor: it would lock
  -- somebody out of the console with a secret they mistyped.
  confirmed_at  TIMESTAMPTZ,

  -- The last TOTP window spent. See above: this is the replay control.
  last_window   BIGINT,

  -- Six digits is a million guesses, and a stolen half-session would happily
  -- spend them. Five consecutive failures lock the factor for fifteen
  -- minutes; a success clears the count. The lock is on the *factor* rather
  -- than on the attempt token, because otherwise discarding the token and
  -- asking for another resets the budget.
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until    TIMESTAMPTZ,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT user_totp_secret_present CHECK (length(secret_base32) >= 16),
  CONSTRAINT user_totp_attempts_sane CHECK (failed_attempts >= 0)
);

CREATE TABLE user_totp_recovery (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,

  -- An HMAC, never the code. Same rule as `auth_challenges.code_hash`.
  code_hash  TEXT NOT NULL,

  -- Single use. Kept after use rather than deleted, so "which recovery code
  -- was burned, and when" survives the incident it was burned during.
  used_at    TIMESTAMPTZ,

  -- Retired by a re-enrolment. A code that unlocks a secret nobody holds any
  -- more is a key to a door that no longer exists, so restarting enrolment
  -- retires the old list — and *retires* rather than deletes it, because
  -- `bel_identity` has no DELETE here on purpose and because "this code was
  -- live until Tuesday" is worth being able to answer.
  superseded_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, code_hash)
);

CREATE INDEX user_totp_recovery_unused_idx
  ON user_totp_recovery (user_id)
  WHERE used_at IS NULL AND superseded_at IS NULL;

-- ── The identity surface, and only it ───────────────────────────────────────

ALTER TABLE user_totp ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_totp FORCE ROW LEVEL SECURITY;
ALTER TABLE user_totp_recovery ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_totp_recovery FORCE ROW LEVEL SECURITY;

CREATE POLICY user_totp_identity_only ON user_totp
  FOR ALL USING (app_is_identity()) WITH CHECK (app_is_identity());

CREATE POLICY user_totp_recovery_identity_only ON user_totp_recovery
  FOR ALL USING (app_is_identity()) WITH CHECK (app_is_identity());

GRANT SELECT, INSERT, UPDATE, DELETE ON user_totp TO bel_identity;
GRANT SELECT, INSERT, UPDATE ON user_totp_recovery TO bel_identity;

-- DELETE on the seed, because disabling a second factor is a real operation
-- and leaving a stale secret behind is how somebody gets locked out by a row
-- nobody remembered. No DELETE on the recovery codes: a burned one is
-- evidence, and a retired one is answered with `superseded_at` rather than
-- with a missing row.

-- Stated as REVOKEs rather than as omissions, so the intent is greppable. A
-- compromised operator console must not be able to read the seed that guards
-- the surface which can approve operators and settle payments.
REVOKE ALL ON user_totp FROM bel_public, bel_app, bel_admin;
REVOKE ALL ON user_totp_recovery FROM bel_public, bel_app, bel_admin;

COMMIT;
