-- A hold, and the booking it becomes, remember which piece of road they are
-- for (ADR-0025).
--
-- Occupancy has carried the span since 0035, and for the *inventory* question
-- — is this seat free between Dolisie and Pointe-Noire — that is enough.
-- Two other questions are not answerable from it:
--
--   * **what was quoted.** A leg is priced by the operator, flat, and the
--     price the traveller was shown at the moment they claimed the seat is
--     the price the reservation must charge. Re-deriving it four hours later
--     at the counter would let a price list edited in between rewrite what
--     somebody agreed to pay.
--   * **what was sold.** Occupancy is deleted when the journey is refunded or
--     the coach is swapped; the booking is the record that outlives it, and a
--     conductor reading a manifest needs to know where this passenger gets on
--     and off.
--
-- Both columns are NULL for a whole-road sale, which is every sale that
-- exists today: NULL means "the road as the departure defined it", so nothing
-- has to be backfilled and no existing path changes behaviour.

BEGIN;

ALTER TABLE holds
  ADD COLUMN road_span          INT4RANGE,
  -- Per seat, not per hold. A family of three buying the Dolisie leg pays
  -- three times the leg's price, and the arithmetic belongs where every other
  -- fare in this schema does — on the seat.
  ADD COLUMN segment_fare_minor BIGINT;

ALTER TABLE bookings
  ADD COLUMN road_span INT4RANGE;

COMMENT ON COLUMN holds.road_span IS
  'The piece of road this hold took, or NULL for the whole road as the '
  'departure defined it (ADR-0025).';
COMMENT ON COLUMN holds.segment_fare_minor IS
  'What one seat on that piece was quoted at, and what the reservation will '
  'charge. NULL on a whole-road hold, which prices from the seat row.';
COMMENT ON COLUMN bookings.road_span IS
  'Where this passenger gets on and off, as positions into the departure''s '
  'road (ADR-0025). NULL is the whole journey.';

-- A span with no price is a leg nobody could be charged for, and a price with
-- no span is a number attached to nothing. Neither is a state any path here
-- can produce, and both would be discovered at a counter.
ALTER TABLE holds
  ADD CONSTRAINT holds_segment_is_whole
    CHECK ((road_span IS NULL) = (segment_fare_minor IS NULL)),
  ADD CONSTRAINT holds_segment_fare_positive
    CHECK (segment_fare_minor IS NULL OR segment_fare_minor > 0);

-- ── And the traveller cannot edit what they were quoted ─────────────────────
--
-- 0005 gave `bel_public` a table-wide UPDATE on `holds`, for one purpose: a
-- traveller releasing their own hold, and the reserve path consuming it. Both
-- write `state` and nothing else.
--
-- With a price on the row that stops being harmless. A table-wide grant would
-- let a traveller set `segment_fare_minor` to 1 on their own hold and then
-- reserve it — the reservation charges what the hold says it quoted, which is
-- exactly why that column exists. So the grant becomes the column it always
-- was in practice. Same lesson as 0032 and 0035: the list is the control, and
-- a column REVOKE under a table-level grant is decoration.
REVOKE UPDATE ON holds FROM bel_public;
GRANT UPDATE (state) ON holds TO bel_public;

COMMIT;
