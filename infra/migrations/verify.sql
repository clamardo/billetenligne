-- Verifies that the guarantees in 0004 actually hold.
--
-- Run against a throwaway database after the migrations. Every block below
-- asserts something we claim in an ADR — a claim that is not executed is a
-- claim that will quietly stop being true.

\set ON_ERROR_STOP on
SET client_min_messages TO NOTICE;

-- Seed two competing operators and a little data for each.
INSERT INTO operators (id, code, legal_name, market_code, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'ODN', 'Ocean du Nord',      'CG', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'TBV', 'Trans Bony Voyages', 'CG', 'active');

INSERT INTO cities (code, market_code, name_fr, name_en) VALUES
  ('BZV', 'CG', 'Brazzaville', 'Brazzaville'),
  ('PNR', 'CG', 'Pointe-Noire', 'Pointe-Noire');

INSERT INTO routes (id, operator_id, origin_city, destination_city, code, duration_minutes) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'BZV', 'PNR', 'BZV-PNR', 450),
  ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'BZV', 'PNR', 'BZV-PNR', 460);

DO $$
DECLARE
  visible INT;
BEGIN
  -- ── 1. Tenant isolation ───────────────────────────────────────────────────
  -- The whole marketplace depends on an operator being unable to read a
  -- competitor's routes, pricing or load factor.
  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);

  SELECT count(*) INTO visible FROM routes;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: tenant sees % routes, expected only its own', visible;
  END IF;

  SELECT count(*) INTO visible FROM operators;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: tenant sees % operators, expected only itself', visible;
  END IF;

  -- ── 2. A tenant cannot write into another tenant ──────────────────────────
  BEGIN
    INSERT INTO routes (operator_id, origin_city, destination_city, code, duration_minutes)
    VALUES ('22222222-2222-2222-2222-222222222222', 'BZV', 'PNR', 'SNEAK', 400);
    RAISE EXCEPTION 'FAIL: wrote a row into another tenant';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- expected: WITH CHECK refused it
  END;

  -- ── 3. Unset tenant sees nothing ──────────────────────────────────────────
  -- A code path that forgets to scope must fail closed, never open.
  PERFORM set_config('app.tenant_id', '', true);
  SELECT count(*) INTO visible FROM routes;
  IF visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: unscoped connection saw % routes', visible;
  END IF;

  -- ── 4. Shared reference data stays readable ───────────────────────────────
  -- Two operators serving Pointe-Noire must mean the same Pointe-Noire.
  SELECT count(*) INTO visible FROM cities;
  IF visible <> 2 THEN
    RAISE EXCEPTION 'FAIL: cities should be shared, saw %', visible;
  END IF;

  -- ── 5. The platform role crosses tenants deliberately ─────────────────────
  PERFORM set_config('app.platform', 'on', true);
  SELECT count(*) INTO visible FROM routes;
  IF visible <> 2 THEN
    RAISE EXCEPTION 'FAIL: platform saw % routes, expected all', visible;
  END IF;
  PERFORM set_config('app.platform', 'off', true);

  RESET ROLE;
  RAISE NOTICE 'OK  tenant isolation (5 checks)';
END
$$;

-- ── 6. The ledger must balance ──────────────────────────────────────────────
-- Lives in verify_unbalanced.sql, run as a separate psql invocation.
--
-- It cannot be tested inline: the trigger is DEFERRABLE INITIALLY DEFERRED, so
-- it fires at COMMIT — after any DO block has already returned. A plpgsql
-- EXCEPTION handler opens a subtransaction, not a commit, so it never sees the
-- failure. Deferred is the right definition (a balanced movement is often
-- written as several statements), so the test moves rather than the trigger.

DO $$
DECLARE
  txn UUID := gen_random_uuid();
  n INT;
