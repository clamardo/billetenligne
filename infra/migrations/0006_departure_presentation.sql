-- 0006_departure_presentation — what the traveller is allowed to know about
-- the coach.
--
-- Written because the grant list in 0005 refused a query, which is the grant
-- list working. The search screen needs two facts about the vehicle: whether
-- it is a bus or an aircraft (so the client picks a silhouette), and what
-- amenities it has (wifi, USB, air conditioning). Those are the things a
-- traveller is choosing between.
--
-- The `vehicles` table carries considerably more: the registration plate, the
-- compliance status, the maintenance state. `status = 'blocked_compliance'`
-- is commercially sensitive — an operator would not thank us for publishing
-- which of their coaches is off the road — so granting the public role SELECT
-- on the whole table to reach two columns is the wrong trade.
--
-- Instead the two facts are captured onto the departure, which is exactly the
-- pattern `seat_layout_id` already follows: a departure keeps what it was sold
-- with, and editing the fleet tomorrow does not rewrite a coach that already
-- has bookings. It also removes a join from the hottest read in the product.

BEGIN;

ALTER TABLE departures
  ADD COLUMN mode      TEXT NOT NULL DEFAULT 'bus',
  ADD COLUMN amenities TEXT[] NOT NULL DEFAULT '{}';

ALTER TABLE departures
  ADD CONSTRAINT departures_mode_known CHECK (mode IN ('bus', 'air'));

-- Existing rows take their vehicle's values. Departures with no vehicle
-- assigned yet keep the defaults, which is correct: an unassigned coach is a
-- bus with no advertised amenities until somebody says otherwise.
UPDATE departures d
   SET mode      = v.mode,
       amenities = v.amenities
  FROM vehicles v
 WHERE v.id = d.vehicle_id;

COMMENT ON COLUMN departures.mode IS
  'Captured from the vehicle at materialisation. Public — the client picks a '
  'silhouette from it. Reassigning the fleet does not rewrite a sold departure.';

COMMENT ON COLUMN departures.amenities IS
  'Captured from the vehicle at materialisation. Public. Deliberately NOT a '
  'join to vehicles: that table also carries registration and compliance '
  'status, which are the operator''s business and nobody else''s.';

COMMIT;
