-- 0005_public_sales_access — the seam 0004 was missing.
--
-- 0004 assumed every connection belongs to an operator. The traveller does
-- not. A public request arrives with a Firebase user and no tenant at all, so
-- under 0004 alone `app_tenant_id()` is NULL, every tenant policy evaluates
-- false, and the buying path sees an empty database.
--
-- The tempting fix is to look up the departure's operator and set
-- `app.tenant_id` to it for the duration of the request. It works, and it is
-- wrong: it would run an anonymous internet request with the operator's own
-- full tenant authority, so one careless join in a public handler would read
-- that operator's staff list, KYB documents or ledger.
--
-- Instead the public surface gets its own role with its own narrow policies.
-- Least privilege at the CONNECTION, not at the query: bel_public has no
-- grant whatsoever on operator_staff, kyb_documents, payouts, refunds or
-- audit_log, so a public handler cannot reach them even with a SQL injection
-- and a free afternoon.
--
-- Two properties are worth stating because the rest of the design leans on
-- them:
--
--   * **bel_public can never mark a seat sold.** Its UPDATE policy sees only
--     `available` and `held` rows and may only write those two states back.
--     Selling is a system action that happens after money is captured, under
--     the operator's own scope. There is no path from an unauthenticated
--     request to a sold seat.
--   * **A traveller sees their own rows, never a stranger's.** Holds and
--     bookings are keyed to `app.user_id`, which is set from the verified
--     Firebase token and nothing else.

BEGIN;

-- ── Role ────────────────────────────────────────────────────────────────────
-- Created LOGIN by infra/dev/seed/00-roles.sql and by Terraform in real
-- environments; guarded here so the migration is runnable either way.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_public') THEN
    CREATE ROLE bel_public NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

-- The role the API actually logs in as.
--
-- NOINHERIT is the point of it: bel_api holds membership of all three surface
-- roles and the privileges of NONE of them. A freshly borrowed pool
-- connection can read nothing and write nothing until it declares which
-- surface it is serving with `SET LOCAL ROLE`, and because that is LOCAL, the
-- declaration dies at COMMIT rather than riding the connection back into the
-- pool and into the next request.
--
-- The alternative — three connection pools with three passwords — costs three
-- sets of credentials to rotate and gains nothing, because a pool that can
-- log in as bel_admin is exactly as dangerous as a role that can SET ROLE to
-- it.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_api') THEN
    CREATE ROLE bel_api NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

GRANT bel_public, bel_app, bel_admin TO bel_api;

-- ── Session helpers ─────────────────────────────────────────────────────────

-- The signed-in traveller on this connection, or NULL.
--
-- `true` makes current_setting return NULL rather than raising, so a browse
-- request that never signs in does not error — it simply matches no
-- user-scoped rows, which is exactly right.
CREATE OR REPLACE FUNCTION app_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::UUID
$$;

-- True only on the public surface. Set alongside app.user_id by the same
-- middleware, so a console connection can never accidentally inherit the
-- traveller policies below.
CREATE OR REPLACE FUNCTION app_is_public() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.public', true), 'off') = 'on'
$$;

-- ── What a traveller may read ───────────────────────────────────────────────
--
-- Policies are permissive and therefore OR'd with the tenant policies from
-- 0004. Adding one here widens the public surface and nothing else: an
-- operator's view of its own data is untouched.

-- A cancelled departure is still readable on purpose: a traveller holding a
-- ticket for it must be able to see what happened to their coach.
CREATE POLICY departures_public_read ON departures
  FOR SELECT USING (app_is_public());

CREATE POLICY routes_public_read ON routes
  FOR SELECT USING (app_is_public() AND active);

CREATE POLICY route_stops_public_read ON route_stops
  FOR SELECT USING (app_is_public());

-- The seat map. Needed to draw the layout before anything is held.
CREATE POLICY seat_layouts_public_read ON seat_layouts
  FOR SELECT USING (app_is_public());

CREATE POLICY seats_public_read ON seats
  FOR SELECT USING (app_is_public());

-- ── What a traveller may change ─────────────────────────────────────────────

