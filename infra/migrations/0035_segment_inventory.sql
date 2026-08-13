-- Segment selling: a seat's occupancy becomes a range (ADR-0025).
--
-- The Brazzaville–Pointe-Noire coach passes through Dolisie and every
-- operator on that road already sells the Dolisie leg, out of a notebook, at
-- the roadside. `route_stops` has described the road since the last slice.
-- What has been in the way is one column: `seats.state` is a scalar, and
-- "sold Brazzaville→Dolisie and free Dolisie→Pointe-Noire" is one row with
-- two answers.
--
-- Four decisions, each argued in ADR-0025 and restated here because this file
-- is what somebody reads at two in the morning:
--
--   1. Occupancy is a **half-open range of stop positions in its own table**,
--      and "two people cannot buy the same piece of the same seat" is an
--      EXCLUDE constraint rather than a check in a handler. `[0,2)` and
--      `[2,4)` do not overlap, which is exactly right: a passenger alighting
--      at Dolisie and one boarding at Dolisie share no part of the journey.
--
--   2. **The whole road is a range too.** An ordinary sale writes `[0,N)` and
--      takes the same path as a segment. A design where the usual case
--      bypasses the new machinery is a design where the new machinery is
--      untested in production.
--
--   3. **`seats.state` stays and stops being written by hand** — it becomes
--      derived from occupancy by trigger, and gains `partial`. Every reader
--      that has not been taught about segments therefore fails *closed*: it
--      asks "is this available?" and hears no, because not all of it is.
--
--   4. **A segment is sellable only when the operator has priced it.** No
--      distance-based fraction of the through fare: a fare is a commercial
--      decision, and an operator who finds we invented one will find it on
--      the day a passenger paid it. Which is also what makes this shippable —
--      until somebody prices a segment, every departure sells its whole road
--      for its whole fare exactly as it does today.

-- Outside the transaction below: a new enum value cannot be added and used in
-- the same transaction, and the rest of this file must be able to name it.
ALTER TYPE seat_state ADD VALUE IF NOT EXISTS 'partial';

BEGIN;

-- For the `=` parts of the exclusion constraint. Ships with Postgres.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ── The road a departure was sold on ────────────────────────────────────────
--
-- Captured on the departure rather than joined from the route, and that is
-- the property the whole model rests on: a stop inserted next month must not
-- re-number what was sold last month. Positions run origin = 0, each
-- `route_stops.sequence` in order, destination last — so a road with no
-- intermediate stops is `[0,1)`, one leg, which is every departure that
-- exists today.
ALTER TABLE departures
  ADD COLUMN road_span INT4RANGE NOT NULL DEFAULT '[0,1)';

COMMENT ON COLUMN departures.road_span IS
  'The positions this departure was put on sale with (ADR-0025). Origin is 0 '
  'and the destination is the upper bound, exclusive. Captured here rather '
  'than joined from route_stops so that editing a road does not renumber '
  'journeys already sold.';

-- ── What an operator has priced ─────────────────────────────────────────────

CREATE TABLE segment_fares (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  route_id      UUID NOT NULL REFERENCES routes(id) ON DELETE CASCADE,

  -- Positions into the road, not city codes: a road that visits the same town
  -- twice is unusual and not impossible, and a pair of codes cannot say which
  -- visit was meant.
  from_position INTEGER NOT NULL,
  to_position   INTEGER NOT NULL,

  fare_minor    BIGINT NOT NULL,
  currency      CHAR(3) NOT NULL,

  -- Withdrawn rather than deleted: a segment that stops being sold is a
  -- commercial decision somebody will ask about, and the bookings sold under
  -- it still point at the road it described.
  active        BOOLEAN NOT NULL DEFAULT TRUE,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (route_id, from_position, to_position),

  CONSTRAINT segment_fare_span_sane
    CHECK (from_position >= 0 AND to_position > from_position),
  -- A free seat is not a price, it is a mistake. Zero would also fail the
  -- ledger's positive-amount check three tables downstream.
  CONSTRAINT segment_fare_positive CHECK (fare_minor > 0)
);

CREATE INDEX segment_fares_route_idx
  ON segment_fares (route_id) WHERE active;

COMMENT ON TABLE segment_fares IS
  'What an operator charges for a piece of a road (ADR-0025). A pair with no '
  'row here is not sellable — there is deliberately no pro-rata fallback.';

-- ── Occupancy ───────────────────────────────────────────────────────────────

