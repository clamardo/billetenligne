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

-- Ledger and audit tables are append-only by grant, not by convention:
-- migrations revoke UPDATE and DELETE from both roles on
-- ledger_entries, payment_events and audit_log.
