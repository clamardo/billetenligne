-- 0039_ticket_link_boarding_point — the yard, on the link (ADR-0026).
--
-- 0038 answered the journey and forgot the address. A passenger holding a
-- link knows the coach leaves Brazzaville at 06:00 and not which of the
-- company's three yards to stand in at half past five, which is the fact an
-- agency's telephone line repeats more than any other (`06-fleet-and-routes`).
--
-- So two columns, and they are added by DROP and CREATE rather than by
-- CREATE OR REPLACE — Postgres refuses to change a function's return type in
-- place, and that refusal is the point ADR-0026 makes about this function:
-- what the holder of a link may know is a decision taken here, not a line
-- somebody edits in a handler.
--
-- The yard is **the one they board at**, which on a priced leg is the stop's
-- own station and not the terminal the coach left from (ADR-0025). A stop
-- with no station named answers nothing at all, because a ticket that says
-- "Gare routière" sends somebody to a gate nobody at that company has heard
-- of.

BEGIN;

DROP FUNCTION IF EXISTS ticket_by_link(TEXT);

CREATE FUNCTION ticket_by_link(p_token_hash TEXT)
RETURNS TABLE (
  booking_ref      TEXT,
  booking_state    TEXT,
  operator_name    TEXT,
  operator_code    TEXT,
  route_code       TEXT,
  origin_city      TEXT,
  destination_city TEXT,
  departs_at       TIMESTAMPTZ,
  arrives_at       TIMESTAMPTZ,
  status           TEXT,
  station_name     TEXT,
  station_notes    TEXT,
  seat_label       TEXT,
  passenger_name   TEXT,
  payload          TEXT,
  voided           BOOLEAN,
  channel          TEXT,
  expires_at       TIMESTAMPTZ,
  revoked          BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  -- The tally first, and only for a link that is live: a page somebody left
  -- open on a dead link must not keep counting.
  UPDATE ticket_links l
     SET opens = l.opens + 1, last_opened_at = now()
   WHERE l.token_hash = p_token_hash
     AND l.revoked_at IS NULL
     AND l.expires_at > now();

  RETURN QUERY
  WITH road AS (
    SELECT r.id AS route_id, 0 AS position, r.origin_city AS city
      FROM routes r
     UNION ALL
    SELECT rs.route_id, rs.sequence, rs.city_code FROM route_stops rs
     UNION ALL
    SELECT r.id,
           1 + (SELECT count(*)::int FROM route_stops x
                 WHERE x.route_id = r.id),
           r.destination_city
      FROM routes r
  )
  SELECT b.ref,
         b.state::text,
         COALESCE(o.trading_name, o.legal_name),
         o.code,
         rt.code,
         COALESCE(cf.name_fr, co.name_fr),
         COALESCE(ct.name_fr, cd.name_fr),
         d.departs_at + make_interval(mins => COALESCE(fs.offset_minutes, 0)),
         CASE WHEN ts.position IS NULL THEN d.arrives_at
              ELSE d.departs_at + make_interval(mins => ts.offset_minutes) END,
         d.status::text,
         os.name,
         os.boarding_notes,
         t.seat_label,
         bs.passenger_name,
         t.payload,
         t.voided_at IS NOT NULL,
         l.channel,
         l.expires_at,
         l.revoked_at IS NOT NULL
    FROM ticket_links l
    JOIN bookings b   ON b.id = l.booking_id
    JOIN departures d ON d.id = b.departure_id
    JOIN routes rt    ON rt.id = d.route_id
    JOIN operators o  ON o.id = b.operator_id
    JOIN cities co    ON co.code = rt.origin_city
    JOIN cities cd    ON cd.code = rt.destination_city
    LEFT JOIN tickets t ON t.booking_id = b.id
    LEFT JOIN booking_seats bs
           ON bs.booking_id = b.id AND bs.seat_label = t.seat_label
    LEFT JOIN LATERAL (
      SELECT rd.position, rd.city,
             COALESCE((SELECT rs.offset_minutes FROM route_stops rs
                        WHERE rs.route_id = d.route_id
                          AND rs.sequence = rd.position), 0) AS offset_minutes
        FROM road rd
       WHERE rd.route_id = d.route_id
         AND rd.position = lower(b.road_span)
    ) fs ON TRUE
    LEFT JOIN LATERAL (
      SELECT rd.position, rd.city,
             (SELECT rs.offset_minutes FROM route_stops rs
               WHERE rs.route_id = d.route_id
                 AND rs.sequence = rd.position) AS offset_minutes
        FROM road rd
       WHERE rd.route_id = d.route_id
         AND rd.position = upper(b.road_span)
         AND rd.position < 1 + (SELECT count(*)::int FROM route_stops x
                                 WHERE x.route_id = d.route_id)
    ) ts ON TRUE
    -- Position 0 is the departure's own terminal; anything else is the stop's,
    -- and a stop that names none says none.
    LEFT JOIN stations os
           ON os.id = CASE WHEN COALESCE(fs.position, 0) = 0
                           THEN d.origin_station_id
                           ELSE (SELECT rs.station_id FROM route_stops rs
                                  WHERE rs.route_id = d.route_id
                                    AND rs.sequence = fs.position) END
    LEFT JOIN cities cf ON cf.code = fs.city
    LEFT JOIN cities ct ON ct.code = ts.city
   WHERE l.token_hash = p_token_hash
   ORDER BY t.seat_label;
END;
$$;

REVOKE ALL ON FUNCTION ticket_by_link(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ticket_by_link(TEXT) TO bel_public, bel_app, bel_admin;

COMMIT;
