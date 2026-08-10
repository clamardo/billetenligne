-- 0015_operator_applications — where the first row in `operators` comes from.
--
-- Until this migration, every operator arrived by SQL. The admin back office
-- could approve, request information from, reject, suspend and reinstate an
-- application; nothing anywhere could *create* one. That is fine for ten
-- operators onboarded in a room and wrong for the eleventh, who applies
-- without a phone call (03-operator-lifecycle.md §2.2).
--
-- Two shapes were possible and the choice matters:
--
--   * An `operator_applications` table with its own identity, promoted into
--     an `operators` row on approval. Clean, and it duplicates the review
--     queue, the audit trail and the six decisions that already exist and are
--     already tested.
--   * The application IS the operator, in its early lifecycle states. The
--     state machine in §1 already reads `registered → application_draft →
--     under_review → … → active`, so those states are not a separate entity
--     pretending to be one — they are an operator that cannot sell yet.
--
-- This migration takes the second. The wizard's own fields live in a detail
-- table beside the operator, because they are read once by a reviewer and
-- never again by anything on the selling path.
--
-- The security question that follows is the interesting one: **an applicant
-- is a member of the public.** They hold a traveller session, they belong to
-- no tenant, and they are about to write a row into the table that defines
-- tenancy. The answer here is column-level:
--
--   * `bel_public` may INSERT an operator, and the policy pins the new row to
--     `status = 'application_draft'`. There is no path from the internet to
--     an active operator.
--   * `bel_public` may UPDATE exactly four columns — legal name, trading
--     name, RCCM, NIU. Not `status`, not `commission_bps`, not
--     `settlement_account_id`, not the vitrine. A crafted request cannot
--     approve itself, cannot cut its own commission, and cannot rename
--     somebody else's storefront, because the grant does not exist rather
--     than because a handler remembered to check.
--   * Both are further restricted to the operator whose application row
--     names the caller as applicant, and updates stop the moment the
--     application leaves the applicant's hands.

BEGIN;

-- ── The wizard's own record ─────────────────────────────────────────────────

