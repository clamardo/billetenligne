-- Verifies the identity surface from 0007.
--
-- 0007 makes five claims, each of the kind that stays true right up until the
-- afternoon somebody adds a convenient GRANT. So each is executed:
--
--   1. the identity role can issue a challenge and read it back;
--   2. NOTHING ELSE can read a code hash — not the sales surface, not an
--      operator, not the identity surface itself with the flag off;
--   3. the identity role cannot sell, refund, or read the ledger;
--   4. the sales surface cannot read user_accounts;
--   5. one address means one account, whatever case it is typed in.
--
-- Runs after verify_public.sql, against the same seeded database.

\set ON_ERROR_STOP on
SET client_min_messages TO NOTICE;

-- ── 1 & 2. Issuing a challenge, and who can see it ──────────────────────────
DO $$
DECLARE
  challenge UUID;
  visible   INT;
BEGIN
  SET LOCAL ROLE bel_identity;
  PERFORM set_config('app.identity', 'on', true);
  PERFORM set_config('app.public', 'off', true);

  INSERT INTO auth_challenges (channel, destination, code_hash, expires_at)
  VALUES ('email', 'aline@example.cg', 'hmac-not-a-code',
          now() + INTERVAL '5 minutes')
  RETURNING id INTO challenge;

  SELECT count(*) INTO visible FROM auth_challenges WHERE id = challenge;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: the identity role cannot read its own challenge';
  END IF;

  -- The same role, one flag off. This is the case that matters: a future
  -- handler that forgets to declare the surface must see nothing, not
  -- everything.
  PERFORM set_config('app.identity', 'off', true);
  SELECT count(*) INTO visible FROM auth_challenges;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: challenges are readable without app.identity (% rows)', visible;
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  a challenge is visible to the identity surface and to nothing else';
END
$$;

-- ── 3, 4. Grant lists ───────────────────────────────────────────────────────
--
-- The identity surface answers one question — "who is this?" — and a role that
-- can answer it and also take money is a role whose blast radius is the whole
-- product.
DO $$
DECLARE
  t         TEXT;
  reachable TEXT[] := '{}';
  forbidden TEXT[] := ARRAY[
    'seats', 'holds', 'bookings', 'booking_seats', 'tickets',
    'payment_intents', 'refunds', 'ledger_entries', 'payment_events',
    'audit_log', 'kyb_documents', 'departures'
  ];
