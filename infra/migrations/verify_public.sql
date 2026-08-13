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
  held    TEXT;
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

  -- The seat is taken by writing the piece of road that is now occupied, not
  -- by setting a state: since 0036 no application role may write `seats` at
  -- all, and the state below is the trigger's answer rather than ours.
  INSERT INTO seat_occupancy (departure_id, seat_label, operator_id, span,
                              hold_id, held_until)
  SELECT 'cccccccc-0000-0000-0000-000000000001', '1A',
         '11111111-1111-1111-1111-111111111111', d.road_span,
         'dddddddd-0000-0000-0000-000000000001',
         now() + INTERVAL '15 minutes'
    FROM departures d WHERE d.id = 'cccccccc-0000-0000-0000-000000000001';

  SELECT state::text INTO held FROM seats
   WHERE departure_id = 'cccccccc-0000-0000-0000-000000000001'
     AND seat_label = '1A';
  IF held <> 'held' THEN
    RAISE EXCEPTION 'FAIL: a traveller''s claim left the seat %', held;
  END IF;

  -- ── 3. Selling is NOT ─────────────────────────────────────────────────────
  -- The single most important line in this file. If this check ever stops
  -- failing, an unauthenticated request can board a coach for free.
  --
  -- Two ways to try it now, and both are refused. Writing the state directly
  -- is refused by the grant that 0036 took away; writing occupancy with a
  -- booking behind it is refused by the policy, which lets a traveller write
  -- exactly one kind of row — a piece of a seat held under a hold of theirs.
  BEGIN
    UPDATE seats SET state = 'sold', hold_id = NULL,
                     booking_id = gen_random_uuid()
     WHERE departure_id = 'cccccccc-0000-0000-0000-000000000001'
       AND seat_label = '1A';
    RAISE EXCEPTION 'FAIL: the public role marked a seat sold';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: there is no UPDATE grant on seats to any app role
  END;

  BEGIN
    INSERT INTO seat_occupancy (departure_id, seat_label, operator_id, span,
                                booking_id)
    VALUES ('cccccccc-0000-0000-0000-000000000001', '1B',
            '11111111-1111-1111-1111-111111111111', '[0,1)', gen_random_uuid());
    RAISE EXCEPTION 'FAIL: the public role sold itself a seat';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: the policy insists on a hold, and on it being theirs
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
    -- `refunds` stays: what somebody was paid back, and the claim code that
    -- collects it, is not a term of sale. `refund_policies` left this list in
    -- 0024 and is checked below instead — the terms are printed on the
    -- departure screen before anybody buys, so a role that cannot read them
    -- cannot render the screen the spec asks for.
    'refunds',
    'vehicles', 'departure_patterns', 'redemptions',
    -- Commercial terms between two companies (0019), not a fact about a
    -- coach. A disruption is public; what two operators agreed to bill each
    -- other is not.
    'payout_runs', 'protection_agreements', 'protection_corridors',
    'protection_movements', 'protection_requests'
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

  -- `refund_policies` left the list in 0024. The terms a booking is judged by
  -- are published — §4.1 puts them on the departure screen before purchase
  -- and §8.2 quotes them on the cancellation sheet — so SELECT is granted
  -- across operators on purpose: somebody comparing two companies holds a
  -- booking under neither. Every write stays refused, which is the half of
  -- the claim that matters, because a traveller who could rewrite the terms
  -- could rewrite what they are owed.
  IF NOT has_table_privilege('bel_public', 'refund_policies', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: a traveller cannot read the terms of their sale';
  END IF;
  IF has_table_privilege('bel_public', 'refund_policies', 'INSERT')
  OR has_table_privilege('bel_public', 'refund_policies', 'UPDATE')
  OR has_table_privilege('bel_public', 'refund_policies', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: the public role can write refund policies';
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

-- ── 12. An operator cannot pay themselves ───────────────────────────────────
--
-- The claim 0018 rests on. Two-person control on money leaving (ADR-0011) is
-- worth nothing if the party being paid can insert a run, approve it, or
-- change the amount — so the grant gives `bel_app` SELECT and nothing else,
-- and this executes that rather than trusting the file to have said it.
DO $$
DECLARE
  visible INT;
  run UUID := 'eeeeeeee-0000-0000-0000-000000000001';
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO payout_runs
    (id, operator_id, period_start, period_end, currency,
     payable_minor, tills_minor, net_minor)
  VALUES
    (run, '11111111-1111-1111-1111-111111111111',
     now() - INTERVAL '7 days', now(), 'XAF', 3708000, 192000, 3516000);

  -- The operator may read their own statement. That is what it is for.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);

  SELECT count(*) INTO visible FROM payout_runs WHERE id = run;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: an operator cannot read their own statement';
  END IF;

  BEGIN
    UPDATE payout_runs SET state = 'approved' WHERE id = run;
    RAISE EXCEPTION 'FAIL: an operator approved their own payout';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    INSERT INTO payout_runs
      (operator_id, period_start, period_end, currency,
       payable_minor, tills_minor, net_minor)
    VALUES
      ('11111111-1111-1111-1111-111111111111',
       now() - INTERVAL '14 days', now() - INTERVAL '7 days',
       'XAF', 9000000, 0, 9000000);
    RAISE EXCEPTION 'FAIL: an operator raised their own payout run';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  an operator reads their statement and cannot move it';
END
$$;

-- ── 13. The same week cannot be paid twice ──────────────────────────────────
--
-- The one mistake in 0018 that cannot be undone with an UPDATE. A partial
-- unique index rather than a convention, and voided runs excluded so a
-- mistake can be voided and redone.
DO $$
DECLARE
  operator UUID := '11111111-1111-1111-1111-111111111111';
  window_start TIMESTAMPTZ := date_trunc('day', now() - INTERVAL '30 days');
  window_end   TIMESTAMPTZ := date_trunc('day', now() - INTERVAL '23 days');
  first_run UUID;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO payout_runs
    (operator_id, period_start, period_end, currency,
     payable_minor, tills_minor, net_minor)
  VALUES (operator, window_start, window_end, 'XAF', 100000, 0, 100000)
  RETURNING id INTO first_run;

  BEGIN
    INSERT INTO payout_runs
      (operator_id, period_start, period_end, currency,
       payable_minor, tills_minor, net_minor)
    VALUES (operator, window_start, window_end, 'XAF', 100000, 0, 100000);
    RAISE EXCEPTION 'FAIL: the same week was paid twice';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Voiding the first releases the week, so a mistake can be redone.
  UPDATE payout_runs SET state = 'void' WHERE id = first_run;

  INSERT INTO payout_runs
    (operator_id, period_start, period_end, currency,
     payable_minor, tills_minor, net_minor)
  VALUES (operator, window_start, window_end, 'XAF', 100000, 0, 100000);

  RESET ROLE;
  RAISE NOTICE 'OK  one payout per operator per week, and a void reopens it';
END
$$;

-- ── 14. An agreement belongs to two tenants, and to no third ────────────────
--
-- The only widening of tenant isolation in this schema (0019). Every other
-- operator table answers to one `app_tenant_id()`; this one answers to two,
-- because an agreement neither party can read is not an agreement. A widening
-- is exactly the kind of thing that quietly grows, so the boundary is executed
-- here: both parties see it, a third operator does not, and neither party can
-- bind two companies they are not one of.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  bony  UUID := '22222222-2222-2222-2222-222222222222';
  agr   UUID := 'dddddddd-0000-0000-0000-000000000001';
  third UUID := 'dddddddd-0000-0000-0000-0000000000ff';
  seen  INT;
  low   UUID := LEAST('11111111-1111-1111-1111-111111111111'::uuid,
                      '22222222-2222-2222-2222-222222222222'::uuid);
  high  UUID := GREATEST('11111111-1111-1111-1111-111111111111'::uuid,
                         '22222222-2222-2222-2222-222222222222'::uuid);
BEGIN
  INSERT INTO operators (id, code, legal_name, market_code, status)
  VALUES (third, 'THR', 'Third Party Transport', 'CG', 'active');

  -- Océan du Nord proposes.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  INSERT INTO protection_agreements
    (id, operator_a, operator_b, proposed_by, rebill_discount_bps,
     monthly_cap_seats)
  VALUES (agr, low, high, ocean, 1500, 40);

  INSERT INTO protection_corridors (agreement_id, city_low, city_high)
  VALUES (agr, 'BZV', 'PNR');

  -- An operator cannot bind two companies they are not a party to. This is
  -- the WITH CHECK, and without it the widening above would be a hole.
  BEGIN
    INSERT INTO protection_agreements (operator_a, operator_b, proposed_by)
    VALUES (LEAST(bony, third), GREATEST(bony, third), bony);
    RAISE EXCEPTION 'FAIL: an operator bound two other companies';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    NULL;
  END;

  -- Trans Bony, the counterparty, sees it. That is the point of the widening.
  PERFORM set_config('app.tenant_id', bony::text, true);
  SELECT count(*) INTO seen FROM protection_agreements WHERE id = agr;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the counterparty cannot see the agreement';
  END IF;

  SELECT count(*) INTO seen FROM protection_corridors WHERE agreement_id = agr;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the counterparty cannot see the corridors';
  END IF;

  -- A third operator sees nothing at all.
  PERFORM set_config('app.tenant_id', third::text, true);
  SELECT count(*) INTO seen FROM protection_agreements WHERE id = agr;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a stranger read two companies terms';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  an agreement is readable by both parties and by no third';
END
$$;

-- ── 15. The terms are frozen once the other party has agreed ────────────────
--
-- 0019 decision 2. The discount is what one operator bills the other under,
-- so it cannot move after acceptance — a column-level grant rather than a
-- handler, which is what makes it hold against code written next year.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  bony  UUID := '22222222-2222-2222-2222-222222222222';
  agr   UUID := 'dddddddd-0000-0000-0000-000000000001';
  live  INT;
BEGIN
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', bony::text, true);

  -- The counterparty accepts. State and the acceptance stamp are granted.
  UPDATE protection_agreements
     SET state = 'active', accepted_at = now()
   WHERE id = agr;

  BEGIN
    UPDATE protection_agreements SET rebill_discount_bps = 0 WHERE id = agr;
    RAISE EXCEPTION 'FAIL: the rebill rate was changed after acceptance';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    UPDATE protection_agreements SET monthly_cap_seats = 9999 WHERE id = agr;
    RAISE EXCEPTION 'FAIL: the monthly ceiling was raised after acceptance';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- And an agreement is not something either party makes disappear.
  BEGIN
    DELETE FROM protection_agreements WHERE id = agr;
    RAISE EXCEPTION 'FAIL: an agreement was deleted';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- Two operators have at most one live agreement: a second would be two
  -- rates for the same seat with no way to say which was meant.
  BEGIN
    PERFORM set_config('app.tenant_id', ocean::text, true);
    INSERT INTO protection_agreements (operator_a, operator_b, proposed_by)
    VALUES (LEAST(ocean, bony), GREATEST(ocean, bony), ocean);
    RAISE EXCEPTION 'FAIL: a second live agreement was written';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  SELECT count(*) INTO live FROM protection_agreements
   WHERE id = agr AND state = 'active' AND rebill_discount_bps = 1500;
  IF live <> 1 THEN
    RAISE EXCEPTION 'FAIL: the accepted terms are not the proposed ones';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  accepted terms are frozen, and a pair has one agreement';
END
$$;

-- ── 16. The receiving operator answers, and nobody else ─────────────────────
--
-- 0020 decision 2. A protection request is the one row in this schema written
-- by one tenant and answered by another, so "who may move it" is the whole
-- control: the sender asks and cannot answer their own ask, the receiver
-- answers and cannot rewrite what they were asked.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  bony  UUID := '22222222-2222-2222-2222-222222222222';
  agr   UUID := 'dddddddd-0000-0000-0000-000000000001';
  broken UUID := 'cccccccc-0000-0000-0000-000000000001';
  spare  UUID := 'cccccccc-0000-0000-0000-00000000000b';
  req    UUID := 'eeeeeeee-1111-0000-0000-000000000001';
  seen   INT;
BEGIN
  -- A coach belonging to the other company, to be asked for.
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO seat_layouts (id, operator_id, name, sections, capacity)
  VALUES ('bbbbbbbb-0000-0000-0000-00000000000b', bony, 'Their coach',
          '[]'::jsonb, 40);

  INSERT INTO routes (id, operator_id, origin_city, destination_city,
                      code, duration_minutes)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000b', bony, 'BZV', 'PNR',
          'TBV-BZV-PNR', 450);

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency)
  VALUES (spare, bony, 'aaaaaaaa-0000-0000-0000-00000000000b',
          'bbbbbbbb-0000-0000-0000-00000000000b',
          now() + INTERVAL '2 days 6 hours', now() + INTERVAL '2 days 14 hours',
          40, 9000, 'XAF');

  -- Océan du Nord, whose coach has failed, asks.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  INSERT INTO protection_requests
    (id, agreement_id, sending_operator_id, receiving_operator_id,
     from_departure_id, to_departure_id, seats_requested)
  VALUES (req, agr, ocean, bony, broken, spare, 31);

  -- And cannot answer their own ask. The UPDATE policy is a USING clause, so
  -- the row is invisible to the statement rather than the statement being
  -- refused — which means the assertion is that nothing moved, not that
  -- something raised. Worth writing out: a silent zero-row UPDATE is exactly
  -- the kind of control that reads as working and is not tested.
  UPDATE protection_requests
     SET state = 'accepted', decided_at = now() WHERE id = req;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*) INTO seen
    FROM protection_requests WHERE id = req AND state = 'pending';
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: an operator accepted their own protection request';
  END IF;

  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  -- Nor ask on somebody else's behalf.
  BEGIN
    INSERT INTO protection_requests
      (agreement_id, sending_operator_id, receiving_operator_id,
       from_departure_id, to_departure_id, seats_requested)
    VALUES (agr, bony, ocean, spare, broken, 5);
    RAISE EXCEPTION 'FAIL: an operator asked on another company''s behalf';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- The receiver sees it, which is the inbound queue §2.3 asks for.
  PERFORM set_config('app.tenant_id', bony::text, true);
  SELECT count(*) INTO seen FROM protection_requests WHERE id = req;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the receiving operator cannot see the request';
  END IF;

  -- Answers it.
  UPDATE protection_requests
     SET state = 'accepted', decided_at = now() WHERE id = req;

  -- And cannot rewrite what they were asked for.
  BEGIN
    UPDATE protection_requests SET seats_requested = 1 WHERE id = req;
    RAISE EXCEPTION 'FAIL: the receiver rewrote the request';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- A third company sees nothing.
  PERFORM set_config('app.tenant_id', 'dddddddd-0000-0000-0000-0000000000ff',
                     true);
  SELECT count(*) INTO seen FROM protection_requests WHERE id = req;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a stranger read a protection request';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  a protection request is asked by one side and answered by the other';
