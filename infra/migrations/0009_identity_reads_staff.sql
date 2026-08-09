-- 0009_identity_reads_staff — the identity surface learns about staff.
--
-- 0007 gave `bel_identity` exactly two tables and asserted, in
-- verify_identity.sql, that it could not reach `operator_staff`. That
-- assertion was written under a narrower reading of what the role does, and
-- the console surface proved it wrong the first time somebody signed in as a
-- vendor: resolving a bearer token now has to answer "who is this **and what
-- are they**", and which operator somebody works for is part of the answer,
-- not a separate privilege.
--
-- It is worth being precise about why this is not a widening of the blast
-- radius. The rule 0007 was protecting is that a role which can answer
-- "who is this?" must not also be able to take money. That still holds
-- exactly: `bel_identity` gains SELECT and nothing else, on two tables that
-- carry no money and no inventory. It cannot grant anybody a role, revoke
-- one, or sell a seat — the verification below asserts each of those.
--
-- The alternative was to put the staff lookup in the console's own scope. It
-- does not work: the lookup happens BEFORE the request has a surface, because
-- its result is what decides which surface the request gets.

BEGIN;

GRANT SELECT ON operator_staff TO bel_identity;

-- And `operators`, because a membership of a suspended or offboarded operator
-- must not resolve to a working console session. Checked in the same query
-- rather than by a second round trip on the hot path of every authenticated
-- request.
GRANT SELECT ON operators TO bel_identity;

-- Stated as an explicit REVOKE rather than left as an omission, so the intent
-- is greppable: reading a role is identity, writing one is administration,
-- and they are not the same surface.
REVOKE INSERT, UPDATE, DELETE ON operator_staff FROM bel_identity;
REVOKE INSERT, UPDATE, DELETE ON operators FROM bel_identity;

CREATE POLICY operator_staff_identity_read ON operator_staff
  FOR SELECT USING (app_is_identity());

COMMIT;
