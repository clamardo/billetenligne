-- Refunds that go back down the rail they came up.
--
-- `refunds` has carried `disbursement_intent_id` since migration 0003 and
-- nothing has ever written to it: a `source` refund was approved, the debt was
-- posted, and then it sat at `approved` forever while the screens told the
-- traveller to walk into an agency. That was honest — a promise the counter
-- has to refuse is worse than a counter somebody can walk into — and it is
-- now unnecessary.
--
-- **A disbursement is a payment intent, not a reversal.** 0003 already says
-- why: mobile-money payout is a different API, different credentials and a
-- separately funded float. So it reuses `payment_intents`, which already has
-- the state machine, the idempotency key, the poll counters and the raw event
-- log — and gains one column saying which way the money goes.
--
-- **The direction column is the whole safety property.** Without it the
-- payment poller's queue — everything `pending` — would pick up a
-- disbursement and ask the *collection* gateway what happened to it. The
-- collection API would answer "no such transaction", the poller would read
-- that as a failure, and a refund that was on its way would be recorded as
-- one that never left. The in-flight index is narrowed to collections in the
-- same statement that adds the column, so the two queues cannot be confused
-- by a query somebody writes next year.

BEGIN;

ALTER TABLE payment_intents
  ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'collect';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'payment_intents_direction_known'
  ) THEN
    ALTER TABLE payment_intents ADD CONSTRAINT payment_intents_direction_known
      CHECK (direction IN ('collect', 'disburse'));
  END IF;
END
$$;

-- A disbursement has no payer: the money is ours, going out. `msisdn` is the
-- wallet it lands in, which is the opposite of what it means on a collection
-- — hence the constraint below rather than a comment nobody reads.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'payment_intents_disburse_has_a_wallet'
  ) THEN
    ALTER TABLE payment_intents ADD CONSTRAINT payment_intents_disburse_has_a_wallet
      CHECK (direction <> 'disburse' OR msisdn IS NOT NULL);
  END IF;
END
$$;

-- The collection poller's queue, narrowed. See the header: a disbursement in
-- here would be asked about down the wrong API and recorded as failed.
DROP INDEX IF EXISTS payment_intents_inflight_idx;
CREATE INDEX payment_intents_inflight_idx
  ON payment_intents (last_polled_at NULLS FIRST)
  WHERE state IN ('pending', 'authorized') AND direction = 'collect';

CREATE INDEX IF NOT EXISTS payment_intents_disbursing_idx
  ON payment_intents (last_polled_at NULLS FIRST)
  WHERE state IN ('pending', 'authorized') AND direction = 'disburse';

-- Where the money goes, copied onto the refund at approval rather than read
-- from the original payment when it is sent. Exactly the argument
-- `payout_runs.destination` makes: a traveller who changes handsets between
-- Tuesday and Thursday must not silently redirect Tuesday's approved refund,
-- and a payment row that is later corrected must not move money.
ALTER TABLE refunds ADD COLUMN IF NOT EXISTS disburse_to TEXT;

-- A `source` refund that has nowhere to send anything is the case that must
-- never reach the worker: a cash sale, or a card whose PAN we have never seen.
-- Refused here rather than filtered there, so the impossible row cannot exist.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'refunds_source_has_a_wallet'
  ) THEN
    ALTER TABLE refunds ADD CONSTRAINT refunds_source_has_a_wallet
      CHECK (destination <> 'source' OR state = 'requested'
             OR disburse_to IS NOT NULL);
  END IF;
END
$$;

-- The worker's queue: approved refunds owed to a wallet, oldest first. Narrow
-- and partial, because it is read every few minutes and is almost always
-- empty.
CREATE INDEX IF NOT EXISTS refunds_awaiting_disbursement_idx
  ON refunds (created_at)
  WHERE state = 'approved' AND destination = 'source';

COMMENT ON COLUMN payment_intents.direction IS
  'collect: money coming in from a traveller. disburse: money going out to '
  'one, for a refund. Different API, different credentials, different float.';

COMMENT ON COLUMN refunds.disburse_to IS
  'The wallet a source refund is sent to, copied from the original payment at '
  'approval so a later change cannot redirect an approved refund.';

COMMIT;