CREATE TABLE seat_occupancy (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  departure_id UUID NOT NULL,
  seat_label   TEXT NOT NULL,
  operator_id  UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  -- Half-open, always. See the header.
  span         INT4RANGE NOT NULL,

  hold_id      UUID REFERENCES holds(id) ON DELETE CASCADE,
  booking_id   UUID REFERENCES bookings(id),

  -- Mirrors the hold's own expiry, so the claim path can clear lapsed
  -- occupancy without joining. See the note on sweeping below.
  held_until   TIMESTAMPTZ,

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  FOREIGN KEY (departure_id, seat_label)
    REFERENCES seats (departure_id, seat_label) ON DELETE CASCADE,

  -- A hold or a booking, never both and never neither: occupancy with no
  -- authority behind it is a seat nobody can account for.
  CONSTRAINT seat_occupancy_one_authority
    CHECK (num_nonnulls(hold_id, booking_id) = 1),
  CONSTRAINT seat_occupancy_hold_expires
    CHECK ((hold_id IS NULL) = (held_until IS NULL)),
  CONSTRAINT seat_occupancy_span_sane
    CHECK (lower(span) >= 0 AND upper(span) > lower(span)),

  -- The reason this table exists. Not a handler, not a SELECT-then-INSERT:
  -- Postgres refuses the second row, and refuses it under concurrency, which
  -- is the only condition that matters on a Friday afternoon.
  EXCLUDE USING gist (
    departure_id WITH =,
    seat_label   WITH =,
    span         WITH &&
  )
);

CREATE INDEX seat_occupancy_hold_idx
  ON seat_occupancy (hold_id) WHERE hold_id IS NOT NULL;
CREATE INDEX seat_occupancy_booking_idx
  ON seat_occupancy (booking_id) WHERE booking_id IS NOT NULL;
-- What the sweeper walks.
CREATE INDEX seat_occupancy_lapsing_idx
  ON seat_occupancy (held_until) WHERE held_until IS NOT NULL;

COMMENT ON TABLE seat_occupancy IS
  'Which part of which seat is taken, and by whom (ADR-0025). A lapsed hold '
  'still has a row until it is swept; the claim path clears rows whose '
  'held_until has passed before inserting, exactly as seats.held_until has '
  'always been checked on read as well as swept — a stalled worker must not '
  'be able to leak inventory, and must not be able to lock it either.';

-- ── seats.state, derived ────────────────────────────────────────────────────
--
-- One source of truth and a fast read is a column the database maintains, not
-- two writers who agree until the afternoon they do not.
-- SECURITY DEFINER, and narrowly: a derived column has to be derived the same
-- way whoever wrote the occupancy row — a traveller holding a seat, an
-- operator selling one at a counter, the sweeper letting one go — and a
-- summary that depended on the writer's own grants would be a summary that
-- disagreed with itself. It reads no argument from the caller and touches
-- exactly the one seat the row named.
CREATE FUNCTION seat_state_from_occupancy() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  dep    UUID := COALESCE(NEW.departure_id, OLD.departure_id);
  label  TEXT := COALESCE(NEW.seat_label,   OLD.seat_label);
  road   INT4RANGE;
  taken  INT4MULTIRANGE;
  holds  INT;
  books  INT;
  one_hold UUID;
  one_book UUID;
  until  TIMESTAMPTZ;
BEGIN
  SELECT d.road_span INTO road FROM departures d WHERE d.id = dep;

  SELECT range_agg(o.span),
         count(*) FILTER (WHERE o.hold_id IS NOT NULL),
         count(*) FILTER (WHERE o.booking_id IS NOT NULL),
         -- `min()` has no uuid form, and picking "the" id only means
         -- anything when there is exactly one anyway.
         (array_agg(o.hold_id)    FILTER (WHERE o.hold_id    IS NOT NULL))[1],
         (array_agg(o.booking_id) FILTER (WHERE o.booking_id IS NOT NULL))[1],
         max(o.held_until)
    INTO taken, holds, books, one_hold, one_book, until
    FROM seat_occupancy o
   WHERE o.departure_id = dep AND o.seat_label = label;

  IF taken IS NULL THEN
    UPDATE seats SET state = 'available', hold_id = NULL, held_until = NULL,
                     booking_id = NULL
     WHERE departure_id = dep AND seat_label = label;
    RETURN NULL;
  END IF;

  -- Covered end to end, or not. `partial` is the honest answer to a reader
  -- that has not been taught about segments, and it is refused by every
  -- `state = 'available'` filter in the product — which is the direction a
  -- change to inventory has to fail in.
  IF road <@ taken THEN
    IF books > 0 THEN
      UPDATE seats
         SET state = 'sold',
             booking_id = CASE WHEN books = 1 THEN one_book ELSE NULL END,
             hold_id = NULL, held_until = NULL
       WHERE departure_id = dep AND seat_label = label;
    ELSE
      UPDATE seats
         SET state = 'held', hold_id = one_hold, held_until = until,
             booking_id = NULL
       WHERE departure_id = dep AND seat_label = label;
    END IF;
  ELSE
    -- `seats_hold_consistent` insists a non-held seat carries no hold id, and
    -- it is right to: a partial seat has several, and one of them on the row
    -- would be a lie that reads like a fact.
    UPDATE seats
       SET state = 'partial', hold_id = NULL, held_until = NULL,
           booking_id = CASE WHEN books = 1 THEN one_book ELSE NULL END
     WHERE departure_id = dep AND seat_label = label;
  END IF;

  RETURN NULL;