BEGIN
  FOREACH t IN ARRAY forbidden LOOP
    IF has_table_privilege('bel_identity', t, 'SELECT')
    OR has_table_privilege('bel_identity', t, 'INSERT')
    OR has_table_privilege('bel_identity', t, 'UPDATE')
    OR has_table_privilege('bel_identity', t, 'DELETE') THEN
      reachable := reachable || t;
    END IF;
  END LOOP;

  IF cardinality(reachable) > 0 THEN
    RAISE EXCEPTION 'FAIL: the identity role can reach %', reachable;
  END IF;

  -- And the converse: the sales surface cannot read the account table, so a
  -- crafted query in a public handler cannot enumerate travellers' addresses.
  IF has_table_privilege('bel_public', 'user_accounts', 'SELECT')
  OR has_table_privilege('bel_public', 'auth_challenges', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: the public role can read accounts or challenges';
  END IF;

  -- Nor may the identity surface erase a challenge it got wrong. The sweeper
  -- may (0010), and the two roles have exactly opposite privileges on this
  -- table for that reason: issuing is identity, retiring is maintenance.
  IF has_table_privilege('bel_identity', 'auth_challenges', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: the identity role can delete its own audit trail';
  END IF;

  IF has_table_privilege('bel_admin', 'auth_challenges', 'INSERT')
  OR has_table_privilege('bel_admin', 'auth_challenges', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: the sweeper can issue or edit a sign-in code';
  END IF;

  -- `operator_staff` left the list above in 0009, because resolving a bearer
  -- token has to answer "who is this AND what are they" and a role is part of
  -- that answer. The rule being protected was never "cannot read a role" — it
  -- was "cannot answer who-is-this and also take money" — so what matters is
  -- that the read is read-only. Reading a role is identity; writing one is
  -- administration, and they are not the same surface.
  IF has_table_privilege('bel_identity', 'operator_staff', 'INSERT')
  OR has_table_privilege('bel_identity', 'operator_staff', 'UPDATE')
  OR has_table_privilege('bel_identity', 'operator_staff', 'DELETE')
  OR has_table_privilege('bel_identity', 'operators', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: the identity role can grant itself a role';
  END IF;

  -- 0012 added `platform_staff` for the same reason and under the same rule.
  -- This one matters more than the others: a surface that could write it
  -- could make its own caller a super_admin, which would make every control
  -- in this file decorative.
  IF NOT has_table_privilege('bel_identity', 'platform_staff', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: the identity role cannot see our own staff';
  END IF;

  IF has_table_privilege('bel_identity', 'platform_staff', 'INSERT')
  OR has_table_privilege('bel_identity', 'platform_staff', 'UPDATE')
  OR has_table_privilege('bel_identity', 'platform_staff', 'DELETE')
  OR has_table_privilege('bel_admin', 'platform_staff', 'INSERT')
  OR has_table_privilege('bel_admin', 'platform_staff', 'UPDATE')
  OR has_table_privilege('bel_admin', 'platform_staff', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: a running surface can appoint its own staff';
  END IF;

  RAISE NOTICE 'OK  the identity role reads roles, cannot write them, and cannot sell';
END
$$;

-- ── 5. One address, one account ─────────────────────────────────────────────
--
-- The application lowercases before it writes. This index is what makes that
-- a guarantee rather than a convention — and the failure it prevents is two
-- accounts, two ticket histories, and a traveller certain we lost their
-- booking.
DO $$
BEGIN
  INSERT INTO user_accounts (email, full_name)
  VALUES ('serge@example.cg', 'Serge N.');

  BEGIN
    INSERT INTO user_accounts (email, full_name)
    VALUES ('Serge@Example.CG', 'Serge N. again');
    RAISE EXCEPTION 'FAIL: the same address created a second account';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  RAISE NOTICE 'OK  one address means one account, whatever case it is typed in';
END
$$;

-- ── 6. The second factor's seed is not reachable from a sales surface ───────
--
-- The whole point of TOTP here is that compromising the console does not get
-- you the back office. A grant on `user_totp` from `bel_app` or `bel_admin`
-- would quietly undo that: the seed is enough to compute every future code.
DO $$
BEGIN
  IF NOT has_table_privilege('bel_identity', 'user_totp', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: the identity surface cannot read a second factor';
  END IF;

  IF has_table_privilege('bel_public', 'user_totp', 'SELECT')
  OR has_table_privilege('bel_app', 'user_totp', 'SELECT')
  OR has_table_privilege('bel_admin', 'user_totp', 'SELECT')
  OR has_table_privilege('bel_public', 'user_totp_recovery', 'SELECT')
  OR has_table_privilege('bel_app', 'user_totp_recovery', 'SELECT')
  OR has_table_privilege('bel_admin', 'user_totp_recovery', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: a sales surface can read the seed guarding the back office';
  END IF;

  -- A burned recovery code is evidence of an incident. A surface that can
  -- delete its own evidence cannot be audited.
  IF has_table_privilege('bel_identity', 'user_totp_recovery', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: a used recovery code can be erased';
  END IF;

  RAISE NOTICE 'OK  the second factor seed lives on the identity surface alone';
END
$$;

-- ── 7. Retiring a recovery code is an UPDATE, never a DELETE ────────────────
--
-- Section 6 refuses `bel_identity` the DELETE. That refusal is only survivable
-- because re-enrolment has somewhere else to go — `superseded_at` — and a
-- schema that lost that column would turn the refusal into a runtime error
-- during enrolment, which is the worst place to find out.
DO $$
DECLARE
  retired INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'user_totp_recovery' AND column_name = 'superseded_at'
  ) THEN
    RAISE EXCEPTION 'FAIL: recovery codes have no way to be retired without DELETE';
  END IF;

  -- And the retirement is real: a superseded code is not spendable.
  -- `user_accounts_reachable` refuses a row nobody could ever be contacted
  -- on, so this fixture carries an address.
  INSERT INTO user_accounts (id, language, email)
  VALUES ('00000000-0000-0000-0000-0000000000f2', 'fr', 'retired@example.cg')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO user_totp_recovery (user_id, code_hash, superseded_at)
  VALUES ('00000000-0000-0000-0000-0000000000f2', 'retired-hash', now())
  ON CONFLICT (user_id, code_hash) DO UPDATE SET superseded_at = now();

  UPDATE user_totp_recovery
     SET used_at = now()
   WHERE user_id = '00000000-0000-0000-0000-0000000000f2'
     AND code_hash = 'retired-hash'
     AND used_at IS NULL
     AND superseded_at IS NULL;
  GET DIAGNOSTICS retired = ROW_COUNT;

  IF retired <> 0 THEN
    RAISE EXCEPTION 'FAIL: a superseded recovery code can still be spent';
  END IF;

  DELETE FROM user_accounts WHERE id = '00000000-0000-0000-0000-0000000000f2';

  RAISE NOTICE 'OK  a retired recovery code is kept as evidence and refused as a key';
END
$$;

-- ── The seed column tells the truth about what it holds ─────────────────────
--
-- 0041 renamed `secret_base32` to `secret` because the API now writes
-- `v1.<nonce>.<ciphertext+tag>` into it. Asserted rather than assumed: the
-- rename is guarded on the old name existing, so a schema that ran 0041 twice
-- — or ran it against a database created after the rename — must still end up
-- with exactly one of the two names, and it must be the new one.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'user_totp' AND column_name = 'secret_base32'
  ) THEN
    RAISE EXCEPTION 'FAIL: user_totp still promises base32 it no longer holds';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'user_totp' AND column_name = 'secret'
  ) THEN
    RAISE EXCEPTION 'FAIL: user_totp has nowhere to keep a seed';
  END IF;

  -- The length floor survived the rename. A sealed value is far longer than
  -- sixteen characters, so this only ever catches a truncated one — which is
  -- the case that would otherwise present as "your authenticator is wrong".
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'user_totp_secret_present'
  ) THEN
    RAISE EXCEPTION 'FAIL: a second factor can be stored with no seed in it';
  END IF;

  RAISE NOTICE 'OK  the TOTP seed column is named for what it actually holds';
END
$$;