END
$$;

-- ── 17. The two-tenant queue widens nothing ─────────────────────────────────
--
-- 0022. A request names two coaches owned by two companies, and neither
-- tenant can read both `departures` rows — so the queue is assembled by a
-- SECURITY DEFINER function, and a definer function is the one construct here
-- that can hand somebody another tenant's rows by accident.
--
-- What is checked is that it did not: the function takes no operator argument
-- and reads `app_tenant_id()` itself, so the two parties each see the request
-- and a third company calling exactly the same function sees nothing. If this
-- ever fails, a competitor is reading who is rescuing whom.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  bony  UUID := '22222222-2222-2222-2222-222222222222';
  req   UUID := 'eeeeeeee-1111-0000-0000-000000000001';
  seen  INT;
  free  INT;
BEGIN
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);

  -- The company that asked sees their own ask, and the counterparty named on
  -- it is the other one.
  PERFORM set_config('app.tenant_id', ocean::text, true);
  SELECT count(*) INTO seen
    FROM protection_queue() q WHERE q.id = req AND q.counterparty_id = bony;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the sending operator cannot read their own request';
  END IF;

  -- The company being asked sees it too, with the seat count §2.3 says they
  -- need to answer — read from a coach the asker cannot read at all.
  PERFORM set_config('app.tenant_id', bony::text, true);
  SELECT count(*), max(q.seats_free) INTO seen, free
    FROM protection_queue() q WHERE q.id = req AND q.counterparty_id = ocean;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the receiving operator cannot read the request';
  END IF;
  IF free IS NULL THEN
    RAISE EXCEPTION 'FAIL: the queue carries no seat count';
  END IF;

  -- And a third company sees nothing, calling the same function.
  PERFORM set_config('app.tenant_id', 'dddddddd-0000-0000-0000-0000000000ff',
                     true);
  SELECT count(*) INTO seen FROM protection_queue() q;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a stranger read the protection queue';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  the protection queue is scoped to its two parties';
