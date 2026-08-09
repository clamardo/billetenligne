-- 0010_worker_grants — what the sweeper is allowed to tidy.
--
-- 0007 wrote, in a comment: "The sweeper in services/worker will run as
-- bel_admin." That was true and it was not enough — `auth_challenges` was
-- created in 0007, and 0004's `GRANT ... ON ALL TABLES` had already run, so
-- the admin role had no privilege on a table that did not exist when the
-- grant was written. `services/worker` now exists and found it on its first
-- pass.
--
-- Worth noting because it is a recurring shape rather than a one-off: `ON ALL
-- TABLES` grants what exists at that moment, and every later migration that
-- creates a table has to say who may reach it. 0004's list is the intent for
-- 0004's tables and nothing after.

BEGIN;

-- SELECT and DELETE only. The sweeper reads which rows are past their
-- retention window and removes them; it has no business issuing a code or
-- editing one, and the identity surface has no business deleting its own
-- audit trail — which is why the two roles have exactly opposite privileges
-- on this table.
GRANT SELECT, DELETE ON auth_challenges TO bel_admin;

-- `auth_challenges` is FORCE ROW LEVEL SECURITY, so a grant alone reaches
-- nothing. The policy is scoped to the platform surface: a challenge is
-- visible to the identity surface that issued it (0007) and to the sweeper
-- that retires it, and to nothing else.
CREATE POLICY auth_challenges_platform_sweep ON auth_challenges
  FOR ALL
  USING (app_is_platform())
  WITH CHECK (app_is_platform());

COMMIT;
