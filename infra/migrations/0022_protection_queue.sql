-- 0022_protection_queue — the two-tenant queue, read by both parties.
--
-- A protection request names two departures owned by two different companies,
-- and `departures`, `routes` and `seats` are all tenant-isolated (0004). So
-- the obvious query — join the request to both coaches — silently returns
-- nothing: whichever half belongs to the counterparty is filtered away by
-- RLS, and the row disappears from the join rather than arriving short of a
-- column. A dispatcher would see an empty queue and conclude nobody had asked.
--
-- Widening the tables is not the answer, for the reason 0021 gives: a SELECT
-- policy is all-columns, and a competitor's fare history is not theirs to
-- browse. So the privilege moves into a function again, and this one is
-- narrower than it looks:
--
--   * it takes **no operator argument** — the caller is `app_tenant_id()`, so
--     there is nothing to spoof by passing somebody else's id;
--   * it returns rows only where the caller is one of the two parties;
--   * the counterparty facts it adds — when the coach leaves, which road, how
--     many seats are free — are what §2.3 says a receiving operator needs to
--     answer, and every one of them is already visible to any traveller
--     searching that route in the app.
--
-- Platform callers see everything, which is what support answering "what
-- happened to this passenger" needs.

BEGIN;

CREATE OR REPLACE FUNCTION protection_queue()
RETURNS TABLE (
  id                     UUID,
  agreement_id           UUID,
  sending_operator_id    UUID,
  receiving_operator_id  UUID,
  from_departure_id      UUID,
  to_departure_id        UUID,
  seats_requested        INTEGER,
  state                  TEXT,
  note                   TEXT,
  requested_at           TIMESTAMPTZ,
  auto_accepted          BOOLEAN,
  seats_moved            INTEGER,
  decline_reason         TEXT,
  departs_at             TIMESTAMPTZ,
  replacement_departs_at TIMESTAMPTZ,
  route_code             TEXT,
  seats_free             INTEGER,
  replacement_fare_minor BIGINT,
  replacement_currency   TEXT,
  discount_bps           INTEGER,
  counterparty_id        UUID
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT q.id,
         q.agreement_id,
         q.sending_operator_id,
         q.receiving_operator_id,
         q.from_departure_id,
         q.to_departure_id,
         q.seats_requested,
         q.state::text,
         q.note,
         q.requested_at,
         q.auto_accepted,
         q.seats_moved,
         q.decline_reason,
         d.departs_at,
         rd.departs_at,
         rt.code,
         (SELECT count(*)::int FROM seats s
           WHERE s.departure_id = q.to_departure_id
             AND s.state = 'available'),
         rd.fare_minor,
         rd.currency,
         a.rebill_discount_bps,
         CASE WHEN q.sending_operator_id = app_tenant_id()
              THEN q.receiving_operator_id
              ELSE q.sending_operator_id END
    FROM protection_requests q
    JOIN protection_agreements a ON a.id = q.agreement_id
    JOIN departures d  ON d.id  = q.from_departure_id
    JOIN departures rd ON rd.id = q.to_departure_id
    JOIN routes rt     ON rt.id = rd.route_id
   WHERE app_is_platform()
      OR q.sending_operator_id = app_tenant_id()
      OR q.receiving_operator_id = app_tenant_id()
   ORDER BY q.requested_at DESC
$$;

REVOKE ALL ON FUNCTION protection_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION protection_queue() TO bel_app, bel_admin;

COMMIT;
