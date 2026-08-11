-- 0023_trip_shares — "share my trip" and the follower page (ADR-0014 §2).
--
-- A traveller sends a link through WhatsApp and somebody at the far end
-- watches a coach cross 512 km of the RN1. That person is not a customer,
-- holds no account, and is on a phone we know nothing about — so the read has
-- to work for an anonymous caller, and everything about this table is shaped
-- by that one fact.
--
-- Three decisions worth the ink:
--
--   * **The token is stored as a hash**, like a sign-in code (0007) and a
--     refund claim. The plaintext exists once, in the response that creates
--     it. A database dump, a replica, a backup on somebody's laptop — none of
--     them is a set of working links into people's journeys.
--   * **The follower reads through a SECURITY DEFINER function**, not through
--     a policy. A SELECT policy on this table would be all-columns and
--     row-enumerable: `bel_public` could walk every share that exists. The
--     function takes the hash, returns the handful of facts ADR-0014 lists,
--     and returns nothing at all for a token it does not hold.
--   * **The function decides what a follower may see, in SQL.** Route,
--     operator, times, status. Never the seat, the phone number, the fare or
--     the booking reference. Putting that list in a handler would make it a
--     line somebody edits; putting it in the function's return type makes
--     adding a column a decision.
--
-- One live share per booking: sharing twice hands out the same link rather
-- than a second one, because two live links are two things to revoke and the
-- traveller only knows about one of them.

BEGIN;

CREATE TABLE IF NOT EXISTS trip_shares (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  departure_id UUID NOT NULL REFERENCES departures(id),
  operator_id  UUID NOT NULL REFERENCES operators(id),

  -- Never the token itself. See above.
  token_hash   TEXT NOT NULL UNIQUE,

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ,

  -- "3 personnes ont ouvert ce lien" on the traveller's own screen. Somebody
  -- who shares a journey wants to know it arrived; somebody who shared it
  -- with the wrong group wants to know that too, while there is still time to
  -- revoke it.
  opens          INTEGER NOT NULL DEFAULT 0,
  last_opened_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS trip_shares_one_live
  ON trip_shares (booking_id) WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS trip_shares_departure
  ON trip_shares (departure_id);

ALTER TABLE trip_shares ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_shares FORCE ROW LEVEL SECURITY;

-- The traveller's own links, through the public surface they already hold a
-- session on. Scoped by the booking's purchaser rather than by a column here,
-- so a share cannot outlive its booking's ownership.
DROP POLICY IF EXISTS trip_shares_own ON trip_shares;
CREATE POLICY trip_shares_own ON trip_shares
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.id = trip_shares.booking_id
         AND b.purchaser_user_id = app_user_id()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.id = trip_shares.booking_id
         AND b.purchaser_user_id = app_user_id()
    )
  );

-- The operator whose coach it is may see that a departure is being followed.
-- Read only, and no token: knowing thirty people are watching the 06:00 is
-- operationally useful and knowing who they are is not theirs.
DROP POLICY IF EXISTS trip_shares_operator ON trip_shares;
CREATE POLICY trip_shares_operator ON trip_shares
  FOR SELECT USING (app_is_platform() OR operator_id = app_tenant_id());

-- Only the traveller writes one, through the public surface they already hold
-- a session on. **Platform staff cannot create a share** — a support agent
-- handing somebody a link to a stranger's journey is not a power this needs to
-- have, and the absence is a grant rather than a promise.
GRANT SELECT, INSERT, UPDATE ON trip_shares TO bel_public;
GRANT SELECT ON trip_shares TO bel_app, bel_admin;

-- ── What a follower is allowed to know ──────────────────────────────────────
--
-- Volatile rather than stable: it counts the open. One call does the read and
-- the tally, so a page that loads is a page that was counted, and a poll every
-- 60 s does not need a second round trip to say so.
CREATE OR REPLACE FUNCTION followed_trip(p_token_hash TEXT)
RETURNS TABLE (
  operator_name    TEXT,
  operator_code    TEXT,
  route_code       TEXT,
  origin_city      TEXT,
  destination_city TEXT,
  departs_at       TIMESTAMPTZ,
  arrives_at       TIMESTAMPTZ,
  status           TEXT,
  expires_at       TIMESTAMPTZ,
  revoked          BOOLEAN,
  disruption_kind  TEXT,
  disruption_cause TEXT,
  disruption_note  TEXT,
  revised_departs_at TIMESTAMPTZ
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  -- The tally first, and only for a link that is actually live: a revoked or
  -- expired link being polled by a page somebody left open must not keep
  -- inflating the number the traveller reads.
  UPDATE trip_shares s
     SET opens = s.opens + 1, last_opened_at = now()
   WHERE s.token_hash = p_token_hash
     AND s.revoked_at IS NULL
     AND s.expires_at > now();

  RETURN QUERY
  SELECT COALESCE(o.trading_name, o.legal_name),
         o.code,
         rt.code,
         co.name_fr,
         cd.name_fr,
         d.departs_at,
         d.arrives_at,
         d.status::text,
         s.expires_at,
         s.revoked_at IS NOT NULL,
         dis.kind::text,
         dis.cause::text,
         dis.note,
         dis.revised_departs_at
    FROM trip_shares s
    JOIN departures d  ON d.id = s.departure_id
    JOIN routes rt     ON rt.id = d.route_id
    JOIN cities co     ON co.code = rt.origin_city
    JOIN cities cd     ON cd.code = rt.destination_city
    JOIN operators o   ON o.id = s.operator_id
    LEFT JOIN disruptions dis
           ON dis.departure_id = s.departure_id
          AND dis.resolved_at IS NULL
   WHERE s.token_hash = p_token_hash;
END;
$$;

REVOKE ALL ON FUNCTION followed_trip(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION followed_trip(TEXT) TO bel_public, bel_app, bel_admin;

COMMIT;
