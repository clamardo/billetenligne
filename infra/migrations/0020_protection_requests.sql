-- 0020_protection_requests — the seats actually change hands.
--
-- 0019 wrote down what two operators agreed to. This is the thing that
-- happens under it at 05:40 on a Tuesday: a dispatcher whose coach has failed
-- asks the company they have an agreement with for room, and that company
-- says yes.
--
-- Three decisions worth more than the columns:
--
--   1. **A request is a row, not a phone call.** `08-disruption.md` §2.3 asks
--      for an inbound queue on the receiving operator's console with a live
--      seat count and an accept/decline. That needs a durable record with a
--      state, because the interesting case is the one where nobody answers —
--      and a request nobody answered has to be visible as such rather than
--      being a call somebody remembers differently.
--
--   2. **The receiving operator decides.** The sender writes the row; only
--      the receiver may move it out of `pending`. By policy, split by
--      command, the same way 0019 splits proposing from deciding. Auto-accept
--      exists (`auto_accept_spare_above`) and is still the receiver's own
--      rule, agreed in advance and applied by the server on their behalf.
--
--   3. **Applying it crosses a tenant boundary, and that is the one thing in
--      this schema no operator connection can do.** The bookings belong to
--      the sending operator and the seats to the receiving one; neither
--      tenant can see both sides. So the movement runs under the platform
--      scope with the *agreement* as its authority — the privilege moves, and
--      the consent is re-checked inside, which is the same shape as the
--      SECURITY DEFINER transition in 0015. `protection_movements` (0019) is
--      what it writes, and both parties read that.

BEGIN;

CREATE TYPE protection_request_state AS ENUM (
  'pending', 'accepted', 'declined', 'applied', 'expired', 'failed'
);

CREATE TABLE protection_requests (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id   UUID NOT NULL REFERENCES protection_agreements(id),

  sending_operator_id   UUID NOT NULL REFERENCES operators(id),
  receiving_operator_id UUID NOT NULL REFERENCES operators(id),

  -- The broken departure and the one being asked for. Both are real rows, so
  -- the receiving console can show what it is being asked to carry rather
  -- than a number somebody typed.
  from_departure_id UUID NOT NULL REFERENCES departures(id),
  to_departure_id   UUID NOT NULL REFERENCES departures(id),

  disruption_id  UUID REFERENCES disruptions(id),

  -- How many people need a seat. Recorded at request time because it is what
  -- the receiving operator agreed to, and the source departure keeps selling
  -- and cancelling underneath.
  seats_requested INTEGER NOT NULL,

  state          protection_request_state NOT NULL DEFAULT 'pending',

  -- The dispatcher's own sentence, sent on to the other company's console.
  note           TEXT,

  requested_by_user UUID REFERENCES user_accounts(id),
  requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  decided_by_user UUID REFERENCES user_accounts(id),
  decided_at     TIMESTAMPTZ,
  decline_reason TEXT,

  -- Set when it was accepted by the receiver's own standing rule rather than
  -- by a person. Kept apart from `decided_by_user` because "nobody looked at
  -- this and it was still fine" is a different fact in a dispute.
  auto_accepted  BOOLEAN NOT NULL DEFAULT FALSE,

  -- What actually moved, once it did. Fewer than `seats_requested` is normal:
  -- partial coverage is a success (§2.2).
  seats_moved    INTEGER,
  applied_at     TIMESTAMPTZ,

  CONSTRAINT protection_request_seats_sane CHECK (seats_requested > 0),
  CONSTRAINT protection_request_two_parties
    CHECK (sending_operator_id <> receiving_operator_id),
  CONSTRAINT protection_request_departures_differ
    CHECK (from_departure_id <> to_departure_id),
  CONSTRAINT protection_request_decision_recorded CHECK (
    (state = 'pending') = (decided_at IS NULL)
  ),
  CONSTRAINT protection_request_application_recorded CHECK (
    (state = 'applied') = (applied_at IS NOT NULL AND seats_moved IS NOT NULL)
  )
);

-- One open request per pair of departures. A dispatcher tapping twice on a
-- bad connection must not queue the same rescue on the receiving console
-- twice — the second read as a second forty-two people needing seats.
CREATE UNIQUE INDEX protection_requests_one_open
  ON protection_requests (from_departure_id, to_departure_id)
  WHERE state = 'pending';

CREATE INDEX protection_requests_inbound
  ON protection_requests (receiving_operator_id, state, requested_at DESC);

CREATE INDEX protection_requests_outbound
  ON protection_requests (sending_operator_id, requested_at DESC);

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE protection_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE protection_requests FORCE ROW LEVEL SECURITY;

-- Both parties read it: one is waiting for an answer and the other owes one.
CREATE POLICY protection_requests_read ON protection_requests
  FOR SELECT USING (
    sending_operator_id = app_tenant_id()
    OR receiving_operator_id = app_tenant_id()
    OR app_is_platform()
  );

-- Only the operator whose coach has failed asks.
CREATE POLICY protection_requests_asked_by_sender ON protection_requests
  FOR INSERT WITH CHECK (
    sending_operator_id = app_tenant_id() OR app_is_platform()
  );

-- Decision 2: only the receiver answers. The sender withdrawing their own
-- request is a decline they write themselves, and is deliberately NOT allowed
-- here — a request that vanished from the receiving console while somebody
-- was deciding on it is worse than one that is answered and then ignored.
CREATE POLICY protection_requests_decided_by_receiver ON protection_requests
  FOR UPDATE
  USING (receiving_operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (receiving_operator_id = app_tenant_id() OR app_is_platform());

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON protection_requests TO bel_app, bel_admin;

-- What a decision may write, and nothing else. The seats asked for, the two
-- departures and who asked are absent: a receiving operator answering a
-- request must not be able to rewrite what they were asked.
GRANT UPDATE (state, decided_by_user, decided_at, decline_reason,
              auto_accepted, seats_moved, applied_at)
  ON protection_requests TO bel_app, bel_admin;

REVOKE DELETE ON protection_requests FROM bel_app, bel_admin;
REVOKE ALL ON protection_requests FROM bel_public;

COMMIT;
