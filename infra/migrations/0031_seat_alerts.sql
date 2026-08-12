-- 0031_seat_alerts — tell me if a seat comes free.
--
-- The 06:00 to Pointe-Noire sells out. A traveller looking at `complet` today
-- has exactly one move: come back and look again, which most people do once
-- and then buy from somebody else. Meanwhile seats *do* come free on that
-- coach all day — a hold lapses, a reservation goes unpaid, somebody cancels
-- — and nobody who wanted one is told.
--
-- **A row of intent, not a reservation.** An alert holds nothing and promises
-- nothing: it says who would like to know, and the first person to pay still
-- gets the seat. Anything stronger would be a queue, and a queue over
-- inventory that is also on sale to everybody else is a promise the system
-- cannot keep at a coach door.
--
-- **One live alert per traveller per departure**, by partial unique index.
-- Somebody who taps twice on a bad connection has asked once, and a table
-- that let them ask five times would send five messages.
--
-- **It fires once and is done.** `notified_at` is the whole state machine:
-- there is no re-arming, because a seat that came free and went again is not
-- news worth a second SMS. Somebody who missed it can ask again.
BEGIN;

CREATE TABLE seat_alerts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  departure_id UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,

  -- How many they need. A family of four is not helped by being told about
  -- one seat, and telling them anyway is how an alert becomes noise people
  -- switch off.
  seats_wanted INTEGER NOT NULL DEFAULT 1,

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- When the message was queued. Set once, and the row is spent.
  notified_at  TIMESTAMPTZ,

  -- When the traveller withdrew. Kept rather than deleted: "I asked and was
  -- never told" is a support conversation, and a deleted row cannot answer
  -- it.
  cancelled_at TIMESTAMPTZ,

  CONSTRAINT seat_alerts_seats_sane CHECK (seats_wanted BETWEEN 1 AND 6),
  -- Both at once is a row that means two things. A withdrawn alert was not
  -- also sent, and a sent one was not also withdrawn.
  CONSTRAINT seat_alerts_one_ending
    CHECK (notified_at IS NULL OR cancelled_at IS NULL)
);

-- One live alert per traveller per departure. A double tap on a bad
-- connection is one request, not two messages.
CREATE UNIQUE INDEX seat_alerts_one_live
  ON seat_alerts (departure_id, user_id)
  WHERE notified_at IS NULL AND cancelled_at IS NULL;

-- The worker's queue: every departure somebody is waiting on. Keyed on the
-- departure because the pass asks "which of these has room now?" once per
-- coach rather than once per waiting traveller.
CREATE INDEX seat_alerts_waiting_idx
  ON seat_alerts (departure_id)
  WHERE notified_at IS NULL AND cancelled_at IS NULL;

ALTER TABLE seat_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE seat_alerts FORCE ROW LEVEL SECURITY;

-- A traveller's own alerts, and nobody else's. Deliberately not visible to
-- the operator: who is waiting for a seat on the 06:00 is a list of people
-- who want to travel, and an operator holding it is an operator who can be
-- asked to sell it.
CREATE POLICY seat_alerts_own ON seat_alerts
  FOR SELECT USING (app_is_public() AND user_id = app_user_id());

CREATE POLICY seat_alerts_ask ON seat_alerts
  FOR INSERT WITH CHECK (app_is_public() AND user_id = app_user_id());

-- Withdrawing is an update, not a delete: see `cancelled_at` above.
CREATE POLICY seat_alerts_withdraw ON seat_alerts
  FOR UPDATE USING (app_is_public() AND user_id = app_user_id())
  WITH CHECK (app_is_public() AND user_id = app_user_id());

-- The pass that actually notices a free seat, and the support view.
CREATE POLICY seat_alerts_platform ON seat_alerts
  FOR ALL USING (app_is_platform()) WITH CHECK (app_is_platform());

GRANT SELECT, INSERT, UPDATE ON seat_alerts TO bel_public;
GRANT SELECT, INSERT, UPDATE ON seat_alerts TO bel_admin;

COMMIT;
