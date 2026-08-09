-- 0004_rls_grants — the tenancy boundary, and the append-only guarantee.
--
-- This is the most important migration in the repository.
--
-- Application-layer filtering is the SECOND line of defence, not the first.
-- The first is here: if a repository method forgets `WHERE operator_id = ?`,
-- the database still refuses. Without that, a single missing clause leaks a
-- competitor's load factor and pricing — the exact thing that makes operators
-- refuse to join a marketplace at all (ADR-0011).
--
-- How it works: the connection sets `app.tenant_id` from the verified token
-- before running anything, and the policies below do the rest. The role that
-- does this is deliberately NOT the table owner and NOT a superuser, because
-- both bypass RLS silently.

BEGIN;

-- ── Roles ───────────────────────────────────────────────────────────────────
-- Created by infra/dev/seed/00-roles.sql locally and by Terraform in real
-- environments; guarded so this migration is runnable either way.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_app') THEN
    CREATE ROLE bel_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_admin') THEN
    CREATE ROLE bel_admin NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

-- Helper: the tenant on this connection, or NULL when unset.
-- `true` makes current_setting return NULL instead of raising, so a public
-- endpoint that never sets a tenant does not error — it simply matches
-- nothing tenant-scoped.
CREATE OR REPLACE FUNCTION app_tenant_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::UUID
$$;

-- Set by the admin API only, after an explicit, audited authorisation check.
CREATE OR REPLACE FUNCTION app_is_platform() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.platform', true), 'off') = 'on'
$$;

-- ── Tenant-scoped tables ────────────────────────────────────────────────────
-- Every table carrying operator_id. Adding one without a policy here is a
-- build failure — `rls_coverage_test` parses these migrations and checks.

DO $$
DECLARE
  t TEXT;
  tenant_tables TEXT[] := ARRAY[
    'stations', 'operator_staff', 'kyb_documents',
    'routes', 'seat_layouts', 'vehicles',
    'departure_patterns', 'departures',
    'seats', 'holds', 'bookings', 'tickets', 'redemptions',
    'payment_intents', 'refunds', 'refund_policies', 'ledger_entries',
    -- An operator sees audit entries about ITS OWN tenant — who on their
    -- staff refunded what — and nothing else. Platform-only rows carry a NULL
    -- operator_id, and `operator_id = app_tenant_id()` is NULL for those,
    -- which is false: a tenant can neither read them nor forge one.
    'audit_log'
  ];
BEGIN
  FOREACH t IN ARRAY tenant_tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    -- FORCE so the policy applies to the table owner too. Without this, a
    -- migration run or an admin session silently sees everything, and the
    -- boundary is only as good as whoever happens to be connected.
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);

    EXECUTE format($f$
      CREATE POLICY %I_tenant_isolation ON %I
        USING (operator_id = app_tenant_id() OR app_is_platform())
        WITH CHECK (operator_id = app_tenant_id() OR app_is_platform())
    $f$, t, t);
  END LOOP;
END
$$;

-- `operators` is its own case: a tenant sees exactly one row, its own.
ALTER TABLE operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE operators FORCE ROW LEVEL SECURITY;
CREATE POLICY operators_tenant_isolation ON operators
  USING (id = app_tenant_id() OR app_is_platform())
  WITH CHECK (id = app_tenant_id() OR app_is_platform());

-- ── Public reference data ───────────────────────────────────────────────────
-- Cities are shared on purpose: two operators serving Pointe-Noire must mean
-- the same Pointe-Noire. Readable by everyone, writable only by the platform.

ALTER TABLE cities ENABLE ROW LEVEL SECURITY;
CREATE POLICY cities_readable ON cities FOR SELECT USING (true);
CREATE POLICY cities_platform_writes ON cities FOR ALL
  USING (app_is_platform()) WITH CHECK (app_is_platform());

-- Route stops inherit their route's tenant through the FK.
ALTER TABLE route_stops ENABLE ROW LEVEL SECURITY;
ALTER TABLE route_stops FORCE ROW LEVEL SECURITY;
CREATE POLICY route_stops_tenant_isolation ON route_stops
  USING (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM routes r
      WHERE r.id = route_stops.route_id AND r.operator_id = app_tenant_id()
    )
  )
  WITH CHECK (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM routes r
      WHERE r.id = route_stops.route_id AND r.operator_id = app_tenant_id()
    )
  );

ALTER TABLE booking_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_seats FORCE ROW LEVEL SECURITY;
CREATE POLICY booking_seats_tenant_isolation ON booking_seats
  USING (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = booking_seats.booking_id AND b.operator_id = app_tenant_id()
    )
  )
  WITH CHECK (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = booking_seats.booking_id AND b.operator_id = app_tenant_id()
    )
  );

ALTER TABLE payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_events FORCE ROW LEVEL SECURITY;
CREATE POLICY payment_events_tenant_isolation ON payment_events
  USING (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM payment_intents pi
      WHERE pi.id = payment_events.intent_id AND pi.operator_id = app_tenant_id()
    )
  )
  WITH CHECK (
    app_is_platform() OR EXISTS (
      SELECT 1 FROM payment_intents pi
      WHERE pi.id = payment_events.intent_id AND pi.operator_id = app_tenant_id()
    )
  );

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT USAGE ON SCHEMA public TO bel_app, bel_admin;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  TO bel_app, bel_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bel_app, bel_admin;

-- ── Append-only, by grant rather than by convention ─────────────────────────
--
-- A rule that is only written down is a comment. These three tables are the
-- evidence trail for every dispute we will ever have, so the ability to
-- rewrite them is removed rather than discouraged.

REVOKE UPDATE, DELETE ON ledger_entries FROM bel_app, bel_admin;
REVOKE UPDATE, DELETE ON payment_events  FROM bel_app, bel_admin;
REVOKE UPDATE, DELETE ON audit_log       FROM bel_app, bel_admin;

-- Belt and braces: a trigger, so even a future GRANT cannot quietly reopen it.
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    '% is append-only: % is not permitted', TG_TABLE_NAME, TG_OP
    USING HINT = 'Correct a mistaken entry by writing a compensating one.';
END
$$;

CREATE TRIGGER ledger_entries_append_only
  BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE TRIGGER payment_events_append_only
  BEFORE UPDATE OR DELETE ON payment_events
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE TRIGGER audit_log_append_only
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ── The double-entry guarantee ──────────────────────────────────────────────
--
-- Enforced at COMMIT, not per row, because a balanced transaction is written
-- as two or more statements. A constraint trigger deferred to the end of the
-- transaction is the only place this check can live and still be true.

CREATE OR REPLACE FUNCTION assert_ledger_balanced() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  imbalance BIGINT;
BEGIN
  SELECT SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END)
    INTO imbalance
  FROM ledger_entries
  WHERE txn_id = NEW.txn_id;

  IF imbalance <> 0 THEN
    RAISE EXCEPTION
      'ledger transaction % does not balance (off by %)', NEW.txn_id, imbalance
      USING HINT = 'Every movement is at least two entries summing to zero.';
  END IF;

  RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER ledger_entries_must_balance
  AFTER INSERT ON ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_ledger_balanced();

COMMIT;
