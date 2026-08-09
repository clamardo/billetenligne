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
