-- 0047_platform_billing — the other billing relationship.
--
-- 04-payments.md §6.2 is explicit: "we do not invoice operators for tickets —
-- we net commission at source". That sentence is about ONE billing
-- relationship — what a ticket sale nets out to — and this migration is
-- deliberately about the other one it does not mention: a flat monthly
-- platform fee for using the console and the booking engine, owed whether
-- the operator sold one ticket this month or none. Modelled in its own
-- tables with its own ledger account (`revenue:subscription`,
-- `receivable:operator:<id>`) rather than folded into `payout_runs` — the
-- day these two get conflated in one number is the day an operator's good
-- ticket week quietly cancels out a platform fee they never agreed was paid.
--
-- No PSP behind either payment type yet: this is placeholder infrastructure,
-- built so the day a Stripe account or a settlement bank account exists, it
-- is a credential swapped into the adapter and not a migration.

BEGIN;

-- Which rail an operator has chosen to pay their platform fee with. One row
-- per operator: a company runs one subscription, not one per payment method
-- it has ever tried.
CREATE TABLE IF NOT EXISTS platform_billing_accounts (
  operator_id        UUID PRIMARY KEY REFERENCES operators(id) ON DELETE CASCADE,
  payment_type        TEXT NOT NULL DEFAULT 'bank_transfer',

  -- Null until a real Stripe account exists behind the card adapter. Read by
  -- nothing today and written by nothing today — it exists so the column is
  -- not itself a migration the day the key arrives.
  stripe_customer_id  TEXT,

  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by          UUID REFERENCES user_accounts(id),

  CONSTRAINT platform_billing_accounts_type_known
    CHECK (payment_type IN ('card', 'bank_transfer'))
);

-- One row per operator per calendar month. Not a queue somebody drains like
-- `payout_runs` — there is one flat tier and nothing to prepare or approve —
-- but a row rather than a pure computation, because "what did we say Océan
-- du Nord owed for August" has to have exactly one answer months later even
-- if the flat rate changes in September.
CREATE TABLE IF NOT EXISTS platform_subscription_charges (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,

  -- Half-open, like a payout period: [period_start, period_end).
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,

  amount_minor  BIGINT NOT NULL,
  currency      CHAR(3) NOT NULL,

  -- 'due' | 'paid'. No 'failed' yet — there is no automatic capture behind
  -- either rail today, so a charge is either owed or somebody at the back
  -- office has confirmed it landed. That confirmation path ships with the
  -- adapter that can actually receive money.
  status        TEXT NOT NULL DEFAULT 'due',

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  paid_at       TIMESTAMPTZ,

  CONSTRAINT platform_subscription_charges_amount_positive
    CHECK (amount_minor > 0),
  CONSTRAINT platform_subscription_charges_status_known
    CHECK (status IN ('due', 'paid')),
  -- One charge per operator per period. Get-or-create relies on this to make
  -- "has this month already been billed" a single unique-violation-safe
  -- statement rather than a check-then-insert race.
  CONSTRAINT platform_subscription_charges_period_unique
    UNIQUE (operator_id, period_start)
);

CREATE INDEX IF NOT EXISTS platform_subscription_charges_operator_idx
  ON platform_subscription_charges (operator_id, period_start);

-- ── Tenant isolation ─────────────────────────────────────────────────────────
--
-- Both tables carry `operator_id` and both get the same tenant policy 0011
-- uses: an operator sees and writes only its own row, the platform surface
-- sees every row (for the back-office view this deployment does not have
-- yet, but the day it exists, the grant should not also need writing).

ALTER TABLE platform_billing_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_billing_accounts FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS platform_billing_accounts_tenant ON platform_billing_accounts;
CREATE POLICY platform_billing_accounts_tenant ON platform_billing_accounts
  FOR ALL
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

ALTER TABLE platform_subscription_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_subscription_charges FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS platform_subscription_charges_tenant ON platform_subscription_charges;
CREATE POLICY platform_subscription_charges_tenant ON platform_subscription_charges
  FOR ALL
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- ── Grants ──────────────────────────────────────────────────────────────────
--
-- Lesson from 0046, applied from the start: a new table needs an explicit
-- grant per surface, and RLS being correct says nothing about whether a role
-- can reach the table at all.
--
-- `bel_app` may read and pick its own payment type — an operator's own
-- preference, not a fact anybody else certifies, unlike a verified mobile
-- money account. It may also INSERT its own charge row (the get-or-create on
-- first read of a new month) but never UPDATE one: marking a charge 'paid'
-- is a back-office confirmation once a real rail exists to confirm it, the
-- same asymmetry 0018 draws around `payout_runs`.
GRANT SELECT, INSERT, UPDATE ON platform_billing_accounts TO bel_app;
GRANT SELECT ON platform_billing_accounts TO bel_admin;

GRANT SELECT, INSERT ON platform_subscription_charges TO bel_app;
GRANT SELECT, UPDATE ON platform_subscription_charges TO bel_admin;

COMMIT;