END
$$;

-- ── 18. A follower learns about a coach, never about a passenger ────────────
--
-- 0023. The one read in this system performed by somebody with no account at
-- all: a relative in Pointe-Noire, holding a WhatsApp link, watching a coach
-- cross the RN1 (ADR-0014 §2). It runs through a SECURITY DEFINER function
-- because a SELECT policy on `trip_shares` would be all-columns and
-- row-enumerable — `bel_public` could walk every share that exists.
--
-- Four things are checked, and each is a way this could leak:
--
--   * the function answers for a token it holds, and answers **nothing** for
--     one it does not, so a link cannot be guessed into existence;
--   * `bel_public` cannot read the table directly with a bare SELECT that
--     returns somebody else's row — the policy is scoped to the purchaser;
--   * the columns coming back carry no seat, no reference, no fare and no
--     phone number, which is asserted against the function's own signature so
--     that adding one is a decision rather than an accident;
--   * the open counter moves for a live link and does **not** move for a
--     revoked one, because a revoked link being polled by a page somebody
--     left open must not keep inflating the number the traveller reads.
DO $$
DECLARE
  ocean   UUID := '11111111-1111-1111-1111-111111111111';
  dep     UUID := 'dddddddd-1111-0000-0000-00000000f001';
  bk      UUID := 'bbbbbbbb-1111-0000-0000-00000000f001';
  buyer   UUID := 'aaaaaaaa-1111-0000-0000-00000000f001';
  live    TEXT := 'hash-of-a-live-token';
  dead    TEXT := 'hash-of-a-revoked-token';
  seen    INT;
  tally   INT;
  leaked  TEXT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO user_accounts (id, email, language)
  VALUES (buyer, 'follower-check@example.cg', 'fr')
  ON CONFLICT DO NOTHING;

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency)
  SELECT dep, ocean, r.id, l.id,
         now() - INTERVAL '2 hours', now() + INTERVAL '6 hours',
         49, 12000, 'XAF'
    FROM routes r, seat_layouts l
   WHERE r.operator_id = ocean AND l.operator_id = ocean
   LIMIT 1;

  INSERT INTO bookings
    (id, ref, operator_id, departure_id, purchaser_user_id, state,
     fare_minor, service_fee_minor, total_minor, currency, payment_method,
     paid_at)
  VALUES (bk, 'BELF01', ocean, dep, buyer, 'confirmed',
          12000, 300, 12300, 'XAF', 'mobile_money', now());

  -- The traveller shares it, through the public surface they already hold a
  -- session on. Platform staff cannot: there is no grant, because a support
  -- agent handing out a link to a stranger's journey is not a power this
  -- needs to have.
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.user_id', buyer::text, true);

  INSERT INTO trip_shares
    (booking_id, departure_id, operator_id, token_hash, expires_at, revoked_at)
  VALUES (bk, dep, ocean, dead, now() + INTERVAL '12 hours', now());

  INSERT INTO trip_shares
    (booking_id, departure_id, operator_id, token_hash, expires_at)
  VALUES (bk, dep, ocean, live, now() + INTERVAL '12 hours');

  -- Somebody else's booking is not theirs to share.
  BEGIN
    PERFORM set_config('app.user_id',
                       '99999999-9999-9999-9999-999999999999', true);
    INSERT INTO trip_shares
      (booking_id, departure_id, operator_id, token_hash, expires_at)
    VALUES (bk, dep, ocean, 'hash-of-a-stolen-share',
            now() + INTERVAL '12 hours');
    RAISE EXCEPTION 'FAIL: a stranger shared somebody else''s trip';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- ── The follower: anonymous, no tenant, no user, no session at all.
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '', true);

  SELECT count(*) INTO seen FROM followed_trip(live);
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a live link does not resolve for a follower';
  END IF;

  SELECT count(*) INTO seen FROM followed_trip('hash-of-a-token-nobody-issued');
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: an unissued token resolved to a trip';
  END IF;

  -- A bare SELECT sees nothing: the policy is scoped to the booking's
  -- purchaser, and a follower is not one.
  SELECT count(*) INTO seen FROM trip_shares;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: the public role can enumerate trip shares';
  END IF;

  -- Nothing about the passenger comes back. Asserted against the function's
  -- signature rather than against one row, so a column added next year fails
  -- here rather than shipping.
  SELECT string_agg(p.parameter_name, ',') INTO leaked
    FROM information_schema.parameters p
    JOIN information_schema.routines r
      ON r.specific_name = p.specific_name
   WHERE r.routine_name = 'followed_trip'
     AND p.parameter_mode = 'OUT'
     AND p.parameter_name ~ 'seat|ref|fare|price|minor|phone|msisdn|name'
     AND p.parameter_name NOT IN ('operator_name');
  IF leaked IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: the follower page exposes %', leaked;
  END IF;

  -- The tally moves, once per open, so "3 personnes ont ouvert ce lien" on
  -- the traveller's screen means what it says.
  PERFORM count(*) FROM followed_trip(live);

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT opens INTO tally FROM trip_shares WHERE token_hash = live;
  IF tally <> 2 THEN
    RAISE EXCEPTION 'FAIL: opens counted % times for two opens', tally;
  END IF;

  -- And not for a revoked one, however often it is polled.
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  SELECT count(*) INTO seen FROM followed_trip(dead);
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT opens INTO tally FROM trip_shares WHERE token_hash = dead;
  IF tally <> 0 THEN
    RAISE EXCEPTION 'FAIL: a revoked link still counts opens';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  a follower learns about a coach, never about a passenger';
END
$$;

-- ── 19. A traveller reads the terms and can never rewrite them ──────────────
--
-- 0024. The cancellation sheet quotes the policy the booking was sold under
-- (§8.2), which means the public role now reads `refund_policies` — the first
-- widening of that role since the sales boundary was drawn, and therefore
-- worth an executed guarantee rather than a comment.
--
-- Three claims, in the order they would break:
--
--   * the terms are readable by `bel_public`, because a sheet that cannot
--     quote them shows a number with no explanation beside it;
--   * they are readable across operators, deliberately — somebody comparing
--     two companies before buying holds a booking under neither;
--   * and every write is refused. The table is append-only for the roles that
--     can write it at all (0014); this asserts the public role is not one of
--     them, which is a different statement and the one that matters here.
DO $$
DECLARE
  ocean  UUID := '11111111-1111-1111-1111-111111111111';
  other  UUID := '22222222-2222-2222-2222-222222222222';
  pid    UUID := 'ffffffff-2222-0000-0000-00000000f001';
  qid    UUID := 'ffffffff-2222-0000-0000-00000000f002';
  seen   INT;