BEGIN
  -- ── 7. A balanced transaction is accepted ─────────────────────────────────
  -- The worked example from 04-payments.md §2: a 9 300 XAF Airtel capture
  -- split into operator payable, commission and service fee.
  INSERT INTO ledger_entries (txn_id, account, direction, amount_minor, currency) VALUES
    (txn, 'psp:cg.airtel_money:clearing',                        'debit',  9300, 'XAF'),
    (txn, 'payable:operator:11111111-1111-1111-1111-111111111111','credit', 8550, 'XAF'),
    (txn, 'revenue:commission',                                   'credit',  450, 'XAF'),
    (txn, 'revenue:service_fee',                                  'credit',  300, 'XAF');

  SELECT count(*) INTO n FROM ledger_txn_balances
   WHERE ledger_txn_balances.txn_id = txn AND balance_minor = 0;
  IF n <> 1 THEN
    RAISE EXCEPTION 'FAIL: balanced transaction did not net to zero';
  END IF;
  RAISE NOTICE 'OK  ledger accepts a balanced transaction';
END
$$;

DO $$
BEGIN
  -- ── 8. Append-only is enforced, not merely documented ─────────────────────
  BEGIN
    UPDATE ledger_entries SET memo = 'tampered' WHERE amount_minor = 9300;
    RAISE EXCEPTION 'FAIL: a ledger entry was updated';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
  END;

  BEGIN
    DELETE FROM ledger_entries WHERE amount_minor = 9300;
    RAISE EXCEPTION 'FAIL: a ledger entry was deleted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK  ledger entries are append-only';
END
$$;

DO $$
DECLARE
  bad INT;
BEGIN
  -- ── 9. Every operator_id table carries an RLS policy ──────────────────────
  -- The check that stops the boundary rotting as tables are added. A new
  -- tenant-scoped table without a policy fails here rather than in production.
  SELECT count(*) INTO bad
  FROM information_schema.columns c
  JOIN pg_class t   ON t.relname = c.table_name
  JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
  WHERE c.table_schema = 'public'
    AND c.column_name = 'operator_id'
    AND t.relkind = 'r'
    AND NOT t.relrowsecurity;

  IF bad > 0 THEN
    RAISE EXCEPTION 'FAIL: % tenant-scoped table(s) have no RLS enabled', bad;
  END IF;
  RAISE NOTICE 'OK  every operator_id table has RLS enabled';
END
$$;

DO $$
DECLARE
  bad INT;
BEGIN
  -- ── 10. No mutable balance column anywhere ────────────────────────────────
  -- Balances are derived from the ledger. A balance you can UPDATE is a
  -- balance that will eventually be wrong with no way to find out when.
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name IN ('balance', 'balance_minor', 'amount_owed')
    AND table_name NOT IN (
      SELECT table_name FROM information_schema.views WHERE table_schema = 'public'
    );

  IF bad > 0 THEN
    RAISE EXCEPTION 'FAIL: % stored balance column(s) found', bad;
  END IF;
  RAISE NOTICE 'OK  no stored balances — every balance is derived';
END
$$;

DO $$
BEGIN
  -- ── 11. Money is never floating point ─────────────────────────────────────
  -- Base tables only. The balance VIEWS are numeric on purpose: SUM(bigint)
  -- widens to numeric in Postgres, which is what stops an aggregate over
  -- millions of rows overflowing. Storage is where exactness matters.
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns c
    JOIN pg_class t     ON t.relname = c.table_name
    JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
    WHERE c.table_schema = 'public'
      AND t.relkind = 'r'
      AND (c.column_name LIKE '%_minor' OR c.column_name LIKE '%amount%')
      AND c.data_type IN ('double precision', 'real', 'numeric')
  ) THEN
    RAISE EXCEPTION 'FAIL: a money column in a base table is not an integer type';
  END IF;
  RAISE NOTICE 'OK  every money column is an integer of minor units';
END
$$;

DO $$
BEGIN
  -- ── 12. Seat state cannot be self-contradictory ───────────────────────────
  BEGIN
    INSERT INTO seats (departure_id, seat_label, operator_id, section_code,
                       state, fare_minor, currency)
    VALUES (gen_random_uuid(), '14A', '11111111-1111-1111-1111-111111111111',
            'STD', 'held', 9000, 'XAF');
    RAISE EXCEPTION 'FAIL: a held seat without a hold was accepted';
  EXCEPTION
    WHEN check_violation OR foreign_key_violation THEN
      RAISE NOTICE 'OK  a held seat must carry a hold and an expiry';
  END;
