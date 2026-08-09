-- A half-entry must not survive COMMIT.
--
-- Separate from verify.sql because the balance trigger is DEFERRABLE INITIALLY
-- DEFERRED: it fires at COMMIT, which no plpgsql EXCEPTION handler can catch.
-- The shell asserts this script fails, and fails for the right reason.
BEGIN;
INSERT INTO ledger_entries (txn_id, account, direction, amount_minor, currency)
VALUES (gen_random_uuid(), 'psp:cg.airtel_money:clearing', 'debit', 9300, 'XAF');
COMMIT;