BEGIN
  RESET ROLE;
  PERFORM set_config('app.platform', 'on', true);
  SET LOCAL ROLE bel_admin;

  INSERT INTO refund_policies
    (id, version, operator_id, name, tiers, destination, processing_hours)
  VALUES
    (pid, 1, ocean, 'Souple',
     '[{"minLeadTimeMinutes": 1440, "rateBps": 10000}]'::jsonb, 'agencyCash',
     72),
    (qid, 1, other, 'Stricte', '[]'::jsonb, 'source', 72);

  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  SELECT count(*) INTO seen FROM refund_policies WHERE id IN (pid, qid);
  IF seen <> 2 THEN
    RAISE EXCEPTION
      'FAIL: a traveller reads % of 2 published policies', seen;
  END IF;

  -- Writing is refused, in all three directions. Caught individually so a
  -- future migration that grants one of them fails on the specific verb.
  BEGIN
    INSERT INTO refund_policies
      (id, version, operator_id, name, tiers, destination, processing_hours)
    VALUES (gen_random_uuid(), 1, ocean, 'Forgée', '[]'::jsonb, 'source', 72);
    RAISE EXCEPTION 'FAIL: a traveller wrote a refund policy';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    UPDATE refund_policies SET name = 'Réécrite' WHERE id = pid;
    RAISE EXCEPTION 'FAIL: a traveller rewrote the terms of a sale';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    DELETE FROM refund_policies WHERE id = pid;
    RAISE EXCEPTION 'FAIL: a traveller deleted the terms of a sale';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  a traveller reads the terms and can never rewrite them';
END
$$;

-- ── 20. A traveller reads their own change order and writes none ────────────
--
-- A change order holds seats on a departure and states what is owed for them.
-- Both of those are the platform role's business: the seats come out of an
-- inventory somebody else is also selling, and the amount is computed from
-- terms the traveller cannot see the inputs of. So the public grant is SELECT
-- and nothing else — and the row it can select is its own.
DO $$
DECLARE
  ocean   UUID := '11111111-1111-1111-1111-111111111111';
  buyer   UUID := 'aaaaaaaa-1111-0000-0000-00000000f002';
  other   UUID := 'aaaaaaaa-1111-0000-0000-00000000f003';
  dep_a   UUID := 'ffffffff-3333-0000-0000-00000000f001';
  dep_b   UUID := 'ffffffff-3333-0000-0000-00000000f002';
  bk      UUID := 'ffffffff-3333-0000-0000-00000000f003';
  chg     UUID := 'ffffffff-3333-0000-0000-00000000f004';
  seen    INT;
BEGIN
  RESET ROLE;
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO user_accounts (id, email, language) VALUES
    (buyer, 'change-buyer@example.cg', 'fr'),
    (other, 'change-stranger@example.cg', 'fr')
  ON CONFLICT DO NOTHING;

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency)
  SELECT d.id, ocean, r.id, l.id,
         now() + d.offset_hours, now() + d.offset_hours + INTERVAL '6 hours',
         49, 12000, 'XAF'
    FROM routes r, seat_layouts l,
         (VALUES (dep_a, INTERVAL '30 hours'), (dep_b, INTERVAL '54 hours'))
           AS d(id, offset_hours)
   WHERE r.operator_id = ocean AND l.operator_id = ocean
   LIMIT 2;

  INSERT INTO bookings
    (id, ref, operator_id, departure_id, purchaser_user_id, state,
     fare_minor, service_fee_minor, total_minor, currency, payment_method,
     paid_at)
  VALUES (bk, 'BELC01', ocean, dep_a, buyer, 'confirmed',
          12000, 300, 12300, 'XAF', 'mobile_money', now());

  -- Written by the platform role, which is the only one that may: the read
  -- surface below is the whole of what a traveller gets.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'on', true);

  INSERT INTO booking_changes
    (id, booking_id, operator_id, from_departure_id, to_departure_id,
     seat_labels, fee_minor, difference_minor, owed_minor, currency,
     created_by, expires_at)
  VALUES (chg, bk, ocean, dep_a, dep_b, ARRAY['1A'], 1200, 3000, 4200, 'XAF',
          buyer, now() + INTERVAL '15 minutes');

  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.user_id', buyer::text, true);

  SELECT count(*) INTO seen FROM booking_changes WHERE id = chg;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a traveller cannot read their own change order';
  END IF;

  -- Somebody else's is not theirs to read, and the answer is an empty row
  -- rather than a refusal: a stranger's order and one that never existed are
  -- deliberately the same.
  PERFORM set_config('app.user_id', other::text, true);
  SELECT count(*) INTO seen FROM booking_changes WHERE id = chg;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a stranger read somebody else''s change order';
  END IF;

  PERFORM set_config('app.user_id', buyer::text, true);

  -- Writing is refused in every direction. An order a client could write is
  -- an order a client could price.
  BEGIN
    INSERT INTO booking_changes
      (booking_id, operator_id, from_departure_id, to_departure_id,
       seat_labels, owed_minor, currency, created_by, expires_at)
    VALUES (bk, ocean, dep_a, dep_b, ARRAY['2A'], 1, 'XAF', buyer,
            now() + INTERVAL '15 minutes');
    RAISE EXCEPTION 'FAIL: a traveller wrote their own change order';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    UPDATE booking_changes SET owed_minor = 1 WHERE id = chg;
    RAISE EXCEPTION 'FAIL: a traveller repriced their own change';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    DELETE FROM booking_changes WHERE id = chg;
    RAISE EXCEPTION 'FAIL: a traveller deleted a change order';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  a traveller reads their own change order and writes none';
END
$$;

-- ── 21. A closed terminal is not an address a stranger is sent to ───────────
--
-- The operator keeps reading it — last month's departures still have to say
-- where their passengers were told to stand — but the public surface stops
-- offering a yard nobody boards at any more.
DO $$
DECLARE
  open_id   UUID;
  closed_id UUID;
  seen      INT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);

  INSERT INTO stations (operator_id, city_code, name, active)
  VALUES ('11111111-1111-1111-1111-111111111111', 'BZV', 'Gare de Kinsoundi', TRUE)
  RETURNING id INTO open_id;

  INSERT INTO stations (operator_id, city_code, name, active)
  VALUES ('11111111-1111-1111-1111-111111111111', 'BZV', 'Ancienne gare', FALSE)
  RETURNING id INTO closed_id;

  RESET ROLE;
  -- Platform back off before the traveller looks. `app_is_platform()` is a
  -- permissive OR in the tenant policy, so leaving it on would have this
  -- block read as our own back office and pass for the wrong reason.
  PERFORM set_config('app.platform', 'off', true);
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);

  SELECT count(*) INTO seen FROM stations WHERE id = open_id;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a traveller cannot read an open terminal';
  END IF;

  SELECT count(*) INTO seen FROM stations WHERE id = closed_id;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a closed terminal is offered to a traveller';
  END IF;

  BEGIN
    INSERT INTO stations (operator_id, city_code, name)
    VALUES ('11111111-1111-1111-1111-111111111111', 'BZV', 'Gare fantome');
    RAISE EXCEPTION 'FAIL: a traveller invented a station';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  a traveller reads open terminals, not closed ones, and writes none';
END
$$;

