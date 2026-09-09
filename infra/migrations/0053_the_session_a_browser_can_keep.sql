-- 0053_the_session_a_browser_can_keep — a session the browser holds no
-- credential for (`18-…-can-join.md` J11).
--
-- **What was wrong.** Every surface here authenticates with a Firebase ID
-- token in an `Authorization` header, and every surface that is a browser has
-- to keep that token somewhere. The console and the back office kept it in
-- `MemorySessionStore`, so a session died with the tab — a dispatcher who
-- refreshed the page was signed out mid-shift. The web build of the handset
-- app did worse: `SecureSessionStore` on the web writes an AES key into the
-- same storage as its own ciphertext, which is a locked door with the key
-- hanging on it (known gap #4).
--
-- **What replaces it.** The refresh token stops crossing the network to the
-- browser at all. It is exchanged server-side and held here; the browser gets
-- an opaque selector in an `HttpOnly` cookie, which is a value that grants
-- nothing to script running in the page. Script is the threat that matters
-- for a browser: an XSS on a page holding a 90-day refresh token in
-- `localStorage` is a 90-day account takeover, and the same XSS against a
-- cookie it cannot read is a session that ends when the cookie does.
--
-- Three decisions are visible in the table.
--
-- **The cookie's value is never stored.** `selector_hash` is a SHA-256 of it,
-- the same rule `auth_challenges.code_hash` follows: a dump of this table
-- lets nobody in, and the row is still findable in one indexed lookup.
--
-- **The refresh token is encrypted at rest, not hashed.** It is the one
-- secret here the server must be able to *read* back — that is what makes it
-- a session — so it takes the same `SecretCipher` treatment as the TOTP seed,
-- and the same honest caveat: a key in the same environment as the database
-- separates a copy of the data from a copy of the environment, and defends
-- against nothing that already holds both.
--
-- **Rotation is a row lock, not application code.** Firebase rotates the
-- refresh token on use, so two tabs waking together must not both spend it —
-- the second would invalidate the first and sign somebody out for opening a
-- second tab. `SELECT … FOR UPDATE` on this row is the whole control, and it
-- is the reason the current ID token is stored beside the refresh token
-- rather than recomputed per request.
--
-- The identity surface, and only it. Resolving a session happens before the
-- request has a tenant or a surface, exactly as sign-in does (0007, 0013).

BEGIN;

CREATE TABLE IF NOT EXISTS web_sessions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,

  -- SHA-256 of the cookie's opaque selector. Never the selector.
  selector_hash  TEXT NOT NULL UNIQUE,

  -- `SecretCipher`'s self-describing form: `v1.<nonce>.<ciphertext+tag>`.
  refresh_cipher TEXT NOT NULL,

  -- The ID token currently in hand, and when it dies. Stored so a page of a
  -- console making six calls costs one refresh rather than six, and so the
  -- refresh that does happen is serialised by this row's lock.
  id_token_cipher     TEXT,
  id_token_expires_at TIMESTAMPTZ,

  -- What the browser was told. Kept for the session list a person can read
  -- later, and for the support call that starts "I never signed in from
  -- there". Coarse on purpose: a user agent and an address, not a
  -- fingerprint.
  user_agent     TEXT,
  created_ip     INET,

  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- The end of the session whatever happens. A browser cookie can outlive
  -- any intention — a shared machine, a stolen laptop — so the server holds
  -- its own clock on it.
  expires_at     TIMESTAMPTZ NOT NULL,

  -- Sign-out, and revocation from another device. Set rather than deleted:
  -- "this session was live until Tuesday" is worth being able to answer
  -- during the incident that asks it.
  revoked_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS web_sessions_user_live_idx
  ON web_sessions (user_id)
  WHERE revoked_at IS NULL;

ALTER TABLE web_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE web_sessions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS web_sessions_identity_only ON web_sessions;
CREATE POLICY web_sessions_identity_only ON web_sessions
  FOR ALL USING (app_is_identity()) WITH CHECK (app_is_identity());

GRANT SELECT, INSERT, UPDATE, DELETE ON web_sessions TO bel_identity;

-- Stated as REVOKEs rather than as omissions, so the intent is greppable.
-- A session row is a live credential in every sense that matters; the
-- operator console and the public surface have no business reading one.
REVOKE ALL ON web_sessions FROM bel_public, bel_app, bel_admin;

COMMIT;
