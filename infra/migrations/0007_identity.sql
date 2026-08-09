-- 0007_identity — the seam between "who says they are" and "who they are".
--
-- Until this migration every hold in the system belonged to one demo user,
-- because there was no way to become a customer. This is what fixes that.
--
-- Two things live here, and the second is the reason the first needs its own
-- role.
--
--   1. `auth_challenges` — the one-time code we send and then check.
--   2. `bel_identity` — a fourth surface role (0005 introduced the pattern),
--      because identity resolution happens BEFORE we know who the caller is,
--      and therefore before any of the existing roles can be chosen.
--
-- Why we send the code at all, when Firebase would send it for us: ADR-0018
-- documents this exact fallback, and ADR-0019 says to build it early enough
-- to have the option. We own the challenge — so we can send it over a channel
-- we can measure and price, email first (ADR-0019: ACS email is configured,
-- SMS is not) and phone second — and Firebase still owns the session, the
-- refresh rotation and the revocation, because a correct code is answered
-- with a Firebase CUSTOM TOKEN rather than a session of our own invention.
--
-- The property that makes the table below safe to hold: **it never stores a
-- code.** It stores an HMAC of one. A dump of this table lets nobody sign in
-- as anybody, which is not true of the obvious design.

BEGIN;

-- ── Verification state on the account ───────────────────────────────────────
--
-- `user_accounts` already carried `email` and `phone_e164`. What it could not
-- say is whether either had ever been *proved*, and the difference matters the
-- moment an operator types a traveller's address into the guichet: that
-- address identifies them, it does not authenticate them.

ALTER TABLE user_accounts
  ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ;

-- Email is the sign-in channel today, so it is looked up on every attempt.
-- Case-insensitively: addresses are stored lowercased by the application, and
-- this index is what makes that a fact rather than an intention.
CREATE UNIQUE INDEX IF NOT EXISTS user_accounts_email_lower
  ON user_accounts (lower(email)) WHERE email IS NOT NULL;

-- ...and the case-SENSITIVE constraint 0001 declared is dropped, because it is
-- now strictly weaker than the index above and having both is worse than
-- having either. The upsert on the sign-in path names one index as its
-- conflict target; a second unique constraint over the same column is a
-- second way for that statement to fail, on a path where failing means a
-- traveller who cannot sign in.
ALTER TABLE user_accounts DROP CONSTRAINT IF EXISTS user_accounts_email_key;

-- ── The challenge ───────────────────────────────────────────────────────────

CREATE TABLE auth_challenges (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  channel       TEXT NOT NULL,
  -- Normalised at the application boundary: an email lowercased and trimmed,
  -- a phone in E.164. Storing what the user typed would make the rate limit
  -- below trivially evadable with a capital letter.
  destination   TEXT NOT NULL,

  -- HMAC-SHA256 of the code under a server-side key, never the code.
  -- A constant-time comparison happens in the application; storing a hash is
  -- what makes a leaked backup worthless rather than catastrophic.
  code_hash     TEXT NOT NULL,

  language      TEXT NOT NULL DEFAULT 'fr',

  attempts      INT NOT NULL DEFAULT 0,
  -- Five, per ADR-0013. A column rather than a constant so a market with
  -- worse SMS deliverability can be given more room without a deploy.
  max_attempts  INT NOT NULL DEFAULT 5,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  consumed_at   TIMESTAMPTZ,

  -- Set when the code is answered correctly. Null before that, and null
  -- forever on a challenge that was never completed — which is what makes
  -- "how many people bounced off sign-in this week" answerable.
  user_id       UUID REFERENCES user_accounts(id) ON DELETE SET NULL,

  CONSTRAINT auth_challenges_channel_known
    CHECK (channel IN ('email', 'phone')),
  CONSTRAINT auth_challenges_expires_after_creation
    CHECK (expires_at > created_at)
);

-- The cooldown lookup: the most recent live challenge for an address. This
-- index is the rate limit's index — without it, the check that runs on every
-- sign-in attempt is a sequential scan over every code ever issued.
CREATE INDEX auth_challenges_destination_recent
  ON auth_challenges (destination, created_at DESC);

-- For the sweeper that will eventually delete these (services/worker). Rows
-- here are worthless within five minutes and are personal data besides.
CREATE INDEX auth_challenges_expiry ON auth_challenges (expires_at)
  WHERE consumed_at IS NULL;

-- ── The identity surface ────────────────────────────────────────────────────
--
-- A fourth role, for the same reason 0005 introduced the third: least
-- privilege at the CONNECTION, not at the query.
--
-- The order of operations forces it. Verifying a bearer token means reading
-- `user_accounts` to turn a Firebase UID into our user id — and that read
-- happens before the request has a surface, a tenant or a user id, so none of
-- `bel_public`, `bel_app` or `bel_admin` can be the role that performs it.
-- Handing the job to `bel_app` would give the traveller-facing sign-in path an
-- operator's authority, which is precisely the trade 0005 refused.
--
-- `bel_identity` can therefore read and write exactly two tables and has no
-- grant whatsoever on departures, seats, holds, bookings, tickets, the ledger
-- or the audit log. It cannot sell anything. It can only answer "who is
-- this?".

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_identity') THEN
    CREATE ROLE bel_identity NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

GRANT bel_identity TO bel_api;

-- True only on the identity surface, set alongside the others by the same
-- middleware that sets `app.public`.
CREATE OR REPLACE FUNCTION app_is_identity() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.identity', true), 'off') = 'on'
$$;

-- RLS on the challenge table even though only one role is granted anything on
-- it. The grant list is the intent; the policy is what survives somebody
-- adding a convenient GRANT in eighteen months. A code hash must never be
-- readable from a surface that serves an anonymous internet request.
ALTER TABLE auth_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_challenges FORCE ROW LEVEL SECURITY;

CREATE POLICY auth_challenges_identity_only ON auth_challenges
  FOR ALL
  USING (app_is_identity())
  WITH CHECK (app_is_identity());

GRANT USAGE ON SCHEMA public TO bel_identity;

GRANT SELECT, INSERT, UPDATE ON auth_challenges TO bel_identity;

-- No DELETE: expiring a challenge is a matter of time, not of a statement,
-- and a surface that can delete its own audit trail cannot be audited. The
-- sweeper in services/worker will run as bel_admin.
GRANT SELECT, INSERT, UPDATE ON user_accounts TO bel_identity;

-- And explicitly NOT to the public surface. Stated as a REVOKE rather than an
-- omission so the intent is greppable: a traveller's own profile is served by
-- the identity surface, which knows the caller, and never by the sales
-- surface, which serves anonymous requests from the internet.
REVOKE ALL ON auth_challenges FROM bel_public, bel_app;
REVOKE ALL ON user_accounts FROM bel_public;

COMMIT;