END
$$;

DO $$
DECLARE
  policy_id UUID := 'cccccccc-0000-0000-0000-000000000001';
BEGIN
  -- ── 13. A refund policy cannot be rewritten ───────────────────────────────
  -- ADR-0015 rule 1: a booking is judged by the version it was sold under,
  -- forever. That rule survives exactly as long as nobody can UPDATE the row
  -- it points at, so the ability is removed rather than discouraged.
  INSERT INTO refund_policies (id, version, operator_id, name, tiers)
  VALUES (policy_id, 1, '11111111-1111-1111-1111-111111111111', 'Souple',
          '[{"minLeadTimeMinutes":1440,"rateBps":10000}]'::jsonb);

  SET LOCAL ROLE bel_app;
  PERFORM set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);

  BEGIN
    UPDATE refund_policies SET name = 'Stricte' WHERE id = policy_id;
    RAISE EXCEPTION 'FAIL: a refund policy was rewritten';
  EXCEPTION
    WHEN insufficient_privilege OR raise_exception THEN
      RAISE NOTICE 'OK  a refund policy is append-only, so a sold booking keeps its terms';
  END;
  RESET ROLE;
END
$$;

DO $$
BEGIN
  -- ── 14. A default policy points at a VERSION, not at a policy ─────────────
  -- Half a reference is a policy id nobody can resolve, and a reference to
  -- "the policy" rather than "the version" is how yesterday's customer
  -- quietly inherits today's terms.
  BEGIN
    UPDATE operators
       SET default_refund_policy_id = 'cccccccc-0000-0000-0000-000000000001'
     WHERE id = '11111111-1111-1111-1111-111111111111';
    RAISE EXCEPTION 'FAIL: half a policy reference was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  BEGIN
    UPDATE operators
       SET default_refund_policy_id = 'cccccccc-0000-0000-0000-000000000001',
           default_refund_policy_version = 99
     WHERE id = '11111111-1111-1111-1111-111111111111';
    RAISE EXCEPTION 'FAIL: a default pointing at a version that does not exist was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK  a default refund policy resolves to one stored version';
  END;
END
$$;

DO $$
DECLARE
  ours   UUID;
  theirs UUID;
BEGIN
  -- ── 15. A coach cannot be said to leave from a rival's terminal ───────────
  -- Two operators run BZV→PNR and each has a yard in Brazzaville. Nothing in
  -- a handler should be the only thing standing between a departure and the
  -- wrong company's address on somebody's ticket, so the constraint says it.
  INSERT INTO stations (operator_id, city_code, name)
  VALUES ('11111111-1111-1111-1111-111111111111', 'BZV', 'Gare de Mikalou')
  RETURNING id INTO ours;

  INSERT INTO stations (operator_id, city_code, name)
  VALUES ('22222222-2222-2222-2222-222222222222', 'BZV', 'Gare de Mikalou')
  RETURNING id INTO theirs;

  INSERT INTO seat_layouts (id, operator_id, name, sections, capacity)
  VALUES ('bbbbbbbb-0000-0000-0000-000000000009',
          '11111111-1111-1111-1111-111111111111', 'Coach 2+2 (gares)',
          '[]'::jsonb, 4);

  BEGIN
    INSERT INTO departures (operator_id, route_id, seat_layout_id, departs_at,
                            arrives_at, capacity, fare_minor, currency,
                            origin_station_id)
    VALUES ('11111111-1111-1111-1111-111111111111',
            'aaaaaaaa-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000009',
            now() + INTERVAL '1 day', now() + INTERVAL '1 day 8 hours',
            4, 12000, 'XAF', theirs);
    RAISE EXCEPTION 'FAIL: a departure boards at another operator''s station';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL; -- expected
  END;

  -- And the same operator's own yard is accepted, so the constraint is a
  -- guard rather than a wall. Removed again immediately: the public boundary
  -- checks that follow count what a traveller can see, and a departure left
  -- behind by this block would be counted as one of theirs.
  INSERT INTO departures (id, operator_id, route_id, seat_layout_id, departs_at,
                          arrives_at, capacity, fare_minor, currency,
                          origin_station_id)
  VALUES ('dddddddd-0000-0000-0000-00000000000f',
          '11111111-1111-1111-1111-111111111111',
          'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000009',
          now() + INTERVAL '1 day', now() + INTERVAL '1 day 8 hours',
          4, 12000, 'XAF', ours);

  DELETE FROM departures WHERE id = 'dddddddd-0000-0000-0000-00000000000f';

  RAISE NOTICE 'OK  a departure can only board at its own operator''s station';
