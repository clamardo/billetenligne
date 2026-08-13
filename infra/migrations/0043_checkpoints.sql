-- 0043_checkpoints — the conductor confirms passage (ADR-0014 §1, tier 2).
--
-- The follower page has drawn a dashed bar since it shipped, and said so in
-- as many words: *estimation d'après l'horaire*. It draws a dashed bar
-- because nothing has ever been able to tell it otherwise — the three tiers
-- of ADR-0014 are written and tested in the domain, the page already renders
-- all three, and the only missing piece was somewhere for an observation to
-- come from.
--
-- It comes from the handset that is already on the coach. The conductor
-- pinned this departure in the yard to board it; confirming that the coach
-- has passed Dolisie is one more tap on a device that is already bound to
-- this run and already trusted to say who boarded it. No GPS permission, no
-- background location, no driver-facing app that does not exist.
--
-- Four decisions worth the ink:
--
--   * **A waypoint is a route stop, not a coordinate.** Dolisie, Nkayi,
--     Madingou — places with names, in the order the road runs them, already
--     in `route_stops` with the minutes into the run. That gives the fraction
--     the bar needs without anybody typing a number, and it means the page
--     can say *passé Dolisie* rather than *passé 4.31°S*.
--   * **Two clocks, both kept.** `passed_at` is the conductor's device, which
--     is the one that was there. `recorded_at` is ours, which is when we
--     heard. A checkpoint tapped in a dead zone and uploaded ninety minutes
--     later is still true about when it happened, and a page that showed our
--     clock would report the coach ninety minutes behind where it is.
--   * **Append-only.** There is no UPDATE grant and no DELETE grant. A claim
--     that a coach was somewhere at a time is not something anybody gets to
--     revise afterwards — including code written next year by somebody who
--     never read this file.
--   * **The follower reads it through `followed_trip`, not a policy.** Same
--     reasoning as 0023: a SELECT policy for `bel_public` would be
--     row-enumerable across every operator's movements. The definer function
--     returns the one checkpoint that matters and nothing else.
--
-- First tap wins, by primary key, exactly like a redemption: a conductor who
-- double-taps means the same thing twice, and the time a dispute is settled
-- with is the one already in the row.

BEGIN;

CREATE TABLE IF NOT EXISTS departure_checkpoints (
  departure_id  UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  route_stop_id UUID NOT NULL REFERENCES route_stops(id) ON DELETE CASCADE,
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  -- The device's clock, at the roadside. See decision 2.
  passed_at     TIMESTAMPTZ NOT NULL,
  -- Ours, when the outbox reached us.
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  reported_by   UUID REFERENCES user_accounts(id),
  device_id     TEXT,

  PRIMARY KEY (departure_id, route_stop_id)
);

-- The follower's read: the furthest confirmed waypoint on this run. Ordered
-- by the road rather than by the clock, because how far along a coach is is a
-- fact about the road — a conductor confirming Nkayi after Dolisie because
-- they forgot the first tap must not move the bar backwards.
CREATE INDEX IF NOT EXISTS departure_checkpoints_departure_idx
  ON departure_checkpoints (departure_id);

ALTER TABLE departure_checkpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE departure_checkpoints FORCE ROW LEVEL SECURITY;

-- The shape 0004 gives every tenant table.
CREATE POLICY departure_checkpoints_tenant_isolation ON departure_checkpoints
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

GRANT SELECT, INSERT ON departure_checkpoints TO bel_app, bel_admin;

-- Decision 3, as a privilege rather than a promise.
REVOKE UPDATE, DELETE ON departure_checkpoints FROM bel_app, bel_admin;

-- ── What a follower is allowed to know, revisited ───────────────────────────
--
-- Dropped and recreated rather than replaced: the return type gains four
-- columns, and `CREATE OR REPLACE` cannot change one. The grants below are
-- re-issued for the same reason — a dropped function takes its grants with
-- it, and a follower page answering 500 because nobody re-granted EXECUTE is
-- the kind of outage that only shows up in production.
DROP FUNCTION IF EXISTS followed_trip(TEXT);

CREATE FUNCTION followed_trip(p_token_hash TEXT)
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
  revised_departs_at TIMESTAMPTZ,
  -- Tier 2. All four are NULL when nobody has confirmed anything, which is
  -- what puts the page back on the dashed bar it has drawn until now.
  checkpoint_name           TEXT,
  checkpoint_offset_minutes INTEGER,
  checkpoint_passed_at      TIMESTAMPTZ,
  route_duration_minutes    INTEGER
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
         dis.revised_departs_at,
         cp.name,
         cp.offset_minutes,
         cp.passed_at,
         rt.duration_minutes
    FROM trip_shares s
    JOIN departures d  ON d.id = s.departure_id
    JOIN routes rt     ON rt.id = d.route_id
    JOIN cities co     ON co.code = rt.origin_city
    JOIN cities cd     ON cd.code = rt.destination_city
    JOIN operators o   ON o.id = s.operator_id
    LEFT JOIN disruptions dis
           ON dis.departure_id = s.departure_id
          AND dis.resolved_at IS NULL
    -- The furthest one down the road, and the name a person would use for it:
    -- the station if the stop names one, the city otherwise. A follower who
    -- reads "passé Dolisie" knows where that is; "passé stop 3" tells them
    -- nothing they could act on.
    LEFT JOIN LATERAL (
      SELECT COALESCE(st.name, ci.name_fr) AS name,
             rs.offset_minutes,
             c.passed_at
        FROM departure_checkpoints c
        JOIN route_stops rs ON rs.id = c.route_stop_id
        JOIN cities ci      ON ci.code = rs.city_code
        LEFT JOIN stations st ON st.id = rs.station_id
       WHERE c.departure_id = s.departure_id
       ORDER BY rs.offset_minutes DESC
       LIMIT 1
    ) cp ON TRUE
   WHERE s.token_hash = p_token_hash;
END;
$$;

REVOKE ALL ON FUNCTION followed_trip(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION followed_trip(TEXT) TO bel_public, bel_app, bel_admin;

COMMIT;