-- ── Waiting for a seat ────────────────────────────────────────────────────────
--
-- An alert is a row of intent on a coach that is full. Three things have to be
-- true of it, and none of them can be enforced in a handler:
--
--   * asking twice is asking once — a partial unique index, because two taps
--     on a bad connection are the ordinary case and two rows are two messages;
--   * withdrawing frees the slot to ask again, because somebody who changed
--     their mind twice is a normal person, not a constraint violation;
--   * one traveller cannot see another's. Who is waiting for a seat on the
--     06:00 is a list of people who want to travel, and it is nobody's list
--     but their own.
DO $$
DECLARE
  aline UUID := '55555555-5555-5555-5555-555555555551';
  serge UUID := '55555555-5555-5555-5555-555555555552';
  trip  UUID := 'dddddddd-0000-0000-0000-000000000031';
  mine  UUID;
  seen  INT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);

  INSERT INTO departures (id, operator_id, route_id, seat_layout_id, departs_at,
                          arrives_at, capacity, fare_minor, currency, status)
  VALUES (trip, '11111111-1111-1111-1111-111111111111',
          'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          now() + INTERVAL '3 days', now() + INTERVAL '3 days 8 hours',
          4, 12000, 'XAF', 'scheduled');

  -- A party of seven is not a party this product sells to. Asserted here,
  -- under the platform role, so the CHECK is what refuses it rather than a
  -- row-level policy arriving first.
  BEGIN
    INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
    VALUES (trip, serge, 7);
    RAISE EXCEPTION 'FAIL: an alert was taken for a party nobody can sell';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  RESET ROLE;
  PERFORM set_config('app.platform', 'off', true);
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.user_id', aline::text, true);

  INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
  VALUES (trip, aline, 2)
  RETURNING id INTO mine;

  -- Asked twice on a connection that dropped. One row.
  BEGIN
    INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
    VALUES (trip, aline, 1);
    RAISE EXCEPTION 'FAIL: one traveller is waiting twice for one coach';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected
  END;

  -- Sent and withdrawn at once is a row that means two things.
  BEGIN
    UPDATE seat_alerts SET notified_at = now(), cancelled_at = now()
     WHERE id = mine;
    RAISE EXCEPTION 'FAIL: an alert was both sent and withdrawn';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  -- Withdrawing frees the slot. The index is over *live* alerts only.
  UPDATE seat_alerts SET cancelled_at = now() WHERE id = mine;
  INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
  VALUES (trip, aline, 4);

  -- Somebody else waiting on the same coach.
  PERFORM set_config('app.user_id', serge::text, true);
  INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
  VALUES (trip, serge, 1);

  SELECT count(*) INTO seen FROM seat_alerts;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a traveller reads % alerts, only one is theirs', seen;
  END IF;

  -- And cannot wait on somebody else's behalf.
  BEGIN
    INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
    VALUES (trip, aline, 1);
    RAISE EXCEPTION 'FAIL: a traveller signed somebody else up for an alert';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  RESET ROLE;
  RAISE NOTICE 'OK  an alert is asked once, withdrawn freely, and read by nobody else';
END
$$;

-- ── The towns on the road ─────────────────────────────────────────────────────
--
-- `route_stops` has existed since migration 0001 and nothing had ever written
-- to it. Now the console does, so the boundary is worth executing rather than
-- assuming:
--
--   * a traveller reads the stops — they are on the search row — and writes
--     none, because a road is the operator's description of their own service;
--   * a company reads its own road's stops and not a competitor's, which is
--     the policy inherited through the route rather than a WHERE clause;
--   * `sequence` is unique per road, because a segment will be a pair of
--     positions in that sequence and two stops at position 2 have no order.
DO $$
DECLARE
  road  UUID := 'aaaaaaaa-0000-0000-0000-000000000001';
  other UUID := 'aaaaaaaa-0000-0000-0000-000000000002';
  seen  INT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);

  INSERT INTO cities (code, market_code, name_fr, name_en)
  VALUES ('DOL', 'CG', 'Dolisie', 'Dolisie')
  ON CONFLICT (code) DO NOTHING;

  INSERT INTO route_stops (route_id, city_code, sequence, offset_minutes)
  VALUES (road, 'DOL', 1, 315);

  -- Two stops cannot share a position. The whole point of the column is that
  -- it can be compared.
  BEGIN
    INSERT INTO route_stops (route_id, city_code, sequence, offset_minutes)
    VALUES (road, 'BZV', 1, 100);
    RAISE EXCEPTION 'FAIL: two stops share one position on one road';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected
  END;

  -- The competitor's own road, so the isolation check below has something to
  -- fail to see.
  INSERT INTO route_stops (route_id, city_code, sequence, offset_minutes)
  VALUES (other, 'DOL', 1, 320);

  RESET ROLE;
  PERFORM set_config('app.platform', 'off', true);

  -- ── The traveller ──
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);

  SELECT count(*) INTO seen FROM route_stops WHERE route_id = road;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a traveller cannot read the towns on the road';
  END IF;

  BEGIN
    INSERT INTO route_stops (route_id, city_code, sequence, offset_minutes)
    VALUES (road, 'PNR', 9, 400);
    RAISE EXCEPTION 'FAIL: a traveller added a stop to somebody''s road';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);

  -- ── The competitor ──
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.tenant_id',
                     '11111111-1111-1111-1111-111111111111', true);

  SELECT count(*) INTO seen FROM route_stops WHERE route_id = other;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: one company reads another company''s road';
  END IF;

  SELECT count(*) INTO seen FROM route_stops WHERE route_id = road;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: a company cannot read its own road';
  END IF;

  RESET ROLE;
  RAISE NOTICE 'OK  a road is read by everyone, described by its operator alone';
END
$$;

-- ── 11. A block the blocked party cannot lift ───────────────────────────────
--
-- The compliance pass stops an operator selling when a licence lapses
-- (03-operator-lifecycle.md §3.3). The whole enforcement rests on one
-- question: can the operator undo it from its own console? RLS cannot answer
-- that — the tenant policy exists precisely to let a company write its own
-- row — so the answer is a column grant, and this executes it.
DO $$
DECLARE
  tenant CONSTANT UUID := '11111111-1111-1111-1111-111111111111';
  seen   INT;
BEGIN
  PERFORM set_config('app.platform', 'on', true);
  SET LOCAL ROLE bel_admin;

  UPDATE operators
     SET sales_blocked_at = now(), sales_blocked_doc = 'fleet_insurance'
   WHERE id = tenant;

  RESET ROLE;
  PERFORM set_config('app.platform', 'off', true);

  -- ── The operator, in its own console ──
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.tenant_id', tenant::text, true);

  -- It can see it. Being told why sales stopped is the point of the banner.
  SELECT count(*) INTO seen
    FROM operators WHERE id = tenant AND sales_blocked_at IS NOT NULL;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: an operator cannot read its own block';
  END IF;

  BEGIN
    UPDATE operators SET sales_blocked_at = NULL WHERE id = tenant;
    RAISE EXCEPTION 'FAIL: an operator lifted its own sales block';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- The same grant is what stops the two older holes on this table.
  BEGIN
    UPDATE operators SET commission_bps = 0 WHERE id = tenant;
    RAISE EXCEPTION 'FAIL: an operator set its own commission to zero';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  BEGIN
    UPDATE operators SET status = 'active' WHERE id = tenant;
    RAISE EXCEPTION 'FAIL: an operator wrote its own lifecycle state';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- And the band the auto-review pass writes (0033). An applicant who could
  -- set their own to `low` is an applicant who approves themselves, which is
  -- the one thing that must be impossible on a self-signup path.
  BEGIN
    UPDATE operators SET risk_band = 'low' WHERE id = tenant;
    RAISE EXCEPTION 'FAIL: an operator wrote its own risk band';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- What it MAY write: its own shop window, and nothing else.
  UPDATE operators SET tagline_fr = 'Le confort à chaque voyage'
   WHERE id = tenant;

  RESET ROLE;

  -- ── The applicant, mid-wizard ──
  --
  -- `bel_public` genuinely may write four columns of this table (0015) — it
  -- is how the wizard saves — so the interesting question is the fifth.
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);

  BEGIN
    UPDATE operators SET risk_band = 'low' WHERE id = tenant;
    RAISE EXCEPTION 'FAIL: an applicant graded their own application';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);

  -- ── Put it back, so the rest of this file finds the world it expects ──
  PERFORM set_config('app.platform', 'on', true);
  SET LOCAL ROLE bel_admin;
  UPDATE operators
     SET sales_blocked_at = NULL, sales_blocked_doc = NULL
   WHERE id = tenant;
  RESET ROLE;
  PERFORM set_config('app.platform', 'off', true);

  RAISE NOTICE 'OK  an operator reads its sales block, and grades neither it nor itself';
END
$$;

-- ── 22. An open call is broadcast to a road, not to a bulletin board ────────
--
-- 0034. The first protection path where the row is deliberately readable by
-- companies that have no relationship with the sender at all, which makes
-- "who was invited" the entire control — and it is computed in a policy, not
-- asserted by a handler. Four conditions, each of which is somebody's
-- afternoon convenience away from being dropped, so each is executed here.
DO $$
DECLARE
  ocean  UUID := '11111111-1111-1111-1111-111111111111';
  bony   UUID := '22222222-2222-2222-2222-222222222222';
  niari  UUID := '33333333-3333-3333-3333-333333333333';
  broken UUID := 'cccccccc-0000-0000-0000-000000000001';
  call   UUID := 'ffffffff-0000-0000-0000-000000000001';
  seen   INT;
