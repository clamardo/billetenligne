-- 0051_the_passenger_sees_the_road — the ticket holder reads the checkpoints
-- (`18-…-can-join.md` J6).
--
-- 0043 gave the road somewhere to report itself and one reader: `followed_trip
-- (TEXT)`, keyed on a share token, granted to `bel_public`. The person with
-- the most reason to want it is the one that reader cannot serve. A passenger
-- **on the coach**, whose phone is already in their hand, has no token unless
-- they happened to mint a link for somebody else — so the traveller app has
-- had to show a QR and a departure time and nothing about where the coach
-- actually is.
--
-- This grants them the read, and the interesting part is that it is a policy
-- rather than a fourth SECURITY DEFINER function.
--
--   * **0043 refused a SELECT policy, and it was right to.** The caller it was
--     refusing it to was a *stranger holding a token*: a row-level rule for
--     `bel_public` in that shape is enumerable across every operator's
--     movements, which is why the definer function returns the one checkpoint
--     that matters and nothing else. That reasoning does not reach this
--     caller. A ticket holder is identified — `app_user_id()` — and the rule
--     below resolves to the departures they hold a **confirmed** booking on,
--     which is a set of one or two coaches and not a feed.
--
--   * **A policy is a guarantee the whole system keeps, not one this
--     handler keeps.** The invariant in CLAUDE.md is that tenancy is row-level
--     and enforced by Postgres. Written this way, "a traveller reads the
--     checkpoints of coaches they are on" is true of every future query
--     against this table under a traveller scope, including the ones nobody
--     has written; a definer function is true only of the callers that
--     remember to go through it.
--
--   * **`confirmed`, so a cancelled booking sees nothing.** Somebody who
--     cancelled last week is not on that coach, and where a coach is is not
--     their business any more. Refused by the schema rather than by a `WHERE`
--     clause in Dart, because that is a clause somebody eventually drops.
--
-- Append-only survives untouched: this adds SELECT and nothing else, and the
-- REVOKE of UPDATE and DELETE from 0043 still stands. A traveller who could
-- edit a claim about where a coach was would be editing evidence in a delay
-- dispute.

BEGIN;

-- Enumerated one table at a time, the way 0005 does it. The list IS the
-- public attack surface.
GRANT SELECT ON departure_checkpoints TO bel_public;

DROP POLICY IF EXISTS departure_checkpoints_ticket_holder_read
  ON departure_checkpoints;

CREATE POLICY departure_checkpoints_ticket_holder_read
  ON departure_checkpoints
  FOR SELECT USING (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.departure_id = departure_checkpoints.departure_id
         AND b.purchaser_user_id = app_user_id()
         AND b.state = 'confirmed'
    )
  );

-- The road itself is already public (0005), and so are `departures`,
-- `routes`, `cities` and `stations`. Nothing there needs widening: what a
-- passenger is being shown is the timetable they were sold plus the taps
-- their own conductor made.

COMMIT;
