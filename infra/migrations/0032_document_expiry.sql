-- 0032_document_expiry — the paperwork stops the sale, not a person.
--
-- `kyb_documents.expires_at` has existed since 0001 and nothing has ever read
-- it except a count on the admin list. An insurance certificate lapses, the
-- operator keeps selling, and the first anybody notices is a claim after a
-- crash. **Selling seats on an uninsured coach is a liability we will not
-- carry** (03-operator-lifecycle.md §3.3), so the calendar enforces itself.
--
-- The ladder — T−60 notice, T−30 notice and a console banner, T−7 a daily
-- reminder and a queue item for us, T−0 no new sales, T+7 suspension — is in
-- the domain (`DocumentExpiry`), not here. This migration adds only the two
-- columns that record the state a worker put the operator in.
--
-- **Blocked is not suspended, and that is the point.** A block is a switch a
-- worker flips and unflips: upload the renewed certificate, get verified, and
-- the next pass turns sales back on with nobody's approval. Suspension is a
-- status change with a reinstatement procedure and a human attached (§4). Two
-- columns rather than one enum value because they undo differently.
--
-- What a block does NOT do: cancel a departure, void a ticket, or stop the
-- scanner. Everything already sold operates — the 72-hour grace in §3.3 is
-- simply what falls out of blocking *sales* rather than *departures*.
BEGIN;

ALTER TABLE operators
  -- Set and cleared by the compliance pass, never by a console. An operator
  -- that could clear its own block is an operator that has no block.
  ADD COLUMN sales_blocked_at     TIMESTAMPTZ,
  -- `doc_type` of the worst lapsed document, so the banner and the refusal
  -- can name it. A key, not prose (ADR-0008).
  ADD COLUMN sales_blocked_doc    TEXT;

-- A handful of rows at most, but every seat claim reads it: a partial index
-- keeps the check on the blocked few rather than a scan of everybody.
CREATE INDEX operators_blocked_idx ON operators (id)
  WHERE sales_blocked_at IS NOT NULL;

-- ── The block an operator cannot lift ───────────────────────────────────────
--
-- Until now `bel_app` held a blanket `GRANT UPDATE ON ALL TABLES` from 0004,
-- which on this table means an operator's own console session could write
-- `status`, `commission_bps` — and, from today, `sales_blocked_at`. A block
-- the blocked party can clear is not a block, and RLS does not help: the
-- tenant policy's whole job is to let a company write its **own** row.
--
-- So the column list becomes the control, exactly as it already is for the
-- applicant role (0015). Two things are on it: the vitrine, which is the
-- branding an operator is meant to edit, and which refund policy is their
-- default, which is a choice among rows they already own. Nothing on it is a
-- term of trade, a lifecycle state, or an enforcement.
REVOKE UPDATE ON operators FROM bel_app;
GRANT UPDATE (accent_hue, header_pattern, title_fr, title_en,
              tagline_fr, tagline_en, logo_asset, cover_asset,
              default_refund_policy_id, default_refund_policy_version)
  ON operators TO bel_app;

COMMIT;
