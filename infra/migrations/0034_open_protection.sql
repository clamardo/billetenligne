-- 0034_open_protection — the rescue you ask for when you have no friends yet.
--
-- `08-disruption.md` §5 ends with one sentence that had no schema behind it:
-- "for operators with no agreement, the console still offers open protection:
-- broadcast a seat request to any operator on the route who has opted in to
-- receive them. First to accept wins."
--
-- It matters more than the agreements do. An agreement is a relationship two
-- companies already have; the coach that breaks down on a Tuesday morning
-- belongs to somebody who has none. Until today that dispatcher's only option
-- was a refund, which is the outcome §2.2 exists to avoid.
--
-- ── The three decisions this migration is ───────────────────────────────────
--
-- **1 · A call is a row, and the row is the authority.** 0019 made an
-- agreement the thing both parties can see and neither can forge, and 0020
-- built the request on top of it. An open call has no agreement, so it has to
-- be its own authority: `protection_calls` is readable by the operators
-- invited to answer it, and that invitation is computed from data — they are
-- opted in, they are selling, and they run the road — rather than asserted by
-- a handler. A policy that says "any tenant" would make broadcast mean
-- everybody, and a call names a company having a bad morning.
--
-- **2 · The corridor is captured on the call, not joined at read time.** The
-- policy needs the endpoints to decide who may look, and a policy that joins
-- through departures → routes to find them is a policy that changes meaning
-- when the sending operator edits a route. What was broadcast is what was
-- broadcast.
--
-- **3 · Exactly one authority per request.** `protection_requests.agreement_id`
-- becomes nullable and gains a sibling, with a CHECK that one and only one is
-- set. Not two paths through the movement: the same request row, the same
-- application, the same ledger posting — reached by an agreement or by a call.
-- A second request table would have been a second set of policies to keep in
-- step with the first, and they would have drifted the first time only one of
-- them was edited.
--
-- First-to-accept-wins is a conditional UPDATE on the call, not a lock and
-- not a queue: `SET state = 'answered' WHERE id = @id AND state = 'open'`
-- affects one row for exactly one accepter, and everybody else is told the
-- call is closed. Two dispatchers reaching for the same forty-two passengers
-- at 06:04 is the normal case, not the edge one.

BEGIN;

-- ── Opting in ───────────────────────────────────────────────────────────────
--
-- A timestamp rather than a boolean, because "since when" is the question a
-- dispute asks and a boolean cannot answer. NULL is out.
ALTER TABLE operators
  ADD COLUMN open_protection_at TIMESTAMPTZ;

COMMENT ON COLUMN operators.open_protection_at IS
  'When this operator opted in to receive open protection calls (08-disruption '
  '§5). NULL means they do not receive them, which is the default: a company '
  'that has not said yes has not said yes.';

-- The operator's own commercial choice, so it joins the short list 0032 made
-- the control. Everything on that list is something the company decides about
-- itself; nothing on it is a term of trade or an enforcement, and this is on
-- the right side of that line — saying "I will take other people's passengers
-- when I have room" is a choice only they can make.
GRANT UPDATE (open_protection_at) ON operators TO bel_app;

-- ── The call ────────────────────────────────────────────────────────────────

CREATE TYPE protection_call_state AS ENUM ('open', 'answered', 'withdrawn', 'expired');

