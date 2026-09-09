-- 0048_operator_custom_roles — an operator's own roles, mixed and matched.
--
-- ADR-0011 already said the goal plainly: "capability strings, never role
-- names, in every check ... a new role is then a configuration row, not a
-- release." Until now the configuration rows were ours, fixed at build time
-- (`Capability.operatorRoles`). This lets an operator write their own: a
-- ticket seller who should only ever reach the booking API, a driver who
-- scans tickets and nothing else — cloned from one of the built-in roles as
-- a starting point, renamed, and given whatever subset of the *cloning
-- caller's own* capabilities they choose to keep (`CustomRoleDefinition`,
-- `bel_platform`, enforces that subset at the application layer; this table
-- only stores the result).
--
-- Created well after 0004_rls_grants, the same situation 0046 found for
-- `operator_payment_accounts` — so the grants below are explicit rather than
-- inherited from 0004's one-time blanket GRANT.

-- Every statement below is re-appliable, which is the rule the migration
-- runner's own suite enforces: the newest file has to survive being applied
-- to a database that already has it. Written without the guards, this one
-- failed on `relation "operator_custom_roles" already exists` — a red suite
-- that says nothing about custom roles and everything about the file's shape.

BEGIN;

CREATE TABLE IF NOT EXISTS operator_custom_roles (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id      UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  capabilities     TEXT[] NOT NULL,
  -- The default role this one started as a copy of, if any — a hint for the
  -- console's own UI only; nothing server-side reads it back.
  cloned_from_role TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Case-insensitive on purpose, and an index rather than a table-level UNIQUE
-- because Postgres does not allow an expression in the latter: `Ticket_Seller`
-- and `ticket_seller` would be genuinely ambiguous the moment either lands in
-- `operator_staff.roles`, which has no way to tell two spellings apart from
-- the string alone.
CREATE UNIQUE INDEX IF NOT EXISTS operator_custom_roles_operator_id_lower_idx
  ON operator_custom_roles (operator_id, lower(name));

ALTER TABLE operator_custom_roles ENABLE ROW LEVEL SECURITY;
-- FORCE so the policy applies to the table owner too (0004's own rule for
-- every tenant-scoped table) — otherwise a migration run or an admin session
-- would silently see every operator's roles.
ALTER TABLE operator_custom_roles FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS operator_custom_roles_tenant_isolation ON operator_custom_roles;
CREATE POLICY operator_custom_roles_tenant_isolation ON operator_custom_roles
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

GRANT SELECT, INSERT, UPDATE, DELETE ON operator_custom_roles
  TO bel_app, bel_admin;

-- The identity surface resolves a staff row's roles to capabilities on every
-- authenticated request (`postgres_identity.dart`), the same reason it
-- already reads `operator_staff` and `operators` (0009). This table carries
-- only a name and a capability-string array — no PII, no money — so it is
-- the same low-risk grant 0009 made for those two, extended to a third.
GRANT SELECT ON operator_custom_roles TO bel_identity;

DROP POLICY IF EXISTS operator_custom_roles_identity_read ON operator_custom_roles;
CREATE POLICY operator_custom_roles_identity_read ON operator_custom_roles
  FOR SELECT USING (app_is_identity());

COMMIT;
