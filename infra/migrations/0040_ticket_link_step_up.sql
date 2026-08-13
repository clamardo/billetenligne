-- 0040_ticket_link_step_up — seeing is not changing (ADR-0026).
--
-- The token is the credential for **seeing** a ticket, and deliberately for
-- nothing else. Changing a seat or moving money takes a one-time code, and the
-- code goes to the address the link was delivered to — never to one the caller
-- supplies, or the endpoint is an open relay with our domain on it.
--
-- Two functions, and both are SECURITY DEFINER for the same reason the reader
-- is: an anonymous holder has no policy on `ticket_links` and must not get
-- one, because a policy here is row-enumerable and that is a list of every
-- live ticket in the country.
--
--   * `ticket_link_destination` answers where a code may be sent, and nothing
--     else. It does **not** count an open — asking for a code is not reading
--     a ticket, and a tally that moved on it would make the open count a lie.
--   * `claim_by_link` re-points a booking at the account that just proved it
--     holds the address.
--
-- The claim is what turns a counter sale into somebody's account, and it has
-- one rule that matters: **a booking already held by a verified account is
-- never re-pointed.** The guichet creates an unverified account from the
-- number a vendor typed; that is the account this is for. An account somebody
-- has actually signed in to is a person, and a link is not enough to take
-- their booking away from them.

BEGIN;

CREATE OR REPLACE FUNCTION ticket_link_destination(p_token_hash TEXT)
RETURNS TABLE (
  booking_id UUID,
  channel    TEXT,
  sent_to    TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT l.booking_id, l.channel, l.sent_to
    FROM ticket_links l
   WHERE l.token_hash = p_token_hash
     AND l.revoked_at IS NULL
     AND l.expires_at > now();
$$;

CREATE OR REPLACE FUNCTION claim_by_link(p_token_hash TEXT, p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  claimed TEXT;
BEGIN
  UPDATE bookings b
     SET purchaser_user_id = p_user_id
   WHERE b.id = (SELECT l.booking_id FROM ticket_links l
                  WHERE l.token_hash = p_token_hash
                    AND l.revoked_at IS NULL
                    AND l.expires_at > now())
     AND (
       -- Already theirs: idempotent, so a second tap answers the same thing.
       b.purchaser_user_id = p_user_id
       -- Or held by an account nobody has ever proved they hold.
       OR EXISTS (
         SELECT 1 FROM user_accounts u
          WHERE u.id = b.purchaser_user_id
            AND u.email_verified_at IS NULL
            AND u.phone_verified_at IS NULL
       )
       OR b.purchaser_user_id IS NULL
     )
   RETURNING b.ref INTO claimed;

  RETURN claimed;
END;
$$;

REVOKE ALL ON FUNCTION ticket_link_destination(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION claim_by_link(TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ticket_link_destination(TEXT)
  TO bel_public, bel_app, bel_admin;
GRANT EXECUTE ON FUNCTION claim_by_link(TEXT, UUID)
  TO bel_public, bel_app, bel_admin;

COMMIT;