CREATE TABLE protection_calls (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sending_operator_id UUID NOT NULL REFERENCES operators(id),
  from_departure_id   UUID NOT NULL REFERENCES departures(id),
  disruption_id       UUID REFERENCES disruptions(id),

  -- Captured, not joined. See decision 2 above.
  origin_city         TEXT NOT NULL REFERENCES cities(code),
  destination_city    TEXT NOT NULL REFERENCES cities(code),

  -- How many people need a seat, at the moment the call went out. The source
  -- departure keeps cancelling underneath and this is what was asked for.
  seats_requested     INTEGER NOT NULL,

  -- What the sender offers to pay per seat, in the departure's own currency.
  -- Stated on the call rather than negotiated afterwards, because an operator
  -- deciding in ninety seconds whether to take forty-two strangers needs the
  -- number in front of them. No discount by default: a discount is something
  -- a relationship earns, and there is no relationship here.
  rebill_minor        INTEGER NOT NULL,
  currency            TEXT NOT NULL,

  state               protection_call_state NOT NULL DEFAULT 'open',
  note                TEXT,

  opened_by_user      UUID REFERENCES user_accounts(id),
  opened_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- A call with no end is a call that is still on somebody's console the
  -- following week. The sweeper closes them; the column is what it reads.
  expires_at          TIMESTAMPTZ NOT NULL,

  answered_by_operator UUID REFERENCES operators(id),
  closed_at           TIMESTAMPTZ,

  CONSTRAINT protection_call_seats_sane CHECK (seats_requested > 0),
  CONSTRAINT protection_call_rebill_sane CHECK (rebill_minor >= 0),
  CONSTRAINT protection_call_distinct_endpoints
    CHECK (origin_city <> destination_city),
  CONSTRAINT protection_call_not_self
    CHECK (answered_by_operator IS NULL
           OR answered_by_operator <> sending_operator_id),
  -- Open means open: nothing has closed it and nobody has answered.
  CONSTRAINT protection_call_closure_recorded
    CHECK ((state = 'open') = (closed_at IS NULL)),
  CONSTRAINT protection_call_answer_recorded
    CHECK ((state = 'answered') = (answered_by_operator IS NOT NULL))
);

-- One live call per broken departure. A dispatcher tapping twice on a bad
-- connection must not put two calls for the same coach on every console in
-- the country — the second read as a second forty-two people.
CREATE UNIQUE INDEX protection_calls_one_open
  ON protection_calls (from_departure_id)
  WHERE state = 'open';

-- The inbox read: every live call on a road, newest first.
CREATE INDEX protection_calls_live
  ON protection_calls (origin_city, destination_city, opened_at DESC)
  WHERE state = 'open';

-- What the sweeper walks.
CREATE INDEX protection_calls_expiring
  ON protection_calls (expires_at)
  WHERE state = 'open';

CREATE INDEX protection_calls_outbound
  ON protection_calls (sending_operator_id, opened_at DESC);

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE protection_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE protection_calls FORCE ROW LEVEL SECURITY;

-- Who was invited, computed rather than asserted.
--
-- The sender always sees their own. Everybody else sees a call only while all
-- four of these hold: they opted in, they are selling (a company blocked on
-- its own paperwork is not a company we route passengers to — 0032), they are
-- active, and they run this road. The last one is the difference between a
-- broadcast and a bulletin board.
--
-- Deliberately NOT restricted to live calls: an operator who answered one
-- last month must still be able to read the call they answered, or their own
-- movement history stops making sense.
CREATE POLICY protection_calls_read ON protection_calls
  FOR SELECT USING (
    sending_operator_id = app_tenant_id()
    OR app_is_platform()
    OR (
      EXISTS (
        SELECT 1 FROM operators o
         WHERE o.id = app_tenant_id()
           AND o.open_protection_at IS NOT NULL
           AND o.sales_blocked_at IS NULL
           AND o.status = 'active'
      )
      AND EXISTS (
        SELECT 1 FROM routes r
         WHERE r.operator_id = app_tenant_id()
           AND r.active
           AND r.origin_city = protection_calls.origin_city
           AND r.destination_city = protection_calls.destination_city
      )
    )
  );

-- Only the operator whose coach has failed calls for help.
CREATE POLICY protection_calls_opened_by_sender ON protection_calls
  FOR INSERT WITH CHECK (
    sending_operator_id = app_tenant_id() OR app_is_platform()
  );