BEGIN
  -- A third company that runs the other direction only.
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO operators (id, code, legal_name, market_code, status)
  VALUES (niari, 'NIA', 'Niari Express', 'CG', 'active');

  INSERT INTO routes (id, operator_id, origin_city, destination_city,
                      code, duration_minutes)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000003', niari, 'PNR', 'BZV',
          'NIA-PNR-BZV', 460);

  -- ── Opting in is the company's own decision, made by the company ──
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);

  PERFORM set_config('app.tenant_id', bony::text, true);
  UPDATE operators SET open_protection_at = now() WHERE id = bony;

  PERFORM set_config('app.tenant_id', niari::text, true);
  UPDATE operators SET open_protection_at = now() WHERE id = niari;

  -- And not for somebody else. The column grant lets this statement through;
  -- the tenant policy is what makes it move nothing.
  UPDATE operators SET open_protection_at = NULL WHERE id = bony;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*) INTO seen
    FROM operators WHERE id = bony AND open_protection_at IS NOT NULL;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: an operator opted another company out';
  END IF;

  -- ── The call goes out, from the company whose coach has failed ──
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  INSERT INTO protection_calls
    (id, sending_operator_id, from_departure_id, origin_city,
     destination_city, seats_requested, rebill_minor, currency, expires_at)
  VALUES (call, ocean, broken, 'BZV', 'PNR', 31, 12000, 'XAF',
          now() + INTERVAL '2 hours');

  BEGIN
    INSERT INTO protection_calls
      (sending_operator_id, from_departure_id, origin_city, destination_city,
       seats_requested, rebill_minor, currency, expires_at)
    VALUES (bony, broken, 'BZV', 'PNR', 5, 12000, 'XAF',
            now() + INTERVAL '2 hours');
    RAISE EXCEPTION 'FAIL: an operator called for help in another company''s name';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- ── Who was invited ──
  --
  -- Opted in, active, selling, and on this road: the whole list, and all four
  -- matter. Bony is all four.
  PERFORM set_config('app.tenant_id', bony::text, true);
  SELECT count(*) INTO seen FROM protection_calls WHERE id = call;
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: an invited operator cannot see the call';
  END IF;

  -- Niari opted in and is active and selling, and runs PNR→BZV. A road is a
  -- direction. This is the difference between a broadcast and a bulletin
  -- board, and it is one EXISTS clause wide.
  PERFORM set_config('app.tenant_id', niari::text, true);
  SELECT count(*) INTO seen FROM protection_calls WHERE id = call;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a company that does not run the road saw the call';
  END IF;

  -- A company that never opted in sees nothing, which is the default and the
  -- reason the column is nullable.
  PERFORM set_config('app.tenant_id', 'dddddddd-0000-0000-0000-0000000000ff',
                     true);
  SELECT count(*) INTO seen FROM protection_calls WHERE id = call;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a company that never opted in saw the call';
  END IF;

  -- And a company blocked on its own paperwork stops being routed passengers
  -- the moment it is blocked (0032), without anybody editing this table.
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  UPDATE operators SET sales_blocked_at = now(), sales_blocked_doc = 'licence'
   WHERE id = bony;

  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', bony::text, true);
  SELECT count(*) INTO seen FROM protection_calls WHERE id = call;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: a blocked company was offered other people''s passengers';
  END IF;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  UPDATE operators SET sales_blocked_at = NULL, sales_blocked_doc = NULL
   WHERE id = bony;

  -- ── The terms are not writable, by either side ──
  --
  -- A price that moved while a console had the call open is a call nobody
  -- would answer twice, so the sender's UPDATE grant is three columns wide
  -- and none of them is a term.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  BEGIN
    UPDATE protection_calls SET seats_requested = 1 WHERE id = call;
    RAISE EXCEPTION 'FAIL: the sender rewrote the size of their own ask';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  BEGIN
    UPDATE protection_calls SET rebill_minor = 0 WHERE id = call;
    RAISE EXCEPTION 'FAIL: the sender rewrote what they offered to pay';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  BEGIN
    DELETE FROM protection_calls WHERE id = call;
    RAISE EXCEPTION 'FAIL: a call was deleted rather than closed';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- An invited operator does not close somebody else's call either. The
  -- policy is a USING clause, so the row is invisible to the statement rather
  -- than the statement refused — a silent zero-row UPDATE, which is exactly
  -- the kind of control that reads as working and is never tested.
  PERFORM set_config('app.tenant_id', bony::text, true);
  UPDATE protection_calls
     SET state = 'withdrawn', closed_at = now() WHERE id = call;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*) INTO seen
    FROM protection_calls WHERE id = call AND state = 'open';
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: an invited operator withdrew a call that was not theirs';
  END IF;

  -- What the sender may do: take it back, while it is still theirs to take.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);
  UPDATE protection_calls
     SET state = 'withdrawn', closed_at = now() WHERE id = call;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*) INTO seen
    FROM protection_calls WHERE id = call AND state = 'withdrawn';
  IF seen <> 1 THEN
    RAISE EXCEPTION 'FAIL: the sender could not withdraw their own call';
  END IF;

  RESET ROLE;
  PERFORM set_config('app.platform', 'off', true);
  RAISE NOTICE 'OK  an open call reaches the road it names, and its terms are nobody''s to edit';
END
$$;

-- ── 23. A seat is sold in pieces, and never twice ──────────────────────────
--
-- ADR-0025. The claim the whole segment model rests on is that two people
-- cannot buy the same piece of the same seat — and it is a claim about
-- *concurrency*, so it is made to Postgres as an exclusion constraint rather
-- than to a reviewer as a handler. Executed here, along with the other half:
-- `seats.state` is derived from occupancy and gains `partial`, so every
-- reader that has not been taught about segments fails closed.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  aline UUID := '55555555-5555-5555-5555-555555555551';
  serge UUID := '55555555-5555-5555-5555-555555555552';
  dep   UUID := 'cccccccc-0000-0000-0000-0000000000c1';
  h1    UUID := 'dddddddd-0000-0000-0000-0000000000c1';
  h2    UUID := 'dddddddd-0000-0000-0000-0000000000c2';
  seen  TEXT;
