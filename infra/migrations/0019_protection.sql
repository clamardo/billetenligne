-- 0019_protection — the handshake at the gare, written down once.
--
-- `08-disruption.md` §5. When a coach fails at Dolisie the dispatcher walks
-- down the forecourt and finds a competitor with room. That already happens,
-- every week, and it settles in cash at the roadside with an argument about
-- what a seat was worth. This table is the same arrangement agreed once, in
-- daylight, by two people who are not standing in the rain.
--
-- Three decisions worth more than the columns:
--
--   1. **A row belongs to two tenants.** Every other operator table in this
--      schema is isolated to one. This one cannot be: an agreement neither
--      party can read is not an agreement. The policy therefore matches
--      `app_tenant_id()` against *either* party — which is a widening, so it
--      is written once, here, and the guarantee that it widens no further is
--      executed in `verify_public.sql` rather than promised in a comment.
--
--   2. **One party writes the terms and the other accepts them.** The same
--      two-person rule the payout run runs on (0018), for a smaller version
--      of the same reason: this is the rate one operator will bill the other
--      under, and an agreement one party could activate alone would be an
--      invoice one party could write alone. After acceptance the terms are
--      frozen by a column-level grant, not by a handler — the discount, the
--      ceiling and the roads are absent from the UPDATE list.
--
--   3. **Corridors are rows, not an array.** `BZV↔PNR` is unordered and needs
--      one spelling, which is a normalised key and a unique index — neither
--      of which an array column gives without a trigger. The domain sorts the
--      endpoints; the index makes it impossible to store the pair twice.

BEGIN;

CREATE TYPE protection_agreement_state AS ENUM (
  'proposed', 'active', 'suspended', 'ended'
);

CREATE TABLE protection_agreements (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Ordered by id, so a pair has one spelling and the unique index below can
  -- be built on it. Which of the two proposed is `proposed_by`, not position.
  operator_a        UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  operator_b        UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  state             protection_agreement_state NOT NULL DEFAULT 'proposed',

  -- Reciprocal is the norm. One-way is a real arrangement too: a small
  -- operator protected by a large one, with nothing owed the other way.
  reciprocal        BOOLEAN NOT NULL DEFAULT TRUE,

  -- "tarif public − 15%" is 1500. A discount rather than a rate, because that
  -- is how the term is said out loud, and because it makes the direction
  -- obvious: the receiving operator bills less than they would have sold for.
  rebill_discount_bps  INTEGER NOT NULL DEFAULT 0,

  -- "Plafond 40 places / mois". NULL is no ceiling.
  monthly_cap_seats    INTEGER,

  -- "ou automatique si places > 10" — skip the manual accept when the
  -- receiving departure would still have more than this many seats free.
  auto_accept_spare_above INTEGER,

  proposed_by       UUID NOT NULL REFERENCES operators(id),
  proposed_by_user  UUID REFERENCES user_accounts(id),
  proposed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  accepted_by_user  UUID REFERENCES user_accounts(id),
  accepted_at       TIMESTAMPTZ,

  ended_at          TIMESTAMPTZ,
  ended_reason      TEXT,

  CONSTRAINT protection_two_operators CHECK (operator_a <> operator_b),
  CONSTRAINT protection_pair_ordered  CHECK (operator_a < operator_b),
  CONSTRAINT protection_proposer_is_a_party
    CHECK (proposed_by IN (operator_a, operator_b)),
  CONSTRAINT protection_discount_sane
    CHECK (rebill_discount_bps >= 0 AND rebill_discount_bps <= 10000),
  CONSTRAINT protection_cap_sane
    CHECK (monthly_cap_seats IS NULL OR monthly_cap_seats > 0),
  CONSTRAINT protection_threshold_sane
    CHECK (auto_accept_spare_above IS NULL OR auto_accept_spare_above >= 0),
  -- The state column and the acceptance stamp cannot disagree, and in a
  -- dispute it is the stamp that matters. A proposal has none; anything in
  -- force, or paused while in force, has one. `ended` is deliberately either:
  -- a declined proposal was never accepted, and an agreement that ran for a
  -- year and was wound up was.
  CONSTRAINT protection_acceptance_recorded CHECK (
    (state <> 'proposed'  OR accepted_at IS NULL)
    AND (state <> 'active'    OR accepted_at IS NOT NULL)
    AND (state <> 'suspended' OR accepted_at IS NOT NULL)
  )
);

-- Two operators have at most one agreement in force. A second one would mean
-- two rates for the same seat, and no way to say which was meant.
CREATE UNIQUE INDEX protection_one_live_per_pair
  ON protection_agreements (operator_a, operator_b)
  WHERE state IN ('proposed', 'active');

