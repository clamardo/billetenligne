-- Roles that make Row-Level Security a real boundary (ADR-0011).
--
-- The application connects as bel_app, which is deliberately NOT a superuser
-- and does NOT own the tables: a superuser or table owner bypasses RLS
-- silently, which would turn our tenancy boundary into a comment.
--
-- bel_admin is a separate role for the admin back office, allowed to read
-- across tenants — every such read is written to the audit log by the
-- application, and the two roles are separate so a bug in one API surface
-- cannot become a leak in the other.

CREATE ROLE bel_app  LOGIN PASSWORD 'bel_app'  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE bel_admin LOGIN PASSWORD 'bel_admin' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

-- bel_public serves the traveller surface. It is the narrowest of the three
-- on purpose: it holds no grant at all on operator_staff, kyb_documents,
-- payouts, refunds or audit_log, and its policies make marking a seat SOLD
-- impossible (0005). An unauthenticated request cannot reach what this role
-- cannot reach.
CREATE ROLE bel_public LOGIN PASSWORD 'bel_public' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

-- And the role the API actually connects as. NOINHERIT: it is a member of all
-- three surface roles and carries the privileges of none of them until a
-- transaction says `SET LOCAL ROLE`. A connection that has not declared its
-- surface can read nothing.
CREATE ROLE bel_api LOGIN PASSWORD 'bel_api' NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT bel_public, bel_app, bel_admin TO bel_api;

-- Ledger and audit tables are append-only by grant, not by convention:
-- migrations revoke UPDATE and DELETE from both roles on
-- ledger_entries, payment_events and audit_log.
