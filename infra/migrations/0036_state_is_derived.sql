-- `seats.state` stops being writable at all (ADR-0025).
--
-- 0035 built the occupancy table and the trigger that derives `seats.state`
-- from it, and left the old writers in place: eleven code paths still set the
-- state by hand, and the derived column agreed with them only because nobody
-- had written a range that disagreed yet. Two writers who agree until the
-- afternoon they do not is the failure this whole slice exists to remove.
--
-- The code half of that move is in this release. This file is the half that
-- makes it stick: the privilege to write the column goes away, so a path
-- added next year that reaches for `UPDATE seats SET state` fails in the test
-- suite rather than in production, and the trigger — SECURITY DEFINER, owned
-- by the migration role — remains the only thing that can write it.
--
-- Nothing here is a data change. If this migration runs against a database
-- whose code has not been updated, sales stop working loudly, which is the
-- correct direction for a change to inventory to fail in.

BEGIN;

-- ── Nobody writes a seat by hand ────────────────────────────────────────────
--
-- `bel_public` was granted UPDATE in 0005 for exactly one statement — the
-- claim path marking a seat held. That statement is now an INSERT into
-- `seat_occupancy`, so the grant has nothing left to authorise.
--
-- `bel_app` and `bel_admin` hold theirs from the blanket grant in 0004, which
-- is why this REVOKE names them: the seat rows themselves are still created
-- and deleted by an operator putting a coach on a road, and only the three
-- derived columns were ever written after that.
REVOKE UPDATE ON seats FROM bel_public, bel_app, bel_admin;

COMMENT ON COLUMN seats.state IS
  'Derived from seat_occupancy by trigger (ADR-0025). Not writable by any '
  'application role — ask seat_occupancy what is taken, and write there.';

-- ── A lapsed hold is nobody''s ──────────────────────────────────────────────
--
-- The claim path has always treated an expired hold as available on read
-- rather than waiting for the sweeper, because a worker that has been stuck
-- for ten minutes must not be able to strand an operator's inventory. Under
-- occupancy that read becomes a DELETE, and the traveller doing it is not the
-- traveller who let the hold lapse — so the release policy from 0035, which
-- asks whether the hold is yours, cannot authorise it.
--
-- Policies are OR'ed, so this adds precisely one case: a piece of a seat
-- whose deadline has passed can be cleared by whoever wants to sit in it. It
-- names `held_until <= now()` — the database's clock, never a client's — and
-- it cannot touch a sold seat, which carries no deadline at all.
CREATE POLICY seat_occupancy_lapsed ON seat_occupancy
  FOR DELETE TO bel_public
  USING (
    hold_id IS NOT NULL
    AND held_until IS NOT NULL
    AND held_until <= now()
  );

-- ── A reservation moves its own deadline ────────────────────────────────────
--
-- Reserving from a hold — walk in and pay at the counter within four hours —
-- runs under the traveller's own role, and all it changes about the seats is
-- how long they stay theirs. Before ADR-0025 that was `seats.held_until`,
-- covered by the UPDATE grant taken away above.
--
-- So the traveller gets that one column back, on their own hold, and nothing
-- else: not the span, not the booking, not somebody else's row. The *length*
-- of the extension is the server's — a column grant cannot constrain a value
-- — but it can only happen once per hold, because the reserve path consumes
-- the hold in the same transaction and refuses one that is not active.
GRANT UPDATE (held_until) ON seat_occupancy TO bel_public;

CREATE POLICY seat_occupancy_traveller_extend ON seat_occupancy
  FOR UPDATE TO bel_public
  USING (
    hold_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM holds h
       WHERE h.id = seat_occupancy.hold_id AND h.user_id = app_user_id()
    )
  )
  WITH CHECK (
    hold_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM holds h
       WHERE h.id = seat_occupancy.hold_id AND h.user_id = app_user_id()
    )
  );

COMMIT;
