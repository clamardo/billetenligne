-- 0011_mobile_money — where the money is pulled from, and where it lands.
--
-- 0003 modelled a payment intent completely: rail, MSISDN, amount, state
-- machine, poll bookkeeping, an append-only event log. What it never modelled
-- is the two ends of the transfer:
--
--   * the operator's **collection account** — the mobile money number a
--     traveller's francs actually arrive in;
--   * the traveller's **payer number**, which is not necessarily their own.
--     Somebody buying a ticket for their mother pays from their own wallet;
--     somebody whose wallet is empty pays from a relative's, standing next to
--     them. `payment_intents.msisdn` already holds it — what was missing is
--     the fact that it is deliberately allowed to differ from the account.
--
-- The second is worth stating because it changes a validation: we must NOT
-- require the payer MSISDN to match the signed-in traveller's. Requiring it
-- is the obvious thing to write and it breaks the most common way a ticket
-- gets paid for in this market.

BEGIN;

-- ── Where an operator collects ──────────────────────────────────────────────
--
-- One row per operator per rail, because an operator may hold an Airtel
-- merchant number and an MTN one, and a traveller pays into whichever matches
-- the wallet they are paying from. Routing on our side is then a lookup
-- rather than a guess.

CREATE TABLE operator_payment_accounts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  -- 'cg.airtel_money' | 'cg.mtn_momo' | … Matches payment_intents.rail_id, and
  -- a string for the same reason: a new country's rails need no migration.
  rail_id       TEXT NOT NULL,

  -- E.164 without the '+', like user_accounts.phone_e164. The merchant or
  -- till number the operator gave us, verified before it is used.
  msisdn        TEXT NOT NULL,

  -- What the traveller sees on the confirmation screen before they press pay.
  -- Shown because paying a number you do not recognise is the moment people
  -- abandon, and "Ocean du Nord" beside the number is what stops that.
  display_name  TEXT NOT NULL,

  -- A number nobody has proved belongs to the operator must not receive
  -- money. Set when somebody has confirmed it — by a test payment, or by an
  -- admin who saw the merchant agreement.
  verified_at   TIMESTAMPTZ,

  -- Exactly one account per rail is the live one. Deactivating rather than
  -- deleting, because an intent that already paid into an old number has to
  -- keep resolving to it in a dispute six weeks later.
  active        BOOLEAN NOT NULL DEFAULT TRUE,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT operator_payment_accounts_msisdn_digits
    CHECK (msisdn ~ '^[0-9]{8,15}$')
);

-- One ACTIVE account per operator per rail. A partial unique index rather
-- than a plain one, so history is keepable: yesterday's number stays in the
-- table, inactive, and still resolves for the intents that used it.
CREATE UNIQUE INDEX operator_payment_accounts_live
  ON operator_payment_accounts (operator_id, rail_id)
  WHERE active;

CREATE INDEX operator_payment_accounts_operator_idx
  ON operator_payment_accounts (operator_id);

-- ── What the intent needs to remember ───────────────────────────────────────

ALTER TABLE payment_intents
  -- Captured at creation, not looked up at settlement. An operator who
  -- changes their collection number on Tuesday must not silently redirect
  -- Monday's in-flight payment, and a dispute six weeks later has to be able
  -- to say which number the money was pushed to.
  ADD COLUMN IF NOT EXISTS collection_msisdn TEXT,

  -- The traveller's own number at the time, kept beside the payer number so
  -- "paid from somebody else's wallet" is answerable without a join to an
  -- account row that may since have changed.
  ADD COLUMN IF NOT EXISTS payer_is_account_holder BOOLEAN,

  -- What the rail called it. MTN echoes our X-Reference-Id; Airtel mints its
  -- own. Stored separately from psp_reference so a re-query can use whichever
  -- that rail actually keys on.
  ADD COLUMN IF NOT EXISTS rail_transaction_id TEXT;

-- ── Grants ──────────────────────────────────────────────────────────────────
--
-- A traveller creates and reads their OWN intent and nothing else. No UPDATE
-- at all: every state transition is a system action performed under the
-- operator or platform scope after the rail has spoken. There is no path from
-- an internet request to a captured payment, which is the same property
-- migration 0005 established for a sold seat and for the same reason.

GRANT SELECT, INSERT ON payment_intents TO bel_public;
GRANT SELECT ON operator_payment_accounts TO bel_public;

ALTER TABLE payment_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_intents FORCE ROW LEVEL SECURITY;

CREATE POLICY payment_intents_public_own ON payment_intents
  FOR SELECT USING (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = payment_intents.booking_id
        AND b.purchaser_user_id = app_user_id()
    )
  );

CREATE POLICY payment_intents_public_create ON payment_intents
  FOR INSERT WITH CHECK (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.id = payment_intents.booking_id
        AND b.purchaser_user_id = app_user_id()
        -- Only against a booking that is actually waiting to be paid. Without
        -- this a traveller could open an intent against a booking that is
        -- already confirmed and pay for it twice.
        AND b.state = 'pending_payment'
    )
  );

CREATE POLICY payment_intents_tenant ON payment_intents
  FOR ALL
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- The collection account is shown to the traveller before they press pay —
-- the number and the name they are about to send money to. Only the live,
-- verified one: an unverified number is one nobody has proved belongs to the
-- operator, and money sent to it is money gone.
ALTER TABLE operator_payment_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE operator_payment_accounts FORCE ROW LEVEL SECURITY;

CREATE POLICY operator_payment_accounts_public_read ON operator_payment_accounts
  FOR SELECT USING (app_is_public() AND active AND verified_at IS NOT NULL);

CREATE POLICY operator_payment_accounts_tenant ON operator_payment_accounts
  FOR ALL
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

-- payment_events stays unreachable from the public surface. It holds raw
-- rail payloads — MSISDNs, merchant identifiers, whatever the telco chose to
-- echo — and a traveller has no business reading any of it.
REVOKE ALL ON payment_events FROM bel_public;

COMMIT;
