-- Stations become real: where a coach actually leaves from.
--
-- The table has existed since 0001 and nothing has ever read it. A traveller
-- sees "Brazzaville → Pointe-Noire" and is told nothing about which of an
-- operator's three yards to stand in at half past five in the morning — which
-- is exactly the information an agency spends its telephone line repeating.
--
-- It matters more than tidiness. A passenger who missed the 06:00 can often
-- be put on the 09:30, and in a city with two terminals the 09:30 leaves from
-- the other one. Being unable to say *which* makes that transfer untellable,
-- so this is the migration the missed-departure work stands on.
--
-- Three decisions are recorded here:
--
--   1. **A station belongs to exactly one operator.** `operator_id` was
--      nullable, apparently for a shared gare routière — but the tenant
--      policy from 0004 reads `operator_id = app_tenant_id()`, which is NULL
--      and therefore false for such a row: a shared station was invisible to
--      every operator including the ones sharing it. A shared yard is
--      modelled as one row per company, which is also how the desks, the
--      staff scoping and the tills already work.
--
--   2. **A departure cannot board at a rival's terminal, by constraint.** The
--      composite foreign key onto `(id, operator_id)` says it declaratively,
--      rather than leaving it to a WHERE clause somebody forgets.
--
--   3. **Stations are captured on the departure, not read through the
--      pattern.** Same reason the seat layout is: renaming or retiring a
--      terminal next month must not rewrite where a coach that is already
--      sold was said to leave from.
BEGIN;

-- 1 ── A station belongs to one operator, and is unique within its city.
DELETE FROM stations WHERE operator_id IS NULL;

ALTER TABLE stations
  ALTER COLUMN operator_id SET NOT NULL,
  ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT TRUE,
  ADD CONSTRAINT stations_id_belongs_to_operator UNIQUE (id, operator_id),
  ADD CONSTRAINT stations_named_once_per_city UNIQUE (operator_id, city_code, name);

-- A terminal that closes is deactivated, never deleted: tickets sold last
-- week still say where their passengers were told to stand.
CREATE INDEX IF NOT EXISTS stations_operator_city_idx
  ON stations (operator_id, city_code) WHERE active;

-- 2 ── Where a scheduled service leaves from and arrives at.
ALTER TABLE departure_patterns
  ADD COLUMN IF NOT EXISTS origin_station_id UUID,
  ADD COLUMN IF NOT EXISTS destination_station_id UUID,
  ADD CONSTRAINT departure_patterns_origin_station_is_ours
    FOREIGN KEY (origin_station_id, operator_id)
    REFERENCES stations (id, operator_id),
  ADD CONSTRAINT departure_patterns_destination_station_is_ours
    FOREIGN KEY (destination_station_id, operator_id)
    REFERENCES stations (id, operator_id);

ALTER TABLE departures
  ADD COLUMN IF NOT EXISTS origin_station_id UUID,
  ADD COLUMN IF NOT EXISTS destination_station_id UUID,
  ADD CONSTRAINT departures_origin_station_is_ours
    FOREIGN KEY (origin_station_id, operator_id)
    REFERENCES stations (id, operator_id),
  ADD CONSTRAINT departures_destination_station_is_ours
    FOREIGN KEY (destination_station_id, operator_id)
    REFERENCES stations (id, operator_id);

-- 3 ── A traveller reads the terminal they are being sent to.
--
-- The read itself was opened in 0008, for the counter that sold a cash
-- ticket. It is narrowed here rather than widened: a terminal nobody boards
-- at any more is a wrong direction to a stranger, not history, and the
-- operator's own console still sees it through the tenant policy — which is
-- how last month's departures keep saying where they left from.
DROP POLICY stations_public_read ON stations;

CREATE POLICY stations_public_read ON stations
  FOR SELECT USING (app_is_public() AND active);

COMMIT;
