-- 0017_disruptions — the Tuesday-morning breakdown, recorded.
--
-- On this road network disruption is normal traffic, not an error path
-- (`08-disruption.md`). A coach fails near Dolisie with forty-two people on
-- board, and today the only record of that is a phone call to the agency and
-- an argument at the gare. This migration gives it a row.
--
-- Three decisions here are worth more than the columns:
--
--   1. **A disruption is public.** `bel_public` may read it. The traveller
--      whose ticket it affects is the obvious reader, but the one that
--      decides the grant is the *follower* — a family member holding a shared
--      trip link with no account at all (ADR-0014). Withholding the reason a
--      coach is late is precisely the behaviour that produces the phone calls
--      this subsystem exists to remove. There is nothing in a disruption row
--      that is not already being shouted across a station forecourt.
--
--   2. **The declaration cannot be rewritten.** §2.4 calls the record
--      immutable and this migration makes that a grant rather than a
--      sentence: an operator may write `resolved_at`, a resolution note and
--      the supersession link, and may not touch what they declared, when, or
--      why. It is the operator's own evidence in a later dispute — which only
--      works if nobody, including them, can edit it afterwards.
--
--   3. **One open disruption per departure.** Enforced by a partial unique
--      index, so "what is happening to my coach right now?" has exactly one
--      answer. A dispatcher who declares a breakdown and then an equipment
--      swap has resolved the first by declaring the second, and the chain is
--      kept in `superseded_by` rather than being flattened away.

BEGIN;

CREATE TYPE disruption_kind AS ENUM (
  'delay', 'cancellation', 'breakdown_en_route',
  'equipment_swap', 'diversion', 'route_suspension'
);

CREATE TABLE disruptions (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id          UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  departure_id         UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,

  kind                 disruption_kind NOT NULL,
  -- A closed vocabulary, from the domain enum. Free text here would make the
  -- route-risk and coach-reliability figures in §6 uncountable, and those are
  -- the by-product that makes this data worth collecting at all.
  cause                TEXT NOT NULL,

  -- The dispatcher's own words, sent on to the passenger. Optional: the
  -- templated sentence already says what happened, and a mandatory field at
  -- the roadside is a field that delays the message.
  note                 TEXT,
  -- Pre-filled from the last known position and editable. "km 180, RN1, près
  -- de Dolisie" is worth more to a passenger than a pair of coordinates.
  location             TEXT,

  -- Required for a delay, meaningless for a cancellation. The domain refuses
  -- a delay declared without one.
  revised_departs_at   TIMESTAMPTZ,
  estimated_resolution TIMESTAMPTZ,

  -- What this declaration entitled the affected bookings to, frozen at
  -- declaration time. Recomputing it later from the kind would silently
  -- rewrite history the day the threshold in the domain changes.
  marks_involuntary    BOOLEAN NOT NULL,
  -- How many confirmed bookings were on board. Kept because it is the number
  -- the operator will be asked about, and it cannot be recovered later once
  -- passengers have been moved.
  bookings_affected    INTEGER NOT NULL DEFAULT 0,

  declared_by          UUID REFERENCES user_accounts(id),
  declared_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  resolved_at          TIMESTAMPTZ,
  resolution_note      TEXT,
  superseded_by        UUID REFERENCES disruptions(id),

  -- No CHECK on the revised time: the departure's own time lives on
  -- `departures`, and "later than what it was sold as" is a comparison this
  -- table cannot make. It is made once, in the domain, by the same function
  -- the console calls before the dispatcher confirms (ADR-0004).
  CONSTRAINT disruptions_bookings_affected_sane CHECK (bookings_affected >= 0)
);

-- "What is happening to this coach right now?" — one answer, or none.
CREATE UNIQUE INDEX disruptions_one_open
  ON disruptions (departure_id)
  WHERE resolved_at IS NULL;

CREATE INDEX disruptions_departure_idx
  ON disruptions (departure_id, declared_at DESC);

-- The operator's day, and the input to the reliability figures.
CREATE INDEX disruptions_operator_idx
  ON disruptions (operator_id, declared_at DESC);

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE disruptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE disruptions FORCE ROW LEVEL SECURITY;

-- The shape 0004 gives every tenant table.
CREATE POLICY disruptions_tenant_isolation ON disruptions
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- And everyone may read one. See decision 1 above: the reader who decides
-- this is the follower of a shared trip link, who holds no account and is
-- exactly the person an operator most wants to stop phoning the agency.
CREATE POLICY disruptions_public_read ON disruptions
  FOR SELECT USING (app_is_public());

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT ON disruptions TO bel_public;
GRANT SELECT, INSERT ON disruptions TO bel_app, bel_admin;

-- Decision 2, as a privilege rather than a promise. Everything an operator
-- declared — kind, cause, note, location, times, who and when — is absent
-- from this list, so it cannot be edited after the fact by any code path,
-- including one written next year by somebody who never read this file.
GRANT UPDATE (resolved_at, resolution_note, superseded_by)
  ON disruptions TO bel_app, bel_admin;

-- A record of a breakdown is not something an operator gets to make go away.
REVOKE DELETE ON disruptions FROM bel_app, bel_admin;

COMMIT;
