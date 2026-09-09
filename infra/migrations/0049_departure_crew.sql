-- 0049_departure_crew — a departure has people on it (`18-…-can-join.md` J3).
--
-- A departure has been a row that inventory is sold against and nothing else.
-- It has no crew, no state after `scheduled`, and no way to say it has gone —
-- and four separate things the business has asked for are downstream of that
-- one absence. A driver dashboard has nothing to be a dashboard *of*. GPS has
-- nothing to attach to. "Close the departure when we leave" has nothing to
-- close. "Tell the passenger who has not arrived" has no moment at which
-- somebody is missing.
--
-- This is the first half: who is on it.
--
-- Four decisions worth the ink:
--
--   * **Driver and conductor are different jobs.** On an intercity coach here
--     the person driving and the person taking tickets at the door are
--     usually two people. `apps/scanner` is built for whoever holds the
--     operator-owned handset, and which of them that is decides who can mark
--     a passenger boarded and whose tap is evidence in a delay dispute. A
--     single `crew_member` role would have thrown that away on day one.
--
--   * **One person may hold both roles.** A three-coach company runs with the
--     driver taking the tickets, and a schema that forbade it would be a
--     schema the smallest operators cannot use. The key is the triple, not
--     the pair.
--
--   * **"Staff of this operator" is a foreign key, not a check in Dart.**
--     `operator_staff` already carries `UNIQUE (operator_id, user_id)`, so
--     the composite reference below makes assigning somebody else's employee
--     — or a traveller — impossible rather than merely refused. It is the
--     same instinct as the seat-occupancy EXCLUDE constraint: the database is
--     where a rule survives the next caller nobody has written yet.
--
--   * **A roster is editable; a boarding is not.** Unlike
--     `departure_checkpoints` next door, this table keeps its DELETE grant.
--     Somebody rostered onto the wrong coach is a mistake to fix, not a claim
--     about the world to preserve. What must not be revised is what happened
--     *at* the door, and that lives elsewhere.
--
-- `operator_staff.staff_ref` arrives with it, and is deliberately **not** a
-- credential. The request was "the driver signs in with their driver id and
-- their email"; half of that is right. ADR-0024 is email-first — a one-time
-- code to an inbox, plus TOTP for anybody who can move other people's money —
-- and a driver id is written on the roster, printed on the manifest and stuck
-- to the dashboard of the coach. Accepting it at a sign-in prompt would add a
-- secret to phish rather than a factor to hold. It exists so a station
-- manager can find the right person in a list of two hundred.

BEGIN;

-- The two jobs. An enum rather than free text for the same reason
-- `departure_status` is one: a typo must not silently create a third role
-- that no policy, no screen and no manifest knows about.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crew_role') THEN
    CREATE TYPE crew_role AS ENUM ('driver', 'conductor');
  END IF;
END
$$;

-- The operator's own identifier for a person. Short, human, on the roster.
ALTER TABLE operator_staff ADD COLUMN IF NOT EXISTS staff_ref TEXT;

-- Unique within one operator and only where present: most staff will never
-- have one, and a plain UNIQUE would let exactly one of them be null.
CREATE UNIQUE INDEX IF NOT EXISTS operator_staff_ref_unique
  ON operator_staff (operator_id, staff_ref)
  WHERE staff_ref IS NOT NULL;

CREATE TABLE IF NOT EXISTS departure_crew (
  departure_id UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  operator_id  UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES user_accounts(id) ON DELETE CASCADE,
  role         crew_role NOT NULL,

  assigned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  assigned_by  UUID REFERENCES user_accounts(id),

  -- Decision 2: the same person may drive and conduct.
  PRIMARY KEY (departure_id, user_id, role),

  -- Decision 3. Assigning a stranger, or another operator's employee, is not
  -- refused by a handler — it cannot be written.
  CONSTRAINT departure_crew_is_staff
    FOREIGN KEY (operator_id, user_id)
    REFERENCES operator_staff (operator_id, user_id)
    ON DELETE CASCADE
);

-- "Who is on this coach" — the manifest's read, and the dispatcher's.
CREATE INDEX IF NOT EXISTS departure_crew_departure_idx
  ON departure_crew (departure_id);

-- "Which coaches is this person on" — the roster's read, and the one a
-- revocation has to walk to clear somebody off tomorrow's runs.
CREATE INDEX IF NOT EXISTS departure_crew_person_idx
  ON departure_crew (operator_id, user_id);

ALTER TABLE departure_crew ENABLE ROW LEVEL SECURITY;
ALTER TABLE departure_crew FORCE ROW LEVEL SECURITY;

-- The shape 0004 gives every tenant table.
DROP POLICY IF EXISTS departure_crew_tenant_isolation ON departure_crew;
CREATE POLICY departure_crew_tenant_isolation ON departure_crew
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

GRANT SELECT, INSERT, DELETE ON departure_crew TO bel_app, bel_admin;

-- Never. A roster row is replaced, not edited — there is nothing on it to
-- change that is not part of its own key, and an UPDATE grant on a table
-- whose key is its whole content is a grant nobody can use correctly.
REVOKE UPDATE ON departure_crew FROM bel_app, bel_admin;

-- The public surface has no business knowing who is driving. A traveller sees
-- the operator and the coach; the crew is an employment record.
REVOKE ALL ON departure_crew FROM bel_public;

COMMIT;
