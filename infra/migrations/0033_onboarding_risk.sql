-- 0033_onboarding_risk — a decision a queue does not have to make.
--
-- The review queue works oldest-first and publishes a 48-hour SLA
-- (03-operator-lifecycle.md §2.3). That is a promise about the tail, and the
-- tail is mostly three-coach companies whose application is complete, whose
-- settlement name matches, and about which a reviewer has nothing to add. A
-- person reading those is a person not reading the fourteen-coach one with a
-- name that already exists in the table.
--
-- So the applications get a **band and its reasons**, written by a pass, and
-- the low band approves itself (`09-roadmap.md`, Phase 4). The rule lives in
-- `OnboardingRisk`; these three columns are only where the answer is kept.
--
-- **On `operators`, not on `operator_applications`, and that is a grant
-- decision rather than a modelling one.** 0015 gives `bel_public` a blanket
-- UPDATE on the application row — the wizard writes almost every column of
-- it — so a risk band stored there is a risk band the applicant can set to
-- `low`. On `operators` the public role holds four named columns and none of
-- them is this one. The spec's own framing makes it honest: in the early
-- lifecycle states, the application *is* the operator.
BEGIN;

ALTER TABLE operators
  -- `low` · `standard` · `elevated`, from the domain enum. Deliberately not a
  -- Postgres enum: a band is a policy answer that will be re-tuned, and a
  -- migration to add a rung is a migration nobody schedules.
  ADD COLUMN risk_band        TEXT,
  -- Why it is not the band below. Codes, never sentences (ADR-0008) — the
  -- reviewer's screen renders `application.risk.<code>`, and the applicant is
  -- never shown these at all: telling somebody they failed a screen is how a
  -- screen becomes a tool for finding the alias that passes.
  ADD COLUMN risk_reasons     TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN risk_assessed_at TIMESTAMPTZ;

ALTER TABLE operators
  ADD CONSTRAINT operators_risk_band_known
    CHECK (risk_band IS NULL OR risk_band IN ('low', 'standard', 'elevated'));

-- The pass reads exactly this: submitted, undecided, unassessed or stale.
CREATE INDEX operators_awaiting_review_idx ON operators (risk_assessed_at)
  WHERE status = 'under_review';

COMMIT;
