-- 0029_missed_departure — the passenger who was late, and what happens next.
--
-- Today a missed coach is a dead ticket. Self-service change offers only
-- departures on the same route that have not left yet, and D-08's cutoff has
-- already refused anybody inside two hours of departure — so a passenger
-- standing at the terminal at 06:05 for the 06:00 has been refused twice over
-- before they open their telephone. What actually happens is that they plead
-- with the agent, and the agent puts them on the 09:30 or does not, according
-- to nothing written down.
--
-- These two numbers are that decision, written down. They live on
-- `refund_policies` for the reason 0025 gave: a booking already stamps
-- `(refund_policy_id, refund_policy_version)` at sale time, so the terms a
-- missed passenger is judged by are the ones they were sold under, with no
-- second versioning scheme to keep honest.
--
-- **Both default to zero, which means "not offered".** Unlike 0025, there is
-- no ADR default to inherit: honouring a missed ticket is a commercial
-- promise, not a platform behaviour, and a default that quietly gave away
-- seats on every operator's coaches would be us making that promise on their
-- behalf. An operator opts in by answering the question.
BEGIN;

ALTER TABLE refund_policies
  -- How long a missed ticket keeps any value. Zero: it does not.
  ADD COLUMN missed_window_hours INTEGER NOT NULL DEFAULT 0,
  -- What the transfer costs, as a share of the fare already paid. Charged on
  -- top of any fare difference, and settled before the passenger moves.
  ADD COLUMN missed_fee_bps      INTEGER NOT NULL DEFAULT 0,

  ADD CONSTRAINT refund_policies_missed_window_non_negative
    CHECK (missed_window_hours >= 0),
  ADD CONSTRAINT refund_policies_missed_fee_is_a_rate
    CHECK (missed_fee_bps BETWEEN 0 AND 10000);

-- What a counter actually did, and to which coach.
--
-- Not a new kind of booking and not a `booking_changes` row: nothing is held
-- and nothing is awaited. A missed transfer is decided, paid for and applied
-- in one conversation across a counter, so what is stored is the record of it
-- having happened — which is the row somebody reads six weeks later when a
-- passenger says they were charged twice.
CREATE TABLE missed_transfers (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id     UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  operator_id    UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  from_departure_id UUID NOT NULL REFERENCES departures(id),
  to_departure_id   UUID NOT NULL REFERENCES departures(id),
  seat_labels       TEXT[] NOT NULL,

  fee_minor         BIGINT NOT NULL,
  difference_minor  BIGINT NOT NULL,
  paid_minor        BIGINT NOT NULL,
  currency          CHAR(3) NOT NULL,

  -- Which drawer took the money, when any was taken. A transfer that cost
  -- nothing has no till, and that is the honest shape rather than a station
  -- invented to satisfy a NOT NULL.
  station_id     UUID REFERENCES stations(id),
  moved_by       UUID REFERENCES user_accounts(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT missed_transfers_amounts_non_negative
    CHECK (fee_minor >= 0 AND difference_minor >= 0 AND paid_minor >= 0),
  CONSTRAINT missed_transfers_paid_is_the_sum
    CHECK (paid_minor = fee_minor + difference_minor),
  CONSTRAINT missed_transfers_actually_move
    CHECK (from_departure_id <> to_departure_id),
  CONSTRAINT missed_transfers_have_seats
    CHECK (cardinality(seat_labels) > 0),
  -- Money in a drawer has to say which drawer. A paid transfer with no
  -- station is cash nobody can reconcile at the end of a shift.
  CONSTRAINT missed_transfers_paid_has_a_till
    CHECK (paid_minor = 0 OR station_id IS NOT NULL)
);

CREATE INDEX missed_transfers_booking_idx ON missed_transfers (booking_id);
CREATE INDEX missed_transfers_operator_day_idx
  ON missed_transfers (operator_id, created_at DESC);

ALTER TABLE missed_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE missed_transfers FORCE ROW LEVEL SECURITY;

-- The operator's own record, and ours. A traveller has no read here on
-- purpose: what they need is their ticket, which now points at the new coach,
-- and a second story about the same journey is a second thing to disagree.
CREATE POLICY missed_transfers_tenant ON missed_transfers
  FOR ALL USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

GRANT SELECT, INSERT ON missed_transfers TO bel_app;
GRANT SELECT, INSERT ON missed_transfers TO bel_admin;

COMMIT;