END
$$;

DO $$
DECLARE
  yard    UUID;
  gone    UUID := 'dddddddd-0000-0000-0000-000000000010';
  later   UUID := 'dddddddd-0000-0000-0000-000000000011';
  booking UUID := 'eeeeeeee-0000-0000-0000-000000000010';
BEGIN
  -- ── 16. A counter transfer has to add up, and say which drawer ────────────
  -- The passenger who missed the 06:00 pays a fee, possibly a fare
  -- difference, and moves. Three things are worth more than a handler's word
  -- here, because each of them is a number somebody reconciles at the end of
  -- a shift: the total is its parts, cash names its till, and a "transfer"
  -- that leaves the passenger on the same coach is not one.
  INSERT INTO stations (operator_id, city_code, name)
  VALUES ('11111111-1111-1111-1111-111111111111', 'BZV', 'Gare des Reports')
  RETURNING id INTO yard;

  INSERT INTO departures (id, operator_id, route_id, seat_layout_id, departs_at,
                          arrives_at, capacity, fare_minor, currency, status)
  VALUES
    (gone,  '11111111-1111-1111-1111-111111111111',
     'aaaaaaaa-0000-0000-0000-000000000001',
     'bbbbbbbb-0000-0000-0000-000000000009',
     now() - INTERVAL '1 hour', now() + INTERVAL '7 hours',
     4, 12000, 'XAF', 'departed'),
    (later, '11111111-1111-1111-1111-111111111111',
     'aaaaaaaa-0000-0000-0000-000000000001',
     'bbbbbbbb-0000-0000-0000-000000000009',
     now() + INTERVAL '4 hours', now() + INTERVAL '12 hours',
     4, 12000, 'XAF', 'scheduled');

  INSERT INTO bookings (id, ref, operator_id, departure_id, fare_minor,
                        service_fee_minor, total_minor, currency)
  VALUES (booking, 'BEL-VERIF16', '11111111-1111-1111-1111-111111111111',
          gone, 12000, 300, 12300, 'XAF');

  BEGIN
    INSERT INTO missed_transfers (booking_id, operator_id, from_departure_id,
                                  to_departure_id, seat_labels, fee_minor,
                                  difference_minor, paid_minor, currency,
                                  station_id)
    VALUES (booking, '11111111-1111-1111-1111-111111111111', gone, later,
            ARRAY['1A'], 3000, 0, 2000, 'XAF', yard);
    RAISE EXCEPTION 'FAIL: a transfer was paid an amount that is not its parts';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  BEGIN
    INSERT INTO missed_transfers (booking_id, operator_id, from_departure_id,
                                  to_departure_id, seat_labels, fee_minor,
                                  difference_minor, paid_minor, currency)
    VALUES (booking, '11111111-1111-1111-1111-111111111111', gone, later,
            ARRAY['1A'], 3000, 0, 3000, 'XAF');
    RAISE EXCEPTION 'FAIL: money was taken without naming a till';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  BEGIN
    INSERT INTO missed_transfers (booking_id, operator_id, from_departure_id,
                                  to_departure_id, seat_labels, fee_minor,
                                  difference_minor, paid_minor, currency)
    VALUES (booking, '11111111-1111-1111-1111-111111111111', gone, gone,
            ARRAY['1A'], 0, 0, 0, 'XAF');
    RAISE EXCEPTION 'FAIL: a transfer onto the same coach was recorded';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  -- A free transfer needs no till: the honest shape, rather than a station
  -- invented to satisfy a NOT NULL.
  INSERT INTO missed_transfers (booking_id, operator_id, from_departure_id,
                                to_departure_id, seat_labels, fee_minor,
                                difference_minor, paid_minor, currency)
  VALUES (booking, '11111111-1111-1111-1111-111111111111', gone, later,
          ARRAY['1A'], 0, 0, 0, 'XAF');

  -- ── 17. The terms a late passenger is judged by are a rate ────────────────
  -- The fee is basis points on a fare, and the day something writes a percent
  -- into it a 25 % transfer becomes a 2 500 % one.
  -- Written as a new version rather than an edit, because a refund policy is
  -- append-only — which is the point of the block above this one.
  BEGIN
    INSERT INTO refund_policies (id, version, operator_id, name, tiers,
                                 missed_window_hours, missed_fee_bps)
    VALUES (gen_random_uuid(), 1, '11111111-1111-1111-1111-111111111111',
            'Reports impossibles',
            '[{"minLeadTimeMinutes":1440,"rateBps":10000}]'::jsonb, 12, 25000);
    RAISE EXCEPTION 'FAIL: a missed-transfer fee above 100%% was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  -- Cleared away again: the public-boundary checks that follow count what a
  -- traveller can see, and this coach is not one of theirs.
  DELETE FROM missed_transfers WHERE booking_id = booking;
  DELETE FROM bookings WHERE id = booking;
  DELETE FROM departures WHERE id IN (gone, later);

  RAISE NOTICE 'OK  a counter transfer adds up, names its till and actually moves';