END
$$;

CREATE TRIGGER seat_occupancy_state
  AFTER INSERT OR UPDATE OR DELETE ON seat_occupancy
  FOR EACH ROW EXECUTE FUNCTION seat_state_from_occupancy();

-- `seats_sold_consistent` predates this and says a sold seat carries the
-- booking that sold it. A seat sold to two passengers on two legs has two,
-- and the column can hold one — so the constraint has to go, and the
-- invariant it was protecting moves to where it can still be stated:
-- `seat_occupancy_one_authority` says every occupied piece of every seat has
-- exactly one hold or one booking behind it, which is the stronger claim and
-- the one that was actually meant.
ALTER TABLE seats DROP CONSTRAINT seats_sold_consistent;

COMMENT ON COLUMN seats.booking_id IS
  'The booking that sold this seat, when exactly one did. NULL on a seat sold '
  'in pieces to different passengers (ADR-0025) — ask seat_occupancy, which '
  'is where the answer stopped being a scalar.';

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE seat_occupancy ENABLE ROW LEVEL SECURITY;
ALTER TABLE seat_occupancy FORCE ROW LEVEL SECURITY;
ALTER TABLE segment_fares  ENABLE ROW LEVEL SECURITY;
ALTER TABLE segment_fares  FORCE ROW LEVEL SECURITY;

-- Occupancy is inventory, and inventory is public: a traveller reading a seat
-- map has always been able to see which seats are taken. What they cannot see
-- is *by whom* — the hold and booking ids are on the row, so the public grant
-- below is column-level and names neither.
CREATE POLICY seat_occupancy_read ON seat_occupancy
  FOR SELECT USING (TRUE);

CREATE POLICY seat_occupancy_write ON seat_occupancy
  FOR ALL TO bel_app, bel_admin
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- The traveller writes occupancy the same way they write a hold: through the
-- claim path, for a seat on a departure that is on sale. The authority is the
-- hold they own, which is why this policy asks about the hold rather than
-- about them.
CREATE POLICY seat_occupancy_traveller ON seat_occupancy
  FOR INSERT TO bel_public
  WITH CHECK (
    hold_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM holds h
       WHERE h.id = seat_occupancy.hold_id AND h.user_id = app_user_id()
    )
  );

CREATE POLICY seat_occupancy_traveller_release ON seat_occupancy
  FOR DELETE TO bel_public
  USING (
    hold_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM holds h
       WHERE h.id = seat_occupancy.hold_id AND h.user_id = app_user_id()
    )
  );

-- A price list is a shop window: everybody reads it, the operator alone
-- writes it.
CREATE POLICY segment_fares_read ON segment_fares
  FOR SELECT USING (TRUE);

CREATE POLICY segment_fares_write ON segment_fares
  FOR ALL TO bel_app, bel_admin
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- ── Grants ──────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE, DELETE ON seat_occupancy TO bel_app, bel_admin;
GRANT SELECT, INSERT, DELETE ON seat_occupancy TO bel_public;
GRANT SELECT ON segment_fares TO bel_public;
GRANT SELECT, INSERT, UPDATE, DELETE ON segment_fares TO bel_app, bel_admin;

-- ── The road is not rewritable after the fact ───────────────────────────────
--
-- Which needs the same treatment 0032 gave `operators`, and for the same
-- reason: `bel_app` held a table-wide UPDATE on `departures`, and revoking
-- one column while a table-level grant stands is a control that reads as
-- working and does nothing. So the table grant goes and a column list takes
-- its place — the list is the control.
--
-- `road_span` is absent from it. A departure's road is what a passenger
-- bought a piece of, and an operator who could rewrite it after the sale
-- could move somebody's alighting point. `id`, `operator_id` and `created_at`
-- are absent too, and were never sensible to write.
REVOKE UPDATE ON departures FROM bel_app;
GRANT UPDATE (
  route_id, pattern_id, vehicle_id, seat_layout_id, departs_at, arrives_at,
  capacity, fare_minor, currency, status, seat_selection_enabled,
  sales_close_at, mode, amenities, origin_station_id, destination_station_id
) ON departures TO bel_app;

COMMIT;