BEGIN
  -- A road with one town on it: three positions, two legs, `[0,2)`.
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency, road_span)
  VALUES (dep, ocean, 'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          now() + INTERVAL '3 days', now() + INTERVAL '3 days 8 hours',
          4, 12000, 'XAF', '[0,2)');

  INSERT INTO seats (departure_id, seat_label, operator_id, section_code,
                     fare_minor, currency)
  VALUES (dep, '1A', ocean, 'STD', 12000, 'XAF');

  INSERT INTO holds (id, operator_id, departure_id, user_id, seat_labels,
                     expires_at, idempotency_key)
  VALUES (h1, ocean, dep, aline, ARRAY['1A'],
          now() + INTERVAL '15 minutes', 'seg-aline'),
         (h2, ocean, dep, serge, ARRAY['1A'],
          now() + INTERVAL '15 minutes', 'seg-serge');

  RESET ROLE;

  -- ── Aline takes the first leg ──
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.user_id', aline::text, true);

  INSERT INTO seat_occupancy
    (departure_id, seat_label, operator_id, span, hold_id, held_until)
  VALUES (dep, '1A', ocean, '[0,1)', h1, now() + INTERVAL '15 minutes');

  -- Half the road is taken, so the seat is neither free nor gone. A reader
  -- filtering on `state = 'available'` now excludes it, which is the whole
  -- point: an old reader must fail closed, never open.
  SELECT state::text INTO seen FROM seats
   WHERE departure_id = dep AND seat_label = '1A';
  IF seen <> 'partial' THEN
    RAISE EXCEPTION 'FAIL: a half-sold seat reads as %', seen;
  END IF;

  -- ── Serge cannot have the same leg ──
  PERFORM set_config('app.user_id', serge::text, true);
  BEGIN
    INSERT INTO seat_occupancy
      (departure_id, seat_label, operator_id, span, hold_id, held_until)
    VALUES (dep, '1A', ocean, '[0,1)', h2, now() + INTERVAL '15 minutes');
    RAISE EXCEPTION 'FAIL: the same piece of one seat was sold twice';
  EXCEPTION WHEN exclusion_violation THEN
    NULL; -- expected: Postgres refused it, not a handler
  END;

  -- Nor a range that merely overlaps it. This is the case a naive equality
  -- check misses, and the reason the constraint is `&&` rather than `=`.
  BEGIN
    INSERT INTO seat_occupancy
      (departure_id, seat_label, operator_id, span, hold_id, held_until)
    VALUES (dep, '1A', ocean, '[0,2)', h2, now() + INTERVAL '15 minutes');
    RAISE EXCEPTION 'FAIL: an overlapping span was accepted';
  EXCEPTION WHEN exclusion_violation THEN
    NULL; -- expected
  END;

  -- ── But he may have the second, which is the feature ──
  --
  -- Half-open ranges: Aline alights at the town and Serge boards there, and
  -- `[0,1)` and `[1,2)` share nothing. A closed range would have them
  -- fighting over a stop neither of them occupies.
  INSERT INTO seat_occupancy
    (departure_id, seat_label, operator_id, span, hold_id, held_until)
  VALUES (dep, '1A', ocean, '[1,2)', h2, now() + INTERVAL '15 minutes');

  SELECT state::text INTO seen FROM seats
   WHERE departure_id = dep AND seat_label = '1A';
  IF seen <> 'held' THEN
    RAISE EXCEPTION 'FAIL: a seat covered end to end reads as %', seen;
  END IF;

  -- ── And nobody takes a piece of a seat in somebody else's name ──
  --
  -- The authority is the hold, so the policy asks about the hold. Aline
  -- releasing her own leg is her business; releasing Serge's is not.
  PERFORM set_config('app.user_id', aline::text, true);
  DELETE FROM seat_occupancy WHERE hold_id = h2;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*)::text INTO seen FROM seat_occupancy WHERE hold_id = h2;
  IF seen <> '1' THEN
    RAISE EXCEPTION 'FAIL: a traveller released somebody else''s leg';
  END IF;

  -- ── Giving it all back leaves the seat free, without anybody saying so ──
  DELETE FROM seat_occupancy WHERE departure_id = dep;

  SELECT state::text INTO seen FROM seats
   WHERE departure_id = dep AND seat_label = '1A';
  IF seen <> 'available' THEN
    RAISE EXCEPTION 'FAIL: an emptied seat reads as %', seen;
  END IF;

  -- ── And the road itself is not rewritable after the sale ──
  --
  -- `bel_app` held a table-wide UPDATE on `departures`, so a column REVOKE
  -- would have been decorative — the grant list is the control (0032), and
  -- this is the assertion that it actually is one.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.tenant_id', ocean::text, true);

  BEGIN
    UPDATE departures SET road_span = '[0,1)' WHERE id = dep;
    RAISE EXCEPTION 'FAIL: an operator rewrote the road a ticket was sold on';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- What it may still write: the ordinary shape of a departure.
  UPDATE departures SET capacity = 4 WHERE id = dep;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'off', true);
  RAISE NOTICE 'OK  a seat is sold in pieces, never twice, and says so itself';
END
$$;

-- ── 24. A seat's state is nobody's to write ────────────────────────────────
--
-- Section 23 proved the derivation is *correct*. This one proves it is the
-- only one there is: 0035 left eleven code paths still setting the state by
-- hand, and two writers who agree until the afternoon they do not is the
-- failure the whole slice exists to remove. 0036 removes the privilege, so
-- the second writer cannot come back — not from a handler somebody adds next
-- year, and not from an operator with a psql prompt.
--
-- The exception carved out is one column for one role: a traveller reserving
-- from a hold moves their own deadline out to the payment window, and nothing
-- else about the row.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  aline UUID := '55555555-5555-5555-5555-555555555551';
  serge UUID := '55555555-5555-5555-5555-555555555552';
  dep   UUID := 'cccccccc-0000-0000-0000-0000000000d1';
  h1    UUID := 'dddddddd-0000-0000-0000-0000000000d1';
  seen  TEXT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency)
  VALUES (dep, ocean, 'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          now() + INTERVAL '4 days', now() + INTERVAL '4 days 8 hours',
          4, 12000, 'XAF');

  INSERT INTO seats (departure_id, seat_label, operator_id, section_code,
                     fare_minor, currency)
  VALUES (dep, '1A', ocean, 'STD', 12000, 'XAF');

  INSERT INTO holds (id, operator_id, departure_id, user_id, seat_labels,
                     expires_at, idempotency_key)
  VALUES (h1, ocean, dep, aline, ARRAY['1A'],
          now() + INTERVAL '15 minutes', 'derived-aline');

  -- ── Not the platform's, not an operator's, not a traveller's ──
  --
  -- Asked of the catalogue rather than by attempting three statements,
  -- because a privilege that is absent for all three roles is the claim, and
  -- `has_table_privilege` is where that claim actually lives.
  IF has_table_privilege('bel_admin',  'seats', 'UPDATE')
     OR has_table_privilege('bel_app',    'seats', 'UPDATE')
     OR has_table_privilege('bel_public', 'seats', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: an application role can still write a seat by hand';
  END IF;

  -- And column by column, because a column grant added later would not show
  -- up in the table-level answer above.
  IF has_column_privilege('bel_app', 'seats', 'state', 'UPDATE')
     OR has_column_privilege('bel_public', 'seats', 'held_until', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: a column grant reopened the derived state';
  END IF;

  -- ── The traveller moves their own deadline, and nothing else ──
  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.user_id', aline::text, true);

  INSERT INTO seat_occupancy (departure_id, seat_label, operator_id, span,
                              hold_id, held_until)
  SELECT dep, '1A', ocean, d.road_span, h1, now() + INTERVAL '15 minutes'
    FROM departures d WHERE d.id = dep;

  -- Reserving: the seats stay held and the deadline moves to the payment
  -- window. This is the one UPDATE a traveller has on this table.
  UPDATE seat_occupancy SET held_until = now() + INTERVAL '4 hours'
   WHERE hold_id = h1;

  SELECT state::text INTO seen FROM seats
   WHERE departure_id = dep AND seat_label = '1A';
  IF seen <> 'held' THEN
    RAISE EXCEPTION 'FAIL: a reservation left the seat %', seen;
  END IF;

  -- What that same grant does not buy: turning the hold into a sale, which
  -- would be a free ticket, or moving the piece of road under it.
  BEGIN
    UPDATE seat_occupancy SET booking_id = gen_random_uuid(), hold_id = NULL
     WHERE hold_id = h1;
    RAISE EXCEPTION 'FAIL: a traveller sold themselves a seat';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: the grant names one column, and it is not this one
  END;

  BEGIN
    UPDATE seat_occupancy SET span = '[0,9)' WHERE hold_id = h1;
    RAISE EXCEPTION 'FAIL: a traveller rewrote the journey they bought';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- Nor somebody else's deadline, which would be a way to hand a stranger's
  -- seat to whoever asked next.
  PERFORM set_config('app.user_id', serge::text, true);
  UPDATE seat_occupancy SET held_until = now() - INTERVAL '1 minute'
   WHERE hold_id = h1;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*)::text INTO seen FROM seat_occupancy
   WHERE hold_id = h1 AND held_until > now();
  IF seen <> '1' THEN
    RAISE EXCEPTION 'FAIL: a traveller expired somebody else''s hold';
  END IF;

  -- ── But a hold that ran out is nobody's ──
  --
  -- The claim path has always treated a lapsed hold as available rather than
  -- waiting for the sweeper, and under occupancy that read is a DELETE by
  -- whoever wants the seat next. It is the database's clock that decides.
  UPDATE seat_occupancy SET held_until = now() - INTERVAL '1 minute'
   WHERE hold_id = h1;

  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.user_id', serge::text, true);
  DELETE FROM seat_occupancy WHERE departure_id = dep;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*)::text INTO seen FROM seat_occupancy WHERE departure_id = dep;
  IF seen <> '0' THEN
    RAISE EXCEPTION 'FAIL: a lapsed hold kept a seat nobody was paying for';
  END IF;

  SELECT state::text INTO seen FROM seats
   WHERE departure_id = dep AND seat_label = '1A';
  IF seen <> 'available' THEN
    RAISE EXCEPTION 'FAIL: a swept seat reads as %', seen;
  END IF;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'off', true);
  RAISE NOTICE 'OK  a seat''s state is derived, and nobody may write it';
