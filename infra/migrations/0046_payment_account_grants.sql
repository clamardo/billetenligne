-- 0046_payment_account_grants — the table nobody could reach.
--
-- `operator_payment_accounts` was created in 0011, after 0004's blanket
-- `GRANT ... ON ALL TABLES IN SCHEMA public` had already run — so, unlike
-- every table that existed before 0004, this one never got a grant of its
-- own. 0011 gave `bel_public` read access (a traveller has to see the number
-- before paying it) and stopped there. Every later migration that added a
-- table did what 0018 did for `payout_runs`: grant the surfaces that touch it
-- explicitly. This one never did, so `bel_app`'s own `savePaymentAccount` and
-- `bel_admin`'s wallet-verification decision have been running against a
-- table neither role can see — caught by the first real-Postgres integration
-- test either surface wrote against this table, not by RLS (which was
-- already correct) and not by the unit suite (which mocks the database).
--
-- No DELETE, for either surface: an account that stops being the live one is
-- deactivated, never removed — an intent that already paid into it has to
-- keep resolving to it in a dispute six weeks later (0011's own comment on
-- the partial unique index).

BEGIN;

GRANT SELECT, INSERT, UPDATE ON operator_payment_accounts TO bel_app, bel_admin;

COMMIT;