CREATE INDEX protection_by_a ON protection_agreements (operator_a, state);
CREATE INDEX protection_by_b ON protection_agreements (operator_b, state);

-- ── Corridors ───────────────────────────────────────────────────────────────

CREATE TABLE protection_corridors (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id  UUID NOT NULL
                  REFERENCES protection_agreements(id) ON DELETE CASCADE,

  -- Normalised `BZV~PNR`, endpoints sorted by the domain. Stored as the pair
  -- rather than two columns because the unique index is on the pair, and
  -- because every read wants it as one value.
  city_low      TEXT NOT NULL REFERENCES cities(code),
  city_high     TEXT NOT NULL REFERENCES cities(code),

  CONSTRAINT protection_corridor_ordered CHECK (city_low < city_high)
);

CREATE UNIQUE INDEX protection_corridor_once
  ON protection_corridors (agreement_id, city_low, city_high);

-- ── Movements ───────────────────────────────────────────────────────────────
--
-- What was actually moved under an agreement, and what it was billed at. The
-- monthly ceiling is counted from here rather than from the requests, because
-- a request that was declined moved nobody and a ceiling that counted it
-- would refuse a rescue on the strength of a rescue that never happened.
--
-- Append-only for the same reason the disruption record is: this is what one
-- operator will bill the other under, and both of them get to read it.
CREATE TABLE protection_movements (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id    UUID NOT NULL REFERENCES protection_agreements(id),

  -- Who was rescued and who did the rescuing. Both are on the agreement, but
  -- naming them here is what makes the row readable on its own three months
  -- later, when somebody is checking an invoice.
  sending_operator_id   UUID NOT NULL REFERENCES operators(id),
  receiving_operator_id UUID NOT NULL REFERENCES operators(id),

  disruption_id   UUID REFERENCES disruptions(id),
  departure_id    UUID REFERENCES departures(id),

  seats           INTEGER NOT NULL,
  rebill_minor    BIGINT NOT NULL,
  currency        CHAR(3) NOT NULL,

  -- The ledger movement that settled it, so the invoice and the books point
  -- at each other. Not a foreign key, for the same reason `payout_runs.txn_id`
  -- is not: entries carry the transaction id and there is no transactions
  -- table to point at — the ledger is the entries.
  txn_id          UUID,

  moved_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT protection_movement_seats_sane CHECK (seats > 0),
  CONSTRAINT protection_movement_rebill_sane CHECK (rebill_minor >= 0),
  CONSTRAINT protection_movement_two_parties
    CHECK (sending_operator_id <> receiving_operator_id)
);

CREATE INDEX protection_movements_by_agreement
  ON protection_movements (agreement_id, moved_at DESC);

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE protection_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE protection_agreements FORCE ROW LEVEL SECURITY;
ALTER TABLE protection_corridors  ENABLE ROW LEVEL SECURITY;
ALTER TABLE protection_corridors  FORCE ROW LEVEL SECURITY;
ALTER TABLE protection_movements  ENABLE ROW LEVEL SECURITY;
ALTER TABLE protection_movements  FORCE ROW LEVEL SECURITY;

-- Decision 1. The only table in this schema whose policy names two tenants,
-- and it names exactly two: the parties to this row and nobody else.
--
-- Split by command rather than written as one, because reading and writing
-- have genuinely different rules here. A single policy's WITH CHECK covers
-- INSERT *and* UPDATE, which would mean either the proposer alone could
-- accept — defeating the whole point — or anybody could propose on anybody's
-- behalf. Three policies say the true thing: both parties read, one proposes,
-- either decides.
CREATE POLICY protection_both_parties_read ON protection_agreements
  FOR SELECT USING (
    operator_a = app_tenant_id()
    OR operator_b = app_tenant_id()
    OR app_is_platform()
  );

-- An operator may only propose an agreement they are a party to. Without
-- this, a tenant could write a row binding two other companies.
CREATE POLICY protection_proposed_by_a_party ON protection_agreements
  FOR INSERT WITH CHECK (
    (proposed_by = app_tenant_id()
      AND (operator_a = app_tenant_id() OR operator_b = app_tenant_id()))
    OR app_is_platform()
  );

-- Either party may accept, suspend or end it. *What* they may write is the
-- column-level grant below, not this policy — accepting is a state and a
-- timestamp, and the terms are not in the list.
CREATE POLICY protection_either_party_decides ON protection_agreements
  FOR UPDATE
  USING (
    operator_a = app_tenant_id()
    OR operator_b = app_tenant_id()
    OR app_is_platform()
  )
  WITH CHECK (
    operator_a = app_tenant_id()
    OR operator_b = app_tenant_id()
    OR app_is_platform()
  );

