-- 0050_departure_lifecycle — a departure has a state (`18-…-can-join.md` J4).
--
-- The second half of what 0049 began. `departure_status` has carried six
-- values since the first migration and three of them were unreachable:
-- `delayed` and `cancelled` are written by the disruption path, and
-- `boarding`, `departed` and `arrived` were written by nothing at all.
--
-- A state nothing writes is a state every reader has to guess at. It is why
-- the follower page draws an estimate rather than an observation, why nothing
-- could answer "has it gone?", and why "tell the passenger who has not
-- arrived" had no moment at which somebody was missing.
--
-- No new enum and no new table. What is missing is not the vocabulary, it is
-- **when** — a status column says a coach has left and cannot say at what
-- time, which is the only fact a delay dispute actually turns on. Three
-- write-once timestamps, and the name of whoever closed it.
--
-- Three decisions worth the ink:
--
--   * **Write-once, in the application's guard rather than a trigger.** Each
--     of these is set with `COALESCE(col, @at)` under a `WHERE status = @from`
--     that already makes the transition one-way, so a scanner outbox emptying
--     three hours late cannot move `departed_at` to the hour it found signal.
--     A trigger would enforce the same thing twice and be the second place to
--     look when the two disagreed.
--
--   * **The device's clock for `boarding_at`, ours for the rest.** Boarding
--     happens at a door in a dead zone and the earliest scan on the handset
--     is the only clock that was there — the same rule `redemptions` already
--     follows. Closing a departure, by contrast, is an online action by
--     definition: it stops sales, and a close that syncs later has not
--     stopped anything. So it is stamped by Postgres, which is the one clock
--     every API instance shares.
--
--   * **`closed_by` is on the departure, not in an audit table.** One row per
--     departure, read in exactly one situation — a passenger says the coach
--     left early — and the question is always "who said it had gone", never
--     "list every state this coach has been in". A log table for a fact with
--     one writer is a join added for nobody.

BEGIN;

ALTER TABLE departures
  -- The first ticket scanned at the door. Carries the handset's own clock.
  ADD COLUMN IF NOT EXISTS boarding_at TIMESTAMPTZ,

  -- The crew's own action, and the moment new sales stop. Never a ticket:
  -- somebody who boarded and is sitting down has a valid ticket by
  -- definition, and a scan uploaded from a dead zone after this must still be
  -- accepted — the door happened while the coach was there.
  ADD COLUMN IF NOT EXISTS departed_at TIMESTAMPTZ,

  ADD COLUMN IF NOT EXISTS arrived_at  TIMESTAMPTZ,

  -- Who said it had gone. `ON DELETE SET NULL` rather than CASCADE, because
  -- a departure is not deleted when a driver's account is: the record of the
  -- coach outlives the record of who was employed to drive it.
  ADD COLUMN IF NOT EXISTS closed_by   UUID
    REFERENCES user_accounts(id) ON DELETE SET NULL;

-- The column list on `departures` **is** the control (0035 §"the road is not
-- rewritable after the fact"): `bel_app` holds no table-wide UPDATE, so a new
-- column is unwritable until it is named here. Four more, and nothing else —
-- `road_span`, `id`, `operator_id` and `created_at` stay out for the reasons
-- 0035 gives.
GRANT UPDATE (boarding_at, departed_at, arrived_at, closed_by)
  ON departures TO bel_app;

-- "Which coaches are still open?" — the sale path's own question, asked on
-- every claim. Partial, because the rows that matter are the small live end
-- of a table that only grows.
CREATE INDEX IF NOT EXISTS departures_open_idx
  ON departures (operator_id, departs_at)
  WHERE status IN ('scheduled', 'delayed', 'boarding');

COMMIT;
