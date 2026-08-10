-- Verifies the public sales boundary from 0005.
--
-- 0005 makes four claims. Each one is the kind of claim that stays true right
-- up until the afternoon somebody adds a convenient GRANT, so each one is
-- executed here rather than merely written down:
--
--   1. a traveller can see departures and seats without belonging to anyone;
--   2. a traveller cannot mark a seat SOLD — payment is the only way there;
--   3. a traveller sees their own holds and not a stranger's;
--   4. the public role cannot reach staff, KYB or the ledger at all.
--
-- Runs after verify.sql, against the same seeded database.

\set ON_ERROR_STOP on
SET client_min_messages TO NOTICE;

-- Two travellers and a departure to sell.
INSERT INTO user_accounts (id, phone_e164, full_name) VALUES
  ('55555555-5555-5555-5555-555555555551', '+242060000001', 'Aline M.'),
  ('55555555-5555-5555-5555-555555555552', '+242060000002', 'Serge N.');

INSERT INTO seat_layouts (id, operator_id, name, sections, capacity) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'Coach 2+2', '[]'::jsonb, 4);

INSERT INTO departures
  (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
   capacity, fare_minor, currency)
VALUES
  ('cccccccc-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001',
   now() + INTERVAL '2 days', now() + INTERVAL '2 days 8 hours',
   4, 12000, 'XAF');

INSERT INTO seats (departure_id, seat_label, operator_id, section_code,
                   fare_minor, currency) VALUES
  ('cccccccc-0000-0000-0000-000000000001', '1A',
   '11111111-1111-1111-1111-111111111111', 'STD', 12000, 'XAF'),
  ('cccccccc-0000-0000-0000-000000000001', '1B',
   '11111111-1111-1111-1111-111111111111', 'STD', 12000, 'XAF');

DO $$
DECLARE
  visible INT;
  aline   TEXT := '55555555-5555-5555-5555-555555555551';
  serge   TEXT := '55555555-5555-5555-5555-555555555552';
BEGIN
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.user_id', aline, true);

  -- ── 1. A traveller belongs to no operator and can still shop ──────────────
  SELECT count(*) INTO visible FROM departures;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: traveller saw % departures, expected 1', visible;
  END IF;

  SELECT count(*) INTO visible FROM seats;
  IF visible <> 2 THEN
    RAISE EXCEPTION 'FAIL: traveller saw % seats, expected 2', visible;
  END IF;

  -- ── 2. Holding is allowed ─────────────────────────────────────────────────
  INSERT INTO holds (id, operator_id, departure_id, user_id, seat_labels,
                     expires_at, idempotency_key)
  VALUES ('dddddddd-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111',
          'cccccccc-0000-0000-0000-000000000001',
          aline::uuid, ARRAY['1A'], now() + INTERVAL '15 minutes', 'idem-aline');

  UPDATE seats
     SET state = 'held',
         hold_id = 'dddddddd-0000-0000-0000-000000000001',
         held_until = now() + INTERVAL '15 minutes'
   WHERE departure_id = 'cccccccc-0000-0000-0000-000000000001'
     AND seat_label = '1A';

  -- ── 3. Selling is NOT ─────────────────────────────────────────────────────
  -- The single most important line in this file. If this check ever stops
  -- failing, an unauthenticated request can board a coach for free.
  BEGIN
    UPDATE seats SET state = 'sold', hold_id = NULL,
                     booking_id = gen_random_uuid()
     WHERE departure_id = 'cccccccc-0000-0000-0000-000000000001'
       AND seat_label = '1A';
    RAISE EXCEPTION 'FAIL: the public role marked a seat sold';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: WITH CHECK refused the new state
  END;

  -- Nor may it quietly block inventory, which would be a denial of service
  -- against the operator rather than a theft.
  BEGIN
    UPDATE seats SET state = 'blocked', hold_id = NULL
     WHERE departure_id = 'cccccccc-0000-0000-0000-000000000001'
       AND seat_label = '1B';
    RAISE EXCEPTION 'FAIL: the public role blocked a seat';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- ── 4. One traveller cannot see another's hold ────────────────────────────
  PERFORM set_config('app.user_id', serge, true);
  SELECT count(*) INTO visible FROM holds;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: Serge saw % of Aline''s holds', visible;
  END IF;

  -- Nor create one in her name.
  BEGIN
    INSERT INTO holds (operator_id, departure_id, user_id, seat_labels,
                       expires_at, idempotency_key)
    VALUES ('11111111-1111-1111-1111-111111111111',
            'cccccccc-0000-0000-0000-000000000001',
            aline::uuid, ARRAY['1B'], now() + INTERVAL '15 minutes', 'idem-forged');
    RAISE EXCEPTION 'FAIL: created a hold in another traveller''s name';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- ── 5. Signed out sees no holds at all ────────────────────────────────────
  -- `user_id = app_user_id()` is NULL when nobody is signed in, and NULL is
  -- not true. Fails closed, which is the only acceptable direction.
  PERFORM set_config('app.user_id', '', true);
  SELECT count(*) INTO visible FROM holds;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: an anonymous connection saw % holds', visible;
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  public sales boundary (7 checks)';
END
$$;