CREATE TABLE operator_applications (
  operator_id       UUID PRIMARY KEY REFERENCES operators(id) ON DELETE CASCADE,

  -- Who is applying. This is the row that survives approval: activation
  -- turns this account into the operator's first `org_owner`, which is what
  -- makes "I can see my own dashboard" reachable without anybody running an
  -- INSERT for them.
  applicant_user_id UUID NOT NULL REFERENCES user_accounts(id) ON DELETE RESTRICT,

  -- 1 · Entreprise (legal name, trading name, RCCM and NIU live on
  -- `operators` itself — they are the operator's identity, not the
  -- application's).
  legal_form        TEXT,
  registered_address TEXT,
  year_founded      INTEGER,

  -- 2 · Dirigeant. Screened at review; the ID scan and the selfie are
  -- `kyb_documents` rows, which this slice does not write — see step 3.
  owner_name        TEXT,
  owner_id_type     TEXT,
  owner_id_number   TEXT,
  owner_phone       TEXT,
  owner_email       TEXT,

  -- 3 · Licences. **Declared, not photographed.** `kyb_documents` holds the
  -- scans and `bel_public` has no grant on it — deliberately, and the schema
  -- guarantee in `verify_public.sql` refuses to let one be added, because a
  -- table of identity documents is the last one to open to the internet.
  -- Camera-first upload is its own slice; what is collected here is the pair
  -- that §3.3 actually enforces against — a number and an expiry date — so an
  -- operator whose insurance lapses is a query rather than a discovery.
  transport_licence_number   TEXT,
  transport_licence_expires  DATE,
  insurer_name               TEXT,
  fleet_insurance_expires    DATE,

  -- 4 · Exploitation. Drives our launch effort estimate and nothing else, so
  -- it is prose and counts rather than a modelled network.
  routes_served     TEXT,
  fleet_size        INTEGER,
  station_count     INTEGER,
  daily_departures  INTEGER,

  -- 5 · Encaissement. The reference is a wallet MSISDN or a bank account;
  -- verification (name-check, micro-deposit) is a third-party call this
  -- deployment does not make yet, so `verified_at` stays NULL and a reviewer
  -- looks.
  settlement_kind         TEXT,
  settlement_account_name TEXT,
  settlement_account_ref  TEXT,
  settlement_verified_at  TIMESTAMPTZ,

  -- 6 · Accord. What we archive today is the acceptance and its timestamp,
  -- not a countersigned PDF — an e-signature vendor is a contract, not a
  -- schema, and recording consent we can actually produce beats recording a
  -- document we cannot.
  agreement_accepted_at   TIMESTAMPTZ,

  submitted_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT operator_applications_year_sane
    CHECK (year_founded IS NULL OR year_founded BETWEEN 1900 AND 2200),
  CONSTRAINT operator_applications_fleet_sane
    CHECK (fleet_size IS NULL OR fleet_size BETWEEN 0 AND 10000),
  CONSTRAINT operator_applications_stations_sane
    CHECK (station_count IS NULL OR station_count BETWEEN 0 AND 10000),
  CONSTRAINT operator_applications_departures_sane
    CHECK (daily_departures IS NULL OR daily_departures BETWEEN 0 AND 10000),
  CONSTRAINT operator_applications_settlement_known
    CHECK (settlement_kind IS NULL OR settlement_kind IN ('momo', 'bank'))
);

-- One unsubmitted draft per person.
--
-- The abuse this closes is not fraud, it is volume: `bel_public` can INSERT
-- an operator, so without this a signed-in account could mint rows until the
-- table is useless. A *submitted* application is deliberately not covered —
-- re-application after a rejection is allowed by §2.3 after thirty days, and
-- that rule belongs where it can be explained to the applicant rather than in
-- a unique violation.
CREATE UNIQUE INDEX operator_applications_one_draft
  ON operator_applications (applicant_user_id)
  WHERE submitted_at IS NULL;

CREATE INDEX operator_applications_submitted_idx
  ON operator_applications (submitted_at)
  WHERE submitted_at IS NOT NULL;

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE operator_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE operator_applications FORCE ROW LEVEL SECURITY;

-- The same shape 0004 gives every tenant table: an operator sees its own row,
-- the platform sees all of them.
CREATE POLICY operator_applications_tenant_isolation ON operator_applications
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- And the applicant sees theirs, on the public surface, keyed to the verified
-- user id and nothing else.
CREATE POLICY operator_applications_applicant ON operator_applications
  FOR ALL
  USING (app_is_public() AND applicant_user_id = app_user_id())
  WITH CHECK (app_is_public() AND applicant_user_id = app_user_id());

-- ── Who is the applicant? ───────────────────────────────────────────────────
--
-- A function rather than an EXISTS inlined into the policies below, and the
-- reason is not style. A policy on `operators` is evaluated for **every** role
-- that reads the table — including `bel_identity`, whose entire job is
-- answering "who is this?" and which has no grant on `operator_applications`
-- and should never be given one. An inlined subquery makes every sign-in fail
-- with `permission denied for table operator_applications`, which is exactly
-- how this was found.
--
-- SECURITY DEFINER moves the privilege to the function. What it exposes is
-- one boolean about the *current session's own* user id, so a caller learns
-- nothing they did not already know.
CREATE OR REPLACE FUNCTION app_is_applicant_for(p_operator UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM operator_applications a
     WHERE a.operator_id = p_operator
       AND a.applicant_user_id = app_user_id()
  )
$$;

REVOKE ALL ON FUNCTION app_is_applicant_for(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_is_applicant_for(UUID)
  TO bel_public, bel_app, bel_admin, bel_identity;

-- ── What an applicant may do to `operators` ─────────────────────────────────

-- Create one, in exactly one state.
CREATE POLICY operators_applicant_create ON operators
  FOR INSERT
  WITH CHECK (app_is_public() AND status = 'application_draft');

-- Read their own, at any stage — including `rejected`, because being told
-- why is the point of the reason field.
--
-- Note what this makes impossible, deliberately: `INSERT … RETURNING id`.
-- RETURNING evaluates the SELECT policy, and this one is granted by the
-- application row, which cannot exist until the operator does. So the caller
-- generates the id, inserts the operator, then inserts the application — two
-- statements in one transaction. The alternative was a read policy that let
-- any signed-in account see every draft operator on the platform, which is a
-- worse trade than an extra statement.
CREATE POLICY operators_applicant_read ON operators
  FOR SELECT USING (app_is_public() AND app_is_applicant_for(operators.id));

-- Edit it while it is still theirs to edit. `info_requested` is included on
-- purpose: "request info" resumes the wizard exactly where the gap is (§2.3),
-- and a wizard that reopens read-only is a support call.
--
-- USING covers the row as it stands and WITH CHECK the row as it would
-- become, so a crafted request cannot move its own status out from under the
-- policy — and the column grant below means it could not name that column
-- anyway.
CREATE POLICY operators_applicant_update ON operators
  FOR UPDATE
  USING (
    app_is_public()
    AND status IN ('application_draft', 'info_requested')
    AND app_is_applicant_for(operators.id)
  )
  WITH CHECK (
    app_is_public()
    AND status IN ('application_draft', 'info_requested')
    AND app_is_applicant_for(operators.id)
  );

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON operator_applications TO bel_public;
GRANT SELECT ON operator_applications TO bel_app;
GRANT SELECT, INSERT, UPDATE ON operator_applications TO bel_admin;

-- The column list IS the control. Written out rather than `GRANT UPDATE ON
-- operators`, because the difference between the two is whether a member of
-- the public can set their own commission to zero.
GRANT INSERT ON operators TO bel_public;
GRANT UPDATE (legal_name, trading_name, rccm_number, tax_id)
  ON operators TO bel_public;

-- ── The one transition an applicant causes ──────────────────────────────────
--
-- Submitting moves `application_draft` → `under_review`, and `status` is
-- exactly the column the public role must never hold. A grant wide enough to
-- write it is a grant wide enough to write `active`.
--
-- So the transition is a function instead of a privilege: SECURITY DEFINER,
-- one UPDATE, one legal source state, one legal target, and the applicant's
-- own identity re-checked inside — because the definer is the superuser and
-- therefore bypasses the policies that would otherwise be doing that work.
-- The hole is exactly the width of this transition and no wider.
--
-- It writes the audit row too. `bel_public` has no grant on `audit_log` and
-- will not be given one, and an application that appears in a reviewer's
-- queue with no trace of arriving is a queue entry nobody can account for.
CREATE OR REPLACE FUNCTION submit_operator_application(p_operator UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  applicant UUID;
BEGIN
  SELECT a.applicant_user_id INTO applicant
    FROM operator_applications a
    JOIN operators o ON o.id = a.operator_id
   WHERE a.operator_id = p_operator
     AND o.status IN ('application_draft', 'info_requested');

  IF applicant IS NULL OR applicant <> app_user_id() OR NOT app_is_public() THEN
    RETURN FALSE;
  END IF;

  UPDATE operators SET status = 'under_review' WHERE id = p_operator;

  INSERT INTO audit_log (actor_id, actor_type, action, subject_type,
                         subject_id, operator_id, reason)
  VALUES (applicant, 'applicant', 'operator.apply', 'operator',
          p_operator::TEXT, p_operator,
          'submitted through the onboarding wizard');

  RETURN TRUE;
END
$fn$;

REVOKE ALL ON FUNCTION submit_operator_application(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_operator_application(UUID) TO bel_public;

COMMIT;
