-- 0038_ticket_links — the ticket you can always get to (ADR-0026).
--
-- A ticket is worth what the person holding it can reach at the coach door.
-- The walk-in at an agency counter can reach nothing: the guichet creates them
-- an unverified account from the number the vendor types, SMS is off in this
-- market until a sender number exists, and the confirmation email tells
-- somebody with no app that their ticket is in the app.
--
-- So a link. The shape is `trip_shares` (0023), because that table already
-- proves the three things this one needs:
--
--   * **The token is stored as a hash.** The plaintext exists once, in the
--     response that mints it. A dump, a replica, a backup on a laptop — none
--     of them is a set of working links into people's tickets.
--   * **The reader goes through a SECURITY DEFINER function**, never a policy.
--     A SELECT policy here would be all-columns and row-enumerable, which
--     would let `bel_public` walk every live link in the country. The function
--     takes a hash, returns the facts ADR-0026 lists, and answers nothing at
--     all for a token it does not hold.
--   * **What the holder may see is decided in SQL.** Putting the column list
--     in a handler makes it a line somebody edits; putting it in the
--     function's return type makes adding one a decision.
--
-- Two things differ from a share, and both come from what this link is for:
--
--   * **It lives until the coach has gone**, plus a day. A share dies six
--     hours after arrival because watching a finished journey is pointless; a
--     boarding pass has to survive a coach that left four hours late.
--   * **It remembers where it was sent.** Not for display — for the step-up:
--     the one-time code that unlocks changing a booking goes to the address on
--     the link, never to one the caller supplies, or the endpoint is an open
--     relay with our domain on it.

BEGIN;

CREATE TABLE IF NOT EXISTS ticket_links (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  operator_id  UUID NOT NULL REFERENCES operators(id),

  -- Never the token itself. See above.
  token_hash   TEXT NOT NULL UNIQUE,

  -- How it was sent, and to what. `sent_to` is the address as it was at mint
  -- time: a traveller who later changes their email must not find that an old
  -- link now sends codes somewhere new.
  channel      TEXT NOT NULL,
  sent_to      TEXT NOT NULL,

  CONSTRAINT ticket_links_channel_known CHECK (channel IN ('email', 'phone')),

  -- The vendor who sold it, or null when the traveller minted their own.
  created_by   UUID REFERENCES user_accounts(id),

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ,

  opens          INTEGER NOT NULL DEFAULT 0,
  last_opened_at TIMESTAMPTZ
);

-- One live link per channel per booking. Re-sending revokes and re-mints
-- rather than accumulating: two live links are two things to revoke and the
-- traveller was only ever told about one of them.
CREATE UNIQUE INDEX IF NOT EXISTS ticket_links_one_live
  ON ticket_links (booking_id, channel) WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS ticket_links_booking ON ticket_links (booking_id);

ALTER TABLE ticket_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_links FORCE ROW LEVEL SECURITY;

-- The operator whose coach it is. A vendor mints a link for a booking their
-- own company sold, and for no other — the same tenancy rule as everything
-- else on the console surface, enforced where every other one is.
DROP POLICY IF EXISTS ticket_links_tenant ON ticket_links;
CREATE POLICY ticket_links_tenant ON ticket_links
  FOR ALL
  USING (app_is_platform() OR operator_id = app_tenant_id())
  WITH CHECK (app_is_platform() OR operator_id = app_tenant_id());

-- The traveller whose booking it is, so they can re-send it to themselves and
-- kill one they should not have sent.
DROP POLICY IF EXISTS ticket_links_own ON ticket_links;
CREATE POLICY ticket_links_own ON ticket_links
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.id = ticket_links.booking_id
         AND b.purchaser_user_id = app_user_id()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.id = ticket_links.booking_id
         AND b.purchaser_user_id = app_user_id()
    )
  );

GRANT SELECT, INSERT, UPDATE ON ticket_links TO bel_public;
GRANT SELECT, INSERT, UPDATE ON ticket_links TO bel_app, bel_admin;

-- ── What the holder of a link is allowed to know ────────────────────────────
--
-- One row per seat, with the journey repeated on each — because a ticket is a
-- seat, a booking can be three of them, and the header is the same for all
-- three. Volatile: it counts the open in the same call, so a page that loaded
-- is a page that was counted.
--
-- The road is numbered the way every other reader numbers it (ADR-0025), so a
-- passenger who bought Dolisie→Pointe-Noire is shown Dolisie, at the hour the
-- coach reaches Dolisie, and not the terminus the coach happens to run to.
CREATE OR REPLACE FUNCTION ticket_by_link(p_token_hash TEXT)
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
      SELECT rd.city,
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
    LEFT JOIN cities cf ON cf.code = fs.city
    LEFT JOIN cities ct ON ct.code = ts.city
   WHERE l.token_hash = p_token_hash
   ORDER BY t.seat_label;
END;
$$;

REVOKE ALL ON FUNCTION ticket_by_link(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ticket_by_link(TEXT) TO bel_public, bel_app, bel_admin;

COMMIT;