END
$$;

-- ── 25. A traveller cannot edit what they were quoted ──────────────────────
--
-- A hold now carries the price of the leg it took (ADR-0025, migration 0037),
-- and the reservation charges that number rather than re-deriving it at a
-- counter four hours later. Which turns the table-wide UPDATE that 0005 gave
-- `bel_public` — for one statement, releasing your own hold — into a way to
-- buy a journey for one franc.
--
-- So the grant became the column it always was in practice. This is the
-- assertion that it stayed that way.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  aline UUID := '55555555-5555-5555-5555-555555555551';
  dep   UUID := 'cccccccc-0000-0000-0000-0000000000e1';
  h1    UUID := 'dddddddd-0000-0000-0000-0000000000e1';
  seen  TEXT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  INSERT INTO departures
    (id, operator_id, route_id, seat_layout_id, departs_at, arrives_at,
     capacity, fare_minor, currency, road_span)
  VALUES (dep, ocean, 'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          now() + INTERVAL '5 days', now() + INTERVAL '5 days 8 hours',
          4, 12000, 'XAF', '[0,2)');

  INSERT INTO seats (departure_id, seat_label, operator_id, section_code,
                     fare_minor, currency)
  VALUES (dep, '1A', ocean, 'STD', 12000, 'XAF');

  INSERT INTO holds (id, operator_id, departure_id, user_id, seat_labels,
                     expires_at, idempotency_key, road_span,
                     segment_fare_minor)
  VALUES (h1, ocean, dep, aline, ARRAY['1A'],
          now() + INTERVAL '15 minutes', 'quoted-aline', '[1,2)', 5500);

  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.user_id', aline::text, true);

  -- What a traveller may still do to their own hold, and the only thing they
  -- ever did: give it back.
  UPDATE holds SET state = 'released' WHERE id = h1;
  UPDATE holds SET state = 'active'   WHERE id = h1;

  -- What they may not: rewrite the price they were quoted, or the piece of
  -- road it was quoted for. The first is a one-franc ticket; the second is a
  -- whole journey bought at a leg's price.
  BEGIN
    UPDATE holds SET segment_fare_minor = 1 WHERE id = h1;
    RAISE EXCEPTION 'FAIL: a traveller rewrote their own quote';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: the grant names `state`, and nothing else
  END;

  BEGIN
    UPDATE holds SET road_span = '[0,2)' WHERE id = h1;
    RAISE EXCEPTION 'FAIL: a traveller widened the journey they had paid for';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  -- Nor may they extend their own hold past the moment it lapses, which
  -- would be a way to sit on a seat through the morning rush.
  BEGIN
    UPDATE holds SET expires_at = now() + INTERVAL '9 hours' WHERE id = h1;
    RAISE EXCEPTION 'FAIL: a traveller extended their own hold';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected
  END;

  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  SELECT segment_fare_minor::text INTO seen FROM holds WHERE id = h1;
  IF seen <> '5500' THEN
    RAISE EXCEPTION 'FAIL: the quoted price reads % after all that', seen;
  END IF;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'off', true);
  RAISE NOTICE 'OK  a hold''s quote is the server''s, not the traveller''s';
END
$$;

-- ── 26. A ticket link is a hash, and nobody may walk the table ─────────────
--
-- ADR-0026. The link is the credential for seeing a ticket, so two properties
-- have to hold at the same time: an anonymous holder can resolve *their* token
-- into a ticket, and an anonymous caller cannot enumerate anybody else's.
--
-- Both come from the same decision — the reader is a SECURITY DEFINER function
-- that takes a hash, and there is no policy on this table that an anonymous
-- session satisfies. A SELECT policy would have been row-enumerable, which is
-- a list of every live ticket in the country.
DO $$
DECLARE
  ocean UUID := '11111111-1111-1111-1111-111111111111';
  aline UUID := '55555555-5555-5555-5555-555555555551';
  dep   UUID := 'cccccccc-0000-0000-0000-0000000000f1';
  bkg   UUID := 'bbbbbbbb-0000-0000-0000-0000000000f1';
  till  UUID;
  seen  INTEGER;
  ref   TEXT;
BEGIN
  SET LOCAL ROLE bel_admin;
  PERFORM set_config('app.platform', 'on', true);
  PERFORM set_config('app.tenant_id', '', true);

  -- A counter sale names its counter, because that is the drawer it
  -- reconciles against (0008).
  SELECT id INTO till FROM stations WHERE operator_id = ocean LIMIT 1;

  INSERT INTO departures (id, operator_id, route_id, seat_layout_id,
                          departs_at, arrives_at, capacity, fare_minor,
                          currency, status, road_span)
  SELECT dep, ocean, r.id, l.id,
         now() + INTERVAL '6 hours', now() + INTERVAL '14 hours',
         49, 12000, 'XAF', 'scheduled', int4range(0, 1)
    FROM routes r, seat_layouts l
   WHERE r.operator_id = ocean AND l.operator_id = ocean
   LIMIT 1;

  INSERT INTO bookings (id, ref, operator_id, departure_id, purchaser_user_id,
                        state, fare_minor, service_fee_minor, total_minor,
                        currency, channel, station_id, payment_method, paid_at,
                        confirmed_at)
  VALUES (bkg, 'LNK001', ocean, dep, aline, 'confirmed',
          12000, 500, 12500, 'XAF', 'agency', till, 'cash', now(), now());

  INSERT INTO ticket_links (booking_id, operator_id, token_hash, channel,
                            sent_to, expires_at)
  VALUES (bkg, ocean, 'hash-of-a-token', 'email', 'walkin@example.cg',
          now() + INTERVAL '2 days');

  SET LOCAL ROLE bel_public;
  PERFORM set_config('app.public', 'on', true);
  PERFORM set_config('app.platform', 'off', true);
  PERFORM set_config('app.user_id', '', true);

  -- A stranger with no token sees nothing at all. Not "somebody else's row
  -- filtered out" — nothing, including the fact that a row exists.
  SELECT count(*) INTO seen FROM ticket_links;
  IF seen <> 0 THEN
    RAISE EXCEPTION 'FAIL: an anonymous caller listed % ticket links', seen;
  END IF;

  -- And the holder of the token resolves it, through the function, with no
  -- session and no account.
  SELECT booking_ref INTO ref FROM ticket_by_link('hash-of-a-token');
  IF ref <> 'LNK001' THEN
    RAISE EXCEPTION 'FAIL: a link holder could not open their own ticket (%)',
      COALESCE(ref, 'nothing');
  END IF;

  -- A token nobody issued resolves to nothing, which is also what a revoked
  -- and an expired one do — one answer, so a dead link says nothing about
  -- whether it was ever real.
  IF EXISTS (SELECT 1 FROM ticket_by_link('hash-of-nothing')) THEN
    RAISE EXCEPTION 'FAIL: a token nobody issued opened a ticket';
  END IF;

  RESET ROLE;
  PERFORM set_config('app.public', 'off', true);
  PERFORM set_config('app.platform', 'off', true);
  RAISE NOTICE 'OK  a ticket link is a hash, and nobody may walk the table';
END
$$;
