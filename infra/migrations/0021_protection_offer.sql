-- 0021_protection_offer — asking about a coach that is not yours.
--
-- A dispatcher choosing option ③ has to name the other company's departure:
-- the 12:00 with room on it. `departures` is tenant-isolated (0004), so their
-- own connection cannot read that row — and widening the table is not the
-- answer, because a SELECT policy is all-columns and a competitor's fare
-- history and vehicle assignment are not theirs to browse.
--
-- So the privilege moves into a function, the same way naming a counterparty
-- does in 0019. It returns the five facts a rescue needs — whose coach it is,
-- which road, when it leaves, whether it is on sale, and how many seats are
-- free — and every one of them is already visible to any anonymous traveller
-- searching that route in the app. A caller learns nothing they could not
-- learn by opening the app; what they are spared is having to.

BEGIN;

CREATE OR REPLACE FUNCTION protection_offer(p_departure UUID)
RETURNS TABLE (
  operator_id      UUID,
  origin_city      TEXT,
  destination_city TEXT,
  departs_at       TIMESTAMPTZ,
  status           TEXT,
  seats_free       INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT d.operator_id,
         r.origin_city,
         r.destination_city,
         d.departs_at,
         d.status::text,
         (SELECT count(*)::int FROM seats s
           WHERE s.departure_id = d.id AND s.state = 'available')
    FROM departures d
    JOIN routes r ON r.id = d.route_id
   WHERE d.id = p_departure
$$;

REVOKE ALL ON FUNCTION protection_offer(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION protection_offer(UUID) TO bel_app, bel_admin;

COMMIT;
