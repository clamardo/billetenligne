-- 0003_payments_ledger — money.
--
-- The rule this file exists to enforce: **the ledger is the truth**. Every
-- balance is derived from immutable double-entry rows. There is no mutable
-- `balance` column anywhere in this schema, and there never will be — a
-- balance you can UPDATE is a balance that will eventually be wrong with no
-- way to find out when.

BEGIN;

-- ── Idempotency ─────────────────────────────────────────────────────────────

-- Required on every POST that moves money or inventory. A replay returns the
-- original response rather than doing the work twice, so a duplicate tap can
-- never create a second charge (ADR-0005 rule 2).
CREATE TABLE idempotency_keys (
  key           TEXT PRIMARY KEY,
  scope         TEXT NOT NULL,
  user_id       UUID REFERENCES user_accounts(id),
  -- Hash of the request body. A key reused with a DIFFERENT body is almost
  -- always a client bug, and worth failing loudly rather than silently
  -- picking one of the two.
  request_hash  TEXT NOT NULL,
  response_body JSONB,
  status_code   INTEGER,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours')
);

CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys (expires_at);

-- ── Payment intents ─────────────────────────────────────────────────────────

CREATE TYPE payment_state AS ENUM (
  'created', 'pending', 'authorized', 'captured',
  'failed', 'expired', 'cancelled', 'indeterminate'
);

CREATE TABLE payment_intents (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id       UUID NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  operator_id      UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,

  -- e.g. 'cg.airtel_money'. A string, so a new country's rails need no
  -- schema change at all.
  rail_id          TEXT NOT NULL,
  msisdn           TEXT,
  amount_minor     BIGINT NOT NULL,
  currency         CHAR(3) NOT NULL,

  state            payment_state NOT NULL DEFAULT 'created',
  failure_code     TEXT,
  psp_reference    TEXT,

  idempotency_key  TEXT NOT NULL UNIQUE,

  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ,
  terminal_at      TIMESTAMPTZ,
  last_polled_at   TIMESTAMPTZ,
  poll_attempts    INTEGER NOT NULL DEFAULT 0,

  CONSTRAINT payment_intents_amount_positive CHECK (amount_minor > 0),
  -- A terminal state must be stamped; a non-terminal one must not be.
  CONSTRAINT payment_intents_terminal_stamped CHECK (
    (state IN ('captured','failed','expired','cancelled') AND terminal_at IS NOT NULL)
    OR (state NOT IN ('captured','failed','expired','cancelled') AND terminal_at IS NULL)
  ),
  CONSTRAINT payment_intents_failure_has_code CHECK (
    state <> 'failed' OR failure_code IS NOT NULL
  )
);

-- The worker's queue: everything still in flight, oldest first.
CREATE INDEX payment_intents_inflight_idx
  ON payment_intents (last_polled_at NULLS FIRST)
  WHERE state IN ('pending', 'authorized');

-- The admin console's front page. An indeterminate intent is money in limbo
-- and a customer in the dark, so it is a work queue and not a report.
CREATE INDEX payment_intents_indeterminate_idx
  ON payment_intents (created_at)
  WHERE state = 'indeterminate';

CREATE INDEX payment_intents_booking_idx ON payment_intents (booking_id);

-- Append-only. Every callback and every poll response, exactly as received.
-- When a dispute arrives six weeks later this is the only thing that settles
-- it, so nothing is normalised away.
CREATE TABLE payment_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  intent_id   UUID NOT NULL REFERENCES payment_intents(id) ON DELETE CASCADE,
  source      TEXT NOT NULL,
  raw         JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT payment_events_source_known
    CHECK (source IN ('callback', 'poll', 'manual', 'reconciliation'))
);

CREATE INDEX payment_events_intent_idx ON payment_events (intent_id, received_at);

-- ── Ledger ──────────────────────────────────────────────────────────────────

CREATE TYPE ledger_direction AS ENUM ('debit', 'credit');

-- Double entry, immutable. Account names are strings rather than an enum
-- because they are parameterised: 'payable:operator:<uuid>',
-- 'cash:<station>:till', 'psp:cg.airtel_money:clearing'.
CREATE TABLE ledger_entries (
  id            BIGSERIAL PRIMARY KEY,
  -- Groups the two-or-more rows of one movement. Every txn_id must sum to
  -- zero; ledger_txn_balances below makes that checkable in one query.
  txn_id        UUID NOT NULL,
  account       TEXT NOT NULL,
  direction     ledger_direction NOT NULL,
  amount_minor  BIGINT NOT NULL,
  currency      CHAR(3) NOT NULL,

  operator_id   UUID REFERENCES operators(id),
  booking_id    UUID REFERENCES bookings(id),
  intent_id     UUID REFERENCES payment_intents(id),
  refund_id     UUID,

  memo          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ledger_entries_amount_positive CHECK (amount_minor > 0)
);

CREATE INDEX ledger_entries_txn_idx ON ledger_entries (txn_id);
CREATE INDEX ledger_entries_account_idx ON ledger_entries (account, created_at);
CREATE INDEX ledger_entries_operator_idx ON ledger_entries (operator_id, created_at);

-- Signed balance per transaction. Every row must be zero; anything else means
-- a bug wrote a half-entry, and we want to know within the hour.
CREATE VIEW ledger_txn_balances AS
SELECT
  txn_id,
  currency,
  SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END)
    AS balance_minor