CREATE POLICY protection_corridors_read ON protection_corridors
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM protection_agreements a
      WHERE a.id = agreement_id
        AND (a.operator_a = app_tenant_id()
             OR a.operator_b = app_tenant_id()
             OR app_is_platform())
    )
  );

-- The roads are part of the terms, so only the proposer writes them — and
-- only while the agreement is still a proposal. A corridor added after the
-- counterparty agreed would be a road they never agreed to cover.
CREATE POLICY protection_corridors_written_by_proposer ON protection_corridors
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM protection_agreements a
      WHERE a.id = agreement_id
        AND a.state = 'proposed'
        AND (a.proposed_by = app_tenant_id() OR app_is_platform())
    )
  );

CREATE POLICY protection_corridors_removed_by_proposer ON protection_corridors
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM protection_agreements a
      WHERE a.id = agreement_id
        AND a.state = 'proposed'
        AND (a.proposed_by = app_tenant_id() OR app_is_platform())
    )
  );

-- Both parties read a movement: it is the line on an invoice one of them will
-- send and the other will pay.
CREATE POLICY protection_movements_both_parties ON protection_movements
  USING (
    sending_operator_id = app_tenant_id()
    OR receiving_operator_id = app_tenant_id()
    OR app_is_platform()
  )
  WITH CHECK (
    sending_operator_id = app_tenant_id() OR app_is_platform()
  );

-- ── Naming the other company ────────────────────────────────────────────────
--
-- An operator picks a counterparty by CODE — "TBV" — because that is what one
-- company calls another; the UUID is our bookkeeping and appears on no
-- document either of them holds. But `operators` is tenant-isolated (0004), so
-- an operator's own connection cannot read the row it is naming.
--
-- Not solved by widening the table. `operators` carries `commission_bps`,
-- `tax_id` and `settlement_account_id` — a competitor's negotiated rate is
-- precisely the thing a competitor must not read, and a SELECT policy is
-- all-columns. So the privilege moves into two functions that return the two
-- facts that are already public: an active operator's id and their trading
-- name, both of which any anonymous traveller can read from a search result
-- (0005). A caller learns nothing they could not learn by opening the app.
CREATE OR REPLACE FUNCTION operator_id_by_code(p_code TEXT)
RETURNS TABLE (id UUID, name TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT o.id, COALESCE(o.trading_name, o.legal_name)
    FROM operators o
   WHERE upper(o.code) = upper(p_code)
     AND o.status = 'active'
$$;

CREATE OR REPLACE FUNCTION operator_names(p_ids UUID[])
RETURNS TABLE (id UUID, name TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT o.id, COALESCE(o.trading_name, o.legal_name)
    FROM operators o
   WHERE o.id = ANY(p_ids)
     AND o.status = 'active'
$$;

REVOKE ALL ON FUNCTION operator_id_by_code(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_names(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operator_id_by_code(TEXT) TO bel_app, bel_admin;
GRANT EXECUTE ON FUNCTION operator_names(UUID[]) TO bel_app, bel_admin;

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON protection_agreements TO bel_app, bel_admin;
GRANT SELECT, INSERT, DELETE ON protection_corridors TO bel_app, bel_admin;

-- A movement is written once and never edited. What was moved and what it was
-- billed at is the invoice; an UPDATE here would be a rewritten invoice.
GRANT SELECT, INSERT ON protection_movements TO bel_app, bel_admin;
REVOKE UPDATE, DELETE ON protection_movements FROM bel_app, bel_admin;

-- Decision 2, as a privilege. The discount, the ceiling, the auto-accept
-- threshold, the parties and who proposed are all absent from this list, so
-- the terms cannot be edited after the counterparty agreed to them — by any
-- code path, including one written next year by somebody who never read this.
GRANT UPDATE (state, accepted_by_user, accepted_at, ended_at, ended_reason)
  ON protection_agreements TO bel_app, bel_admin;

-- An agreement is not something either party gets to make disappear. Ending
-- one is a state and a timestamp, and both sides keep seeing it.
REVOKE DELETE ON protection_agreements FROM bel_app, bel_admin;

-- The public has no business here: this is a commercial term between two
-- companies, not a fact about a coach.
REVOKE ALL ON protection_agreements FROM bel_public;
REVOKE ALL ON protection_corridors  FROM bel_public;
REVOKE ALL ON protection_movements  FROM bel_public;

COMMIT;