-- And only they withdraw it. Answering is not an UPDATE any tenant performs:
-- it happens inside the movement, under the platform scope, because closing
-- the call and moving the passengers have to be the same transaction or the
-- winner is decided twice.
CREATE POLICY protection_calls_withdrawn_by_sender ON protection_calls
  FOR UPDATE
  USING (sending_operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (sending_operator_id = app_tenant_id() OR app_is_platform());

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON protection_calls TO bel_app, bel_admin;

-- What a withdrawal may write, and nothing else. `seats_requested`,
-- `rebill_minor` and the two cities are absent: a sender must not be able to
-- change the terms of a call somebody is deciding on, and a call whose price
-- moved while a console had it open is a call nobody would answer twice.
GRANT UPDATE (state, closed_at, answered_by_operator)
  ON protection_calls TO bel_app, bel_admin;

REVOKE DELETE ON protection_calls FROM bel_app, bel_admin;
REVOKE ALL ON protection_calls FROM bel_public;

-- ── One authority per request ───────────────────────────────────────────────

ALTER TABLE protection_requests
  ALTER COLUMN agreement_id DROP NOT NULL,
  ADD COLUMN call_id UUID REFERENCES protection_calls(id);

ALTER TABLE protection_requests
  ADD CONSTRAINT protection_request_one_authority CHECK (
    (agreement_id IS NULL) <> (call_id IS NULL)
  );

COMMENT ON COLUMN protection_requests.call_id IS
  'The open call this request answers, when there is no agreement. Exactly '
  'one of agreement_id and call_id is set: every movement has an authority, '
  'and which kind it is decides where the rebill price comes from.';

CREATE INDEX protection_requests_by_call ON protection_requests (call_id)
  WHERE call_id IS NOT NULL;

-- The insert policy on `protection_requests` (0020) lets the *sending*
-- operator write a request. A call is answered by the receiver, so the row
-- that records it is written under the platform scope inside the movement —
-- the same escalation 0020 already documents for applying one, and for the
-- same reason: neither tenant can see both halves.

-- ── The movement record, same rule ──────────────────────────────────────────
--
-- `protection_movements` is what one operator bills the other under, and both
-- of them read it. It carried the agreement as a NOT NULL because there was
-- no other way to be authorised; now there is, and the same XOR applies. The
-- alternative — inventing a synthetic agreement row per call — would put a
-- contract in the table that neither company ever agreed to, which is worse
-- than a nullable column by some distance.

ALTER TABLE protection_movements
  ALTER COLUMN agreement_id DROP NOT NULL,
  ADD COLUMN call_id UUID REFERENCES protection_calls(id);

ALTER TABLE protection_movements
  ADD CONSTRAINT protection_movement_one_authority CHECK (
    (agreement_id IS NULL) <> (call_id IS NULL)
  );

-- ── The queue, taught that an agreement is now optional ─────────────────────
--
-- 0022's function inner-joins the agreement, which was correct when every
-- request had one. Left join now, or every open-call rescue vanishes from
-- both consoles the moment it is made — the exact silent-empty-queue failure
-- 0022 was written to prevent, reintroduced from the other side.
--
-- Dropped and recreated rather than replaced: the signature gains a column.

DROP FUNCTION IF EXISTS protection_queue();

CREATE FUNCTION protection_queue()
RETURNS TABLE (
  id                     UUID,
  agreement_id           UUID,
  call_id                UUID,
  sending_operator_id    UUID,
  receiving_operator_id  UUID,
  from_departure_id      UUID,
  to_departure_id        UUID,
  seats_requested        INTEGER,
  state                  TEXT,
  note                   TEXT,
  requested_at           TIMESTAMPTZ,
  auto_accepted          BOOLEAN,
  seats_moved            INTEGER,
  decline_reason         TEXT,
  departs_at             TIMESTAMPTZ,
  replacement_departs_at TIMESTAMPTZ,
  route_code             TEXT,
  seats_free             INTEGER,
  replacement_fare_minor BIGINT,
  replacement_currency   TEXT,
  discount_bps           INTEGER,
  counterparty_id        UUID
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT q.id,
         q.agreement_id,
         q.call_id,
         q.sending_operator_id,
         q.receiving_operator_id,
         q.from_departure_id,
         q.to_departure_id,
         q.seats_requested,
         q.state::text,
         q.note,
         q.requested_at,
         q.auto_accepted,
         q.seats_moved,
         q.decline_reason,
         d.departs_at,
         rd.departs_at,
         rt.code,
         (SELECT count(*)::int FROM seats s
           WHERE s.departure_id = q.to_departure_id
             AND s.state = 'available'),
         rd.fare_minor,
         rd.currency,
         -- No agreement, no negotiated discount. A call is rebilled at the
         -- price it was broadcast at, and zero here is the honest reading of
         -- "nothing was negotiated" rather than a missing value.
         COALESCE(a.rebill_discount_bps, 0),
         CASE WHEN q.sending_operator_id = app_tenant_id()
              THEN q.receiving_operator_id
              ELSE q.sending_operator_id END
    FROM protection_requests q
    LEFT JOIN protection_agreements a ON a.id = q.agreement_id
    JOIN departures d  ON d.id  = q.from_departure_id
    JOIN departures rd ON rd.id = q.to_departure_id
    JOIN routes rt     ON rt.id = rd.route_id
   WHERE app_is_platform()
      OR q.sending_operator_id = app_tenant_id()
      OR q.receiving_operator_id = app_tenant_id()
   ORDER BY q.requested_at DESC
$$;

REVOKE ALL ON FUNCTION protection_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION protection_queue() TO bel_app, bel_admin;

-- ── The inbox ───────────────────────────────────────────────────────────────
--
-- The call row itself is readable by policy, but the two facts that make it
-- answerable are not: when the broken coach was due to leave, and who is
-- asking. Both live in tables the reader has no grant on, so the privilege
-- moves into a function for the third time in this codebase and, as in 0021
-- and 0022, it is narrow: no operator argument (the caller is
-- `app_tenant_id()`), the same invitation test as the read policy, and the
-- only counterparty facts it adds are ones any traveller searching that route
-- can already see.
CREATE FUNCTION open_protection_calls()
RETURNS TABLE (
  id                   UUID,
  sending_operator_id  UUID,
  sending_operator_name TEXT,
  from_departure_id    UUID,
  origin_city          TEXT,
  destination_city     TEXT,
  seats_requested      INTEGER,
  rebill_minor         INTEGER,
  currency             TEXT,
  state                TEXT,
  note                 TEXT,
  opened_at            TIMESTAMPTZ,
  expires_at           TIMESTAMPTZ,
  departs_at           TIMESTAMPTZ,
  answered_by_operator UUID,
  closed_at            TIMESTAMPTZ,
  we_opened            BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT c.id,
         c.sending_operator_id,
         COALESCE(o.trading_name, o.legal_name),
         c.from_departure_id,
         c.origin_city,
         c.destination_city,
         c.seats_requested,
         c.rebill_minor,
         c.currency,
         c.state::text,
         c.note,
         c.opened_at,
         c.expires_at,
         d.departs_at,
         c.answered_by_operator,
         c.closed_at,
         c.sending_operator_id = app_tenant_id()
    FROM protection_calls c
    JOIN operators o  ON o.id = c.sending_operator_id
    JOIN departures d ON d.id = c.from_departure_id
   WHERE app_is_platform()
      OR c.sending_operator_id = app_tenant_id()
      -- Ours to answer: still live, we opted in, we are selling, we run the
      -- road. Live matters here and not in the read policy — history is worth
      -- keeping readable, an inbox is not a filing cabinet.
      OR (
        c.state = 'open'
        AND c.expires_at > now()
        AND EXISTS (
          SELECT 1 FROM operators me
           WHERE me.id = app_tenant_id()
             AND me.open_protection_at IS NOT NULL
             AND me.sales_blocked_at IS NULL
             AND me.status = 'active'
        )
        AND EXISTS (
          SELECT 1 FROM routes r
           WHERE r.operator_id = app_tenant_id()
             AND r.active
             AND r.origin_city = c.origin_city
             AND r.destination_city = c.destination_city
        )
      )
   ORDER BY c.opened_at DESC
$$;

REVOKE ALL ON FUNCTION open_protection_calls() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION open_protection_calls() TO bel_app, bel_admin;

COMMIT;
