\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE bel_app;
SELECT set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);
SELECT 'tenant base ledger rows' AS probe, count(*) FROM ledger_entries;
SELECT 'tenant account balance view rows' AS probe, count(*) FROM account_balances;
SELECT 'tenant transaction balance view rows' AS probe, count(*) FROM ledger_txn_balances;
SELECT set_config('app.platform', 'on', true);
SELECT 'bel_app with platform flag route count' AS probe, count(*) FROM routes;
ROLLBACK;
BEGIN;
INSERT INTO idempotency_keys (key, scope, request_hash, response_body)
VALUES ('tenant-a-audit-probe', 'company-a', 'test', '{"private":"company-a-response"}');
SET LOCAL ROLE bel_app;
SELECT set_config('app.tenant_id', '22222222-2222-2222-2222-222222222222', true);
SELECT 'company B reads A replay' AS probe, count(*) FROM idempotency_keys WHERE key='tenant-a-audit-probe';
DELETE FROM idempotency_keys WHERE key='tenant-a-audit-probe';
ROLLBACK;
BEGIN;
SET LOCAL ROLE bel_app;
SELECT set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);
INSERT INTO departure_patterns (operator_id, route_id, rrule, departure_time, fare_minor, currency, valid_from)
VALUES ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002', 'FREQ=DAILY', '08:00', 1000, 'XAF', CURRENT_DATE);
SELECT 'A pattern referencing B route accepted' AS probe, count(*) FROM departure_patterns WHERE route_id='aaaaaaaa-0000-0000-0000-000000000002';
ROLLBACK;