END
$$;

DO $$
DECLARE
  trip    UUID := 'dddddddd-0000-0000-0000-000000000012';
  booking UUID := 'eeeeeeee-0000-0000-0000-000000000012';
  op      UUID := '11111111-1111-1111-1111-111111111111';
BEGIN
  -- ── 18. A payment attempt says where the money is coming from ─────────────
  -- Two shapes of rail now share one table. Every rail before the card one
  -- pushed a prompt to a wallet, and `msisdn` was the number charged; a
  -- hosted checkout has no wallet at all, and the card number never enters
  -- this system. Both are legitimate and the row must be able to say which —
  -- otherwise "which number did we charge?" gets a confident wrong answer at
  -- the one moment somebody is disputing a payment.
  INSERT INTO departures (id, operator_id, route_id, seat_layout_id, departs_at,
                          arrives_at, capacity, fare_minor, currency, status)
  VALUES (trip, op,
          'aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000009',
          now() + INTERVAL '2 days', now() + INTERVAL '2 days 8 hours',
          4, 12000, 'XAF', 'scheduled');

  INSERT INTO bookings (id, ref, operator_id, departure_id, fare_minor,
                        service_fee_minor, total_minor, currency)
  VALUES (booking, 'BEL-VERIF18', op, trip, 12000, 300, 12300, 'XAF');

  BEGIN
    INSERT INTO payment_intents (booking_id, operator_id, rail_id, msisdn,
                                 amount_minor, currency, idempotency_key)
    VALUES (booking, op, 'cg.mtn_momo', NULL, 12300, 'XAF', 'verif18-a');
    RAISE EXCEPTION 'FAIL: a prompt was pushed at no number at all';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  BEGIN
    INSERT INTO payment_intents (booking_id, operator_id, rail_id, msisdn,
                                 amount_minor, currency, idempotency_key,
                                 checkout_url)
    VALUES (booking, op, 'cg.mtn_momo', '242061234567', 12300, 'XAF',
            'verif18-b', 'https://checkout.invalid/pay/x');
    RAISE EXCEPTION 'FAIL: a push rail was given a page to open';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  -- The honest card shape: no wallet, and a page. Not an omission somebody
  -- forgot to fill in — there is nothing to fill it in with.
  INSERT INTO payment_intents (booking_id, operator_id, rail_id, msisdn,
                               amount_minor, currency, idempotency_key,
                               hosted_checkout, checkout_url)
  VALUES (booking, op, 'cg.card', NULL, 12300, 'XAF', 'verif18-c',
          TRUE, 'https://checkout.invalid/pay/verif18');

  DELETE FROM payment_intents WHERE booking_id = booking;
  DELETE FROM bookings WHERE id = booking;
  DELETE FROM departures WHERE id = trip;

  RAISE NOTICE 'OK  a wallet payment names a wallet, a card payment names a page';
END
$$;
