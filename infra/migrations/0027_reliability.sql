-- 0027_reliability — the on-time figure, stored rather than recomputed.
--
-- `08-disruption.md` §6 asks for a reliability score surfaced in search
-- results — *« 92 % à l'heure »* — on the argument that it turns reliability
-- into a competitive advantage instead of a hidden cost. The contracts have
-- carried `onTimeRate` since the search results were first drawn; nothing has
-- ever computed one.
--
-- **It is a column, not a query.** Search is the hot path: a join over ninety
-- days of departures and their disruptions, run on every search on a 2G
-- connection, is how a results screen becomes slow for a figure that changes
-- once a day. A nightly worker pass writes it; every reader is a column read.
--
-- **NULL is a real answer and the common one.** An operator with three
-- departures and one breakdown is not "67 % on time" — it is an operator we
-- do not know about yet, and printing a figure from four data points is worse
-- than printing nothing. The sample is stored beside the rate so the decision
-- is auditable rather than buried in whichever query last ran.

BEGIN;

ALTER TABLE operators
  ADD COLUMN on_time_rate           SMALLINT,
  ADD COLUMN reliability_sample     INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN reliability_computed_at TIMESTAMPTZ,

  ADD CONSTRAINT operators_on_time_rate_is_a_percentage
    CHECK (on_time_rate IS NULL OR on_time_rate BETWEEN 0 AND 100),
  ADD CONSTRAINT operators_reliability_sample_non_negative
    CHECK (reliability_sample >= 0);

COMMIT;