-- ── 6. Least privilege is a grant list, not a policy ────────────────────────
--
-- Policies decide which ROWS. Grants decide which TABLES exist at all for
-- this role — and that is the defence that survives a SQL injection in a
-- public handler, because no crafted query can reach a table the role was
-- never granted.
DO $$
DECLARE
  t        TEXT;
  reachable TEXT[] := '{}';
  forbidden TEXT[] := ARRAY[
    'operator_staff', 'platform_staff', 'kyb_documents',
    'ledger_entries', 'payment_events', 'audit_log',
    'refunds', 'refund_policies',
    'vehicles', 'departure_patterns', 'redemptions'
  ];
BEGIN
  FOREACH t IN ARRAY forbidden LOOP
    IF has_table_privilege('bel_public', t, 'SELECT')
    OR has_table_privilege('bel_public', t, 'INSERT')
    OR has_table_privilege('bel_public', t, 'UPDATE')
    OR has_table_privilege('bel_public', t, 'DELETE') THEN
      reachable := reachable || t;
    END IF;
  END LOOP;

  IF cardinality(reachable) > 0 THEN
    RAISE EXCEPTION 'FAIL: the public role can reach %', reachable;
  END IF;

  -- `stations` left this list in 0008, and the reason is worth stating
  -- because it is the first time anything has: reserve-then-pay requires
  -- telling a traveller WHICH agency to walk into, and a list of addresses is
  -- exactly what the table holds. It was on the list originally by grouping
  -- rather than by analysis — unlike `vehicles`, which stayed off because it
  -- carries registration plates and `status = 'blocked_compliance'`, and
  -- unlike `operator_staff`, which is a list of people.
  --
  -- SELECT only. A traveller can read where an agency is and cannot write
  -- anything about it.
  IF has_table_privilege('bel_public', 'stations', 'INSERT')
  OR has_table_privilege('bel_public', 'stations', 'UPDATE')
  OR has_table_privilege('bel_public', 'stations', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: the public role can write to stations';
  END IF;

  -- `payment_intents` left the list in 0011, because a traveller has to be
  -- able to start their own payment and watch it. The property that matters
  -- is the one 0005 established for seats: there is no path from an internet
  -- request to a CAPTURED payment. The traveller may INSERT an intent and
  -- SELECT their own; every state transition afterwards is a system action
  -- under the operator or platform scope, after the rail has spoken.
  IF has_table_privilege('bel_public', 'payment_intents', 'UPDATE')
  OR has_table_privilege('bel_public', 'payment_intents', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: the public role can move a payment forward itself';
  END IF;

  -- And the raw rail payloads stay out of reach entirely: MSISDNs, merchant
  -- identifiers, whatever the telco chose to echo back.
  IF has_table_privilege('bel_public', 'payment_events', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: the public role can read raw PSP payloads';
  END IF;

  RAISE NOTICE 'OK  the public role cannot reach % restricted tables, may only read stations, and cannot advance a payment',
    cardinality(forbidden);
END
$$;

-- ── 7. Nothing here weakened the operator boundary ──────────────────────────
-- 0005 adds permissive policies, which are OR'd. The failure mode worth
-- checking is that one of them accidentally applies without app.public set —
-- which would hand every operator connection a second, wider view.
DO $$
DECLARE
  visible INT;
BEGIN
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.tenant_id', '22222222-2222-2222-2222-222222222222', true);

  -- Trans Bony Voyages owns no departures in this fixture. If a public policy
  -- leaked into the tenant path, it would see Ocean du Nord's.
  SELECT count(*) INTO visible FROM departures;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: a public policy leaked into an operator session (% rows)', visible;
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  operator isolation survives the public policies';
END
$$;

-- ── 8. An applicant may create a draft operator and may not approve it ──────
--
-- 0015 opens the narrowest write on `operators` the public role has ever
-- had, and the whole safety of it rests on two things: an INSERT policy that
-- pins `status`, and a *column-level* UPDATE grant. Column grants are easy to
-- widen by accident — `GRANT UPDATE ON operators` is one word shorter than
-- the correct statement — so the difference is executed here.
DO $$
DECLARE
  aline    TEXT := '55555555-5555-5555-5555-555555555551';
  serge    TEXT := '55555555-5555-5555-5555-555555555552';
  applied  UUID;
  visible  INT;
BEGIN
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', aline, true);

  -- The id is chosen before the row exists, and that is forced rather than
  -- stylistic: `INSERT … RETURNING id` also evaluates the SELECT policy, and
  -- the applicant's read is granted by the *application* row, which cannot
  -- exist until the operator does. Two statements and a generated id instead
  -- of one statement and a hole in the read policy.
  applied := gen_random_uuid();

  INSERT INTO operators (id, code, legal_name, market_code, status)
  VALUES (applied, 'APPLIC-001', 'Sotrapo SARL', 'CG', 'application_draft');

  INSERT INTO operator_applications (operator_id, applicant_user_id)
  VALUES (applied, aline::UUID);

  -- Creating an operator that is already selling.
  BEGIN
    INSERT INTO operators (code, legal_name, market_code, status)
    VALUES ('APPLIC-002', 'Instant Success SARL', 'CG', 'active');
    RAISE EXCEPTION 'FAIL: the public role created an ACTIVE operator';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- Approving their own application.
  BEGIN
    UPDATE operators SET status = 'active' WHERE id = applied;
    RAISE EXCEPTION 'FAIL: an applicant approved their own application';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- Setting their own commission to nothing.
  BEGIN
    UPDATE operators SET commission_bps = 0 WHERE id = applied;
    RAISE EXCEPTION 'FAIL: an applicant set their own commission';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- What they may do: correct the name they typed.
  UPDATE operators SET legal_name = 'Sotrapo S.A.R.L.' WHERE id = applied;

  -- And somebody else's application is not theirs to read or to edit.
  PERFORM set_config('app.user_id', serge, true);

  SELECT count(*) INTO visible FROM operator_applications;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: an applicant saw % other applications', visible;
  END IF;

  UPDATE operators SET legal_name = 'Serge Transport' WHERE id = applied;
  IF FOUND THEN
    RAISE EXCEPTION 'FAIL: an applicant edited a stranger''s application';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  an applicant may draft an operator and may not approve, price or steal one';
END
$$;

-- ── 9. Review does not need the applicant's permission, and vice versa ──────
-- The reviewer works under bel_admin and must see every application; the
-- operator, once activated, sees exactly its own.
DO $$
DECLARE
  visible INT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.user_id', '', true);

  SELECT count(*) INTO visible FROM operator_applications;
  IF visible < 1 THEN
    RAISE EXCEPTION 'FAIL: the review queue cannot see applications';
  END IF;

  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', '22222222-2222-2222-2222-222222222222', true);

  SELECT count(*) INTO visible FROM operator_applications;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: an operator saw % applications that are not its own', visible;
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  the review queue sees every application and an operator sees only its own';
END
$$;

-- ── 10. A breakdown is public, and it is not editable afterwards ────────────
--
-- 0017 makes two claims that are easy to lose. The first is a grant: the
-- follower of a shared trip link holds no account, and if they cannot read
-- why the coach is late they phone the agency — which is the cost this
-- subsystem exists to remove. The second is the absence of a grant: the
-- record is the operator's own evidence in a dispute, and evidence that its
-- owner can edit afterwards is not evidence.
DO $$
DECLARE
  visible INT;
  declaration UUID := 'dddddddd-0000-0000-0000-000000000001';
BEGIN
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);

  INSERT INTO disruptions
    (id, operator_id, departure_id, kind, cause, note, marks_involuntary,
     bookings_affected)
  VALUES
    (declaration,
     '11111111-1111-1111-1111-111111111111',
     'cccccccc-0000-0000-0000-000000000001',
     'breakdown_en_route', 'mechanical', 'moteur, km 180 RN1', TRUE, 2);

  -- Resolving is allowed: that is the column the operator is meant to write.
  UPDATE disruptions SET resolved_at = now() WHERE id = declaration;

  -- Rewriting what was declared is not. The grant does not include the
  -- column, so this fails whatever the policies say.
  BEGIN
    UPDATE disruptions SET cause = 'weather' WHERE id = declaration;
    RAISE EXCEPTION 'FAIL: an operator rewrote a declared cause';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    DELETE FROM disruptions WHERE id = declaration;
    RAISE EXCEPTION 'FAIL: an operator deleted a breakdown record';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- And a signed-out follower can read it.
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '', true);

  SELECT count(*) INTO visible FROM disruptions WHERE id = declaration;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: a trip follower cannot see the disruption';
  END IF;

  -- Reading only. Declaring one is an operator's act.
  IF has_table_privilege('bel_public', 'disruptions', 'INSERT')
  OR has_table_privilege('bel_public', 'disruptions', 'UPDATE')
  OR has_table_privilege('bel_public', 'disruptions', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: the public role can declare or edit a disruption';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  a disruption is readable by anyone, editable by no one, and declared only by its operator';
END
$$;

-- ── 11. One open disruption per departure ───────────────────────────────────
-- "What is happening to my coach right now?" must have exactly one answer.
DO $$
BEGIN
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);

  INSERT INTO disruptions
    (operator_id, departure_id, kind, cause, marks_involuntary)
  VALUES
    ('11111111-1111-1111-1111-111111111111',
     'cccccccc-0000-0000-0000-000000000001', 'delay', 'checkpoint', FALSE);

  BEGIN
    INSERT INTO disruptions
      (operator_id, departure_id, kind, cause, marks_involuntary)
    VALUES
      ('11111111-1111-1111-1111-111111111111',
       'cccccccc-0000-0000-0000-000000000001', 'cancellation', 'no_vehicle', TRUE);
    RAISE EXCEPTION 'FAIL: a departure carries two open disruptions at once';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  a departure has at most one open disruption';
END
$$;