FROM ledger_entries
GROUP BY txn_id, currency;

-- What we owe, and what we hold. Derived, never stored.
CREATE VIEW account_balances AS
SELECT
  account,
  currency,
  SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END)
    AS balance_minor
FROM ledger_entries
GROUP BY account, currency;

-- ── Refunds ─────────────────────────────────────────────────────────────────

CREATE TYPE refund_state AS ENUM (
  'requested', 'approved', 'processing', 'completed',
  'rejected', 'failed', 'cancelled', 'claim_issued', 'claimed', 'claim_expired'
);

-- A refund is a NEW payment intent, never a reversal of the original: mobile
-- money disbursement is a different API, different credentials and a
-- separately funded float from collections.
CREATE TABLE refunds (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id          UUID NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  operator_id         UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,
  original_intent_id  UUID REFERENCES payment_intents(id),
  disbursement_intent_id UUID REFERENCES payment_intents(id),

  amount_minor        BIGINT NOT NULL,
  currency            CHAR(3) NOT NULL,
  -- 10000 = 100%. Integer basis points, so nothing drifts in floating point.
  rate_bps            INTEGER NOT NULL,
  destination         TEXT NOT NULL,
  state               refund_state NOT NULL DEFAULT 'requested',

  -- True when the operator caused it. Bypasses the configured policy
  -- entirely — the platform floor. An operator cannot configure its way out
  -- of its own breakdown.
  involuntary         BOOLEAN NOT NULL DEFAULT FALSE,

  -- Shown at the counter when destination = 'agencyCash'.
  claim_code          TEXT UNIQUE,
  claim_expires_at    TIMESTAMPTZ,
  claimed_by          UUID REFERENCES user_accounts(id),

  requested_by        UUID REFERENCES user_accounts(id),
  approved_by         UUID REFERENCES user_accounts(id),
  reason              TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,

  CONSTRAINT refunds_amount_positive CHECK (amount_minor > 0),
  CONSTRAINT refunds_destination_known CHECK (destination IN
    ('source', 'agencyCash', 'creditNote', 'travellerChoice')),
  CONSTRAINT refunds_cash_has_claim CHECK (
    destination <> 'agencyCash' OR state = 'requested' OR claim_code IS NOT NULL
  )
);

CREATE INDEX refunds_booking_idx ON refunds (booking_id);
CREATE INDEX refunds_open_idx ON refunds (created_at)
  WHERE state IN ('requested', 'approved', 'processing', 'claim_issued');

-- ── Refund policies ─────────────────────────────────────────────────────────

-- Versioned and immutable. A booking stores the version it was sold under and
-- is judged by that version forever (ADR-0015 rule 1).
CREATE TABLE refund_policies (
  id                   UUID NOT NULL,
  version              INTEGER NOT NULL,
  operator_id          UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  name                 TEXT NOT NULL,
  tiers                JSONB NOT NULL,
  destination          TEXT NOT NULL DEFAULT 'source',
  processing_hours     INTEGER NOT NULL DEFAULT 72,
  refund_service_fee   BOOLEAN NOT NULL DEFAULT FALSE,
  non_refundable_fares TEXT[] NOT NULL DEFAULT '{}',
  effective_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by           UUID REFERENCES user_accounts(id),

  PRIMARY KEY (id, version)
);

-- ── Outbox ──────────────────────────────────────────────────────────────────

-- Compose, persist, drain. A send is never inline with a request, so a slow
-- SMS gateway can never slow down a payment confirmation (ADR-0019 rule 1).
--
-- Payments are deliberately NOT in here: a payment must never be replayed by
-- a background worker. Recovery is a status poll, never a re-send.
CREATE TABLE outbox (
  id              BIGSERIAL PRIMARY KEY,
  aggregate       TEXT NOT NULL,
  aggregate_id    UUID,
  event_type      TEXT NOT NULL,
  payload         JSONB NOT NULL,
  -- (event, channel, recipient) is unique: a retried drain cannot double-send,
  -- and nothing erodes trust like two conflicting SMS about one payment.
  dedupe_key      TEXT UNIQUE,
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at    TIMESTAMPTZ,
  last_error      TEXT
);

CREATE INDEX outbox_pending_idx ON outbox (next_attempt_at)
  WHERE delivered_at IS NULL;

-- ── Audit ───────────────────────────────────────────────────────────────────

-- Append-only, and shipped to separate storage. Not even super_admin can edit
-- it. Every cross-tenant read from the admin API lands here with an actor and
-- a reason.
CREATE TABLE audit_log (
  id           BIGSERIAL PRIMARY KEY,
  actor_id     UUID REFERENCES user_accounts(id),
  actor_type   TEXT NOT NULL,
  action       TEXT NOT NULL,
  subject_type TEXT,
  subject_id   TEXT,
  operator_id  UUID REFERENCES operators(id),
  -- Mandatory free text on every sensitive action. "Why" is the question an
  -- audit answers, and it cannot be reconstructed later.
  reason       TEXT,
  before_state JSONB,
  after_state  JSONB,
  trace_id     TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_log_subject_idx ON audit_log (subject_type, subject_id, created_at DESC);
CREATE INDEX audit_log_actor_idx ON audit_log (actor_id, created_at DESC);

COMMIT;
