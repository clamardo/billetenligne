-- 0018_payouts — the week's statement, and the money that follows it.
--
-- `04-payments.md` §6.2. We never invoice an operator for tickets: commission
-- is netted at source when each sale settles, and what is left is paid out.
-- This migration is where "what is left" stops being a query somebody runs
-- and becomes a row two different people have to touch.
--
-- Four decisions, each of which is a fraud or an argument this avoids:
--
--   1. **An operator cannot create, approve or edit their own payout.**
--      `bel_app` gets SELECT and nothing else; every write is `bel_admin`.
--      Two-person control on money leaving (ADR-0011) is worth nothing if the
--      party being paid can move the row themselves.
--
--   2. **The amount is the ledger's balance, not a sum of these columns.**
--      The line items are what the operator reads and argues with; the debt
--      is `payable:operator:<id>` less their tills at the moment of release.
--      Two numbers that both claim to be the debt is how a reconciliation
--      meeting turns into a dispute.
--
--   3. **Approval and release are different columns, written at different
--      times, by different people.** A run that was approved and never paid
--      is a visible state rather than an absence, which is the difference
--      between chasing it and discovering it.
--
--   4. **One run per operator per period.** A partial unique index rather
--      than a convention: paying the same week twice is the one mistake in
--      this file that cannot be undone with an UPDATE.

BEGIN;

CREATE TYPE payout_state AS ENUM ('draft', 'approved', 'paid', 'void');

CREATE TABLE payout_runs (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id         UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,

  -- Half-open, `[period_start, period_end)`. A statement for the week ending
  -- Sunday must not contain Monday's first sale, and the only way to be sure
  -- of that at a boundary is to store the window the query actually used.
  period_start        TIMESTAMPTZ NOT NULL,
  period_end          TIMESTAMPTZ NOT NULL,

  currency            CHAR(3) NOT NULL,

  -- ── What the operator reads (§6.2) ────────────────────────────────────
  online_sales_count  INTEGER NOT NULL DEFAULT 0,
  online_gross_minor  BIGINT  NOT NULL DEFAULT 0,
  -- Present, and never paid out. The operator already holds this money; it
  -- is on the statement because "where is my cash money?" is the question
  -- they ask first, every time.
  cash_sales_count    INTEGER NOT NULL DEFAULT 0,
  cash_gross_minor    BIGINT  NOT NULL DEFAULT 0,
  commission_minor    BIGINT  NOT NULL DEFAULT 0,
  service_fees_minor  BIGINT  NOT NULL DEFAULT 0,
  refunds_minor       BIGINT  NOT NULL DEFAULT 0,

  -- ── What decides the transfer (decision 2) ────────────────────────────
  payable_minor       BIGINT  NOT NULL,
  -- Counted against the payable rather than paid: it is already in their
  -- drawer. Netting the two is what makes a cash sale cost an operator the
  -- service fee and nothing else, with no invoice ever raised.
  tills_minor         BIGINT  NOT NULL,
  -- Signed on purpose. A week of nothing but cash sales is negative — they
  -- owe us the fees — and that is a statement, not a transfer.
  net_minor           BIGINT  NOT NULL,

  state               payout_state NOT NULL DEFAULT 'draft',

  -- Where it goes. Copied onto the run rather than read from the operator at
  -- release time, so changing a settlement account can never redirect a
  -- payout that was already approved against the old one.
  destination         TEXT,

  prepared_by         UUID REFERENCES user_accounts(id),
  prepared_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by         UUID REFERENCES user_accounts(id),
  approved_at         TIMESTAMPTZ,
  paid_at             TIMESTAMPTZ,
  -- The ledger movement this released. Null until it is paid, and the join
  -- that lets anybody check the statement against the books.
  txn_id              UUID,
  reference           TEXT,

  CONSTRAINT payout_runs_window_ordered CHECK (period_end > period_start),
  CONSTRAINT payout_runs_net_is_difference
    CHECK (net_minor = payable_minor - tills_minor),
  CONSTRAINT payout_runs_counts_sane
    CHECK (online_sales_count >= 0 AND cash_sales_count >= 0),
  -- Decision 3, as a constraint: a run cannot be paid without having been
  -- approved by somebody, and cannot be approved without a name against it.
  CONSTRAINT payout_runs_approval_recorded CHECK (
    (state = 'draft')
    OR (state = 'void')
    OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
  ),
  CONSTRAINT payout_runs_payment_recorded CHECK (
    state <> 'paid' OR (paid_at IS NOT NULL AND txn_id IS NOT NULL)
  )
);

-- Decision 4. Void runs are excluded so a mistake can be voided and redone.
CREATE UNIQUE INDEX payout_runs_one_per_period
  ON payout_runs (operator_id, period_start, period_end)
  WHERE state <> 'void';

CREATE INDEX payout_runs_operator_idx
  ON payout_runs (operator_id, period_end DESC);

-- The work queue: what has been prepared and is waiting for a second pair of
-- eyes, oldest first.
CREATE INDEX payout_runs_pending_idx
  ON payout_runs (state, prepared_at)
  WHERE state IN ('draft', 'approved');

-- ── Row-level security ──────────────────────────────────────────────────────

ALTER TABLE payout_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE payout_runs FORCE ROW LEVEL SECURITY;

CREATE POLICY payout_runs_tenant_isolation ON payout_runs
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- ── Grants ──────────────────────────────────────────────────────────────────

-- Decision 1. An operator reads their own statements — that is the whole
-- point of producing them — and can do nothing else to them. Note what is
-- absent: no INSERT, no UPDATE, no column exception. The party being paid
-- does not get to move the row that pays them.
GRANT SELECT ON payout_runs TO bel_app;
GRANT SELECT, INSERT ON payout_runs TO bel_admin;
GRANT UPDATE (state, approved_by, approved_at, paid_at, txn_id, reference,
              destination)
  ON payout_runs TO bel_admin;

-- The line items and the window are what the statement claimed at the time.
-- Not editable by anybody: a statement whose numbers can be changed after an
-- operator has read it is not a statement.
REVOKE DELETE ON payout_runs FROM bel_app, bel_admin;

COMMIT;
