-- 0025_change_terms — what a change costs, stored beside what a refund gives.
--
-- ADR-0012 D-08 states three numbers: free with at least so much notice, a
-- percentage of the fare inside a window, refused closer than a cutoff. They
-- were written into the ADR and lived nowhere, so `01-feature-spec.md` §8.1 —
-- "the fare difference and any fee shown live on every result row" — had
-- nothing to read.
--
-- **They go on `refund_policies` rather than into a table of their own.**
-- That name is now narrower than what the row holds, and renaming it would
-- touch every join, every grant and the composite foreign key that makes
-- ADR-0015 rule 1 work — so the columns are prefixed instead and this comment
-- is the record of the decision. What is gained is the whole point: a booking
-- already stamps `(refund_policy_id, refund_policy_version)` at sale time, so
-- change terms travel with the booking under exactly the same rule, judged
-- forever by the version it was sold under, with no second versioning scheme
-- to keep honest.
--
-- Defaults are D-08's own. An operator who has never thought about changes
-- sells under the numbers the ADR argued for, rather than under NULLs that
-- every reader would have to invent a fallback for.

BEGIN;

ALTER TABLE refund_policies
  ADD COLUMN change_free_hours   INTEGER NOT NULL DEFAULT 24,
  ADD COLUMN change_fee_bps      INTEGER NOT NULL DEFAULT 1000,
  ADD COLUMN change_cutoff_hours INTEGER NOT NULL DEFAULT 2,

  -- The same guard the domain applies before storing, expressed where it
  -- cannot be bypassed by a second writer. A cutoff longer than the free
  -- window leaves no fee band at all: every change inside it is refused as
  -- too late, and nobody notices until the month's changes are counted.
  ADD CONSTRAINT refund_policies_change_window_ordered
    CHECK (change_free_hours >= change_cutoff_hours),
  ADD CONSTRAINT refund_policies_change_fee_is_a_rate
    CHECK (change_fee_bps BETWEEN 0 AND 10000),
  ADD CONSTRAINT refund_policies_change_hours_non_negative
    CHECK (change_cutoff_hours >= 0);

COMMIT;
