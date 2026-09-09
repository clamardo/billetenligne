-- 0052_suspension_honours_tickets — the rule in `03-operator-lifecycle.md` §1,
-- executed rather than written down (`18-…-can-join.md` J13).
--
-- > **`suspended` and `offboarding` both stop new sales but honour issued
-- > tickets.** A platform that strands paying passengers to punish an
-- > operator has punished the wrong party.
--
-- It has been true in the catalogue query since the catalogue existed —
-- `JOIN operators o` under `operators_public_read`, which is scoped to
-- `status = 'active'`, so a suspended company's coaches fall out of search on
-- their own. That is an implementation detail of one query. Every other
-- public read of `departures` went through `departures_public_read`, which
-- said `app_is_public()` and nothing else: a deep link to a departure id, a
-- seat map, a hold. Stopping sales rested on a join somebody could remove.
--
-- Both halves of the rule now live in one policy, and the reason it has to be
-- one policy is that **no implementation that simply hides the operator's
-- rows can satisfy both**:
--
--   * a coach from a company that is not `active` is invisible to the public
--     surface — no search row, no seat map, no hold, no deep link;
--   * unless the caller already holds a booking on it, in which case it stays
--     readable however long the suspension lasts. That is the arm that
--     honours the ticket, and it is the same intent 0005 already had for a
--     cancelled departure: *a traveller holding a ticket for it must be able
--     to see what happened to their coach*.
--
-- A door scan is not affected and never was: boarding reads the manifest
-- under the operator's own tenant scope, and the signature check on the
-- handset happens with no database at all (ADR-0007). Suspending a company
-- takes their coaches off sale; it cannot take a passenger off one.

BEGIN;

DROP POLICY IF EXISTS departures_public_read ON departures;

CREATE POLICY departures_public_read ON departures
  FOR SELECT USING (
    app_is_public() AND (
      EXISTS (
        SELECT 1 FROM operators o
         WHERE o.id = departures.operator_id
           AND o.status = 'active'
      )
      -- The passenger's arm. `app_user_id()` is NULL for somebody browsing
      -- without an account, which makes this false rather than an error —
      -- and browsing needs no account (ADR-0013), so the first arm is what
      -- serves them.
      OR EXISTS (
        SELECT 1 FROM bookings b
         WHERE b.departure_id = departures.id
           AND b.purchaser_user_id = app_user_id()
      )
    )
  );

COMMIT;