-- Holding and releasing, and nothing else.
--
-- USING covers the row as it stands: a `sold` or `blocked` seat is invisible
-- to this policy, so the public role cannot touch one at all. WITH CHECK
-- covers the row as it would become, which is what stops a crafted request
-- from writing `sold` and skipping payment entirely.
CREATE POLICY seats_public_hold ON seats
  FOR UPDATE
  USING (app_is_public() AND state IN ('available', 'held'))
  WITH CHECK (app_is_public() AND state IN ('available', 'held'));

-- A hold belongs to the traveller who created it. `user_id = app_user_id()`
-- is NULL-safe in the sense that matters: an anonymous connection has a NULL
-- user id, the comparison is NULL, and NULL is not true — so browsing without
-- signing in sees no holds rather than everyone's.
CREATE POLICY holds_public_own ON holds
  FOR SELECT USING (app_is_public() AND user_id = app_user_id());

CREATE POLICY holds_public_create ON holds
  FOR INSERT WITH CHECK (app_is_public() AND user_id = app_user_id());

-- Releasing a hold early — the traveller backed out of the payment screen.
CREATE POLICY holds_public_update ON holds
  FOR UPDATE
  USING (app_is_public() AND user_id = app_user_id())
  WITH CHECK (app_is_public() AND user_id = app_user_id());

CREATE POLICY bookings_public_own ON bookings
  FOR SELECT USING (app_is_public() AND purchaser_user_id = app_user_id());

CREATE POLICY bookings_public_create ON bookings
  FOR INSERT WITH CHECK (app_is_public() AND purchaser_user_id = app_user_id());

CREATE POLICY booking_seats_public_own ON booking_seats
  FOR ALL
  USING (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = booking_seats.booking_id
        AND b.purchaser_user_id = app_user_id()
    )
  )
  WITH CHECK (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = booking_seats.booking_id
        AND b.purchaser_user_id = app_user_id()
    )
  );

-- The ticket the traveller carries. Read-only forever: a ticket is issued by
-- the system and voided by the system.
CREATE POLICY tickets_public_own ON tickets
  FOR SELECT USING (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = tickets.booking_id
        AND b.purchaser_user_id = app_user_id()
    )
  );

-- Idempotency keys are per-traveller.
--
-- Without this, one traveller could delete another's in-flight claim and turn
-- their retry into a second execution — a small hole, but the table exists
-- entirely to prevent second executions, so it may as well not exist with a
-- hole in it. `user_id` is filled from `app_user_id()` by the INSERT, the same
-- setting the policy checks, so the two cannot drift apart.
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE idempotency_keys FORCE ROW LEVEL SECURITY;

CREATE POLICY idempotency_public_own ON idempotency_keys
  FOR ALL
  USING (app_is_public() AND user_id = app_user_id())
  WITH CHECK (app_is_public() AND user_id = app_user_id());

-- Staff-side keys are not user-scoped: a console sale is retried by whichever
-- till recovers first, and scoping the key to one agent would break exactly
-- the recovery it exists for.
CREATE POLICY idempotency_staff ON idempotency_keys
  FOR ALL
  USING (NOT app_is_public())
  WITH CHECK (NOT app_is_public());

-- ── Grants ──────────────────────────────────────────────────────────────────
--
-- Enumerated one table at a time, and deliberately not with
-- `GRANT ... ON ALL TABLES`. The list below IS the public attack surface; a
-- future table is invisible to this role until someone adds a line here and
-- has to justify it in review.

GRANT USAGE ON SCHEMA public TO bel_public;

GRANT SELECT ON cities, routes, route_stops, departures, seat_layouts,
                operators TO bel_public;
GRANT SELECT, UPDATE ON seats TO bel_public;
GRANT SELECT, INSERT, UPDATE ON holds TO bel_public;
GRANT SELECT, INSERT ON bookings, booking_seats TO bel_public;
GRANT SELECT ON tickets TO bel_public;
-- DELETE is here for one statement: releasing a claim that failed before it
-- produced a response, so an honest client can genuinely retry rather than
-- being told the work already happened. The policy above keeps that to the
-- traveller's own rows.
GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys TO bel_public;

-- An operator's public identity — name, logo, vitrine — is exactly what a
-- traveller is choosing between, so one row per active operator is readable.
CREATE POLICY operators_public_read ON operators
  FOR SELECT USING (app_is_public() AND status = 'active');

COMMIT;
