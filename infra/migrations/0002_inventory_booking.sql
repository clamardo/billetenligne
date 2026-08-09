-- 0002_inventory_booking — the hot path.
--
-- This file holds the two invariants the business depends on:
--   * a seat is never sold twice, and
--   * a ticket is issued only against captured money.
--
-- Both are enforced here rather than in application code, because the console,
-- the API and any future integration all reach the same tables and only the
-- database sees every writer.

BEGIN;

-- ── Inventory ───────────────────────────────────────────────────────────────

CREATE TYPE seat_state AS ENUM ('available', 'held', 'sold', 'blocked');

-- One row per seat per departure, created when the departure is materialised.
-- This is what holds lock against (ADR-0012). No Redis, no distributed lock:
-- SELECT ... FOR UPDATE on a single row is simple, correct, and Postgres
-- handles this volume without breaking a sweat. The day we need more we will
-- know.
CREATE TABLE seats (
  departure_id  UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  seat_label    TEXT NOT NULL,
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  section_code  TEXT NOT NULL,
  state         seat_state NOT NULL DEFAULT 'available',
  fare_minor    BIGINT NOT NULL,
  currency      CHAR(3) NOT NULL,

  hold_id       UUID,
  -- Checked on read AND swept by a worker. Never by the sweeper alone: a
  -- stalled worker must not be able to leak inventory.
  held_until    TIMESTAMPTZ,
  booking_id    UUID,

  PRIMARY KEY (departure_id, seat_label),

  -- A held seat must have both a hold and an expiry; a sold seat must have a
  -- booking. Contradictory rows are impossible rather than merely unlikely.
  CONSTRAINT seats_hold_consistent CHECK (
    (state = 'held' AND hold_id IS NOT NULL AND held_until IS NOT NULL)
    OR (state <> 'held' AND hold_id IS NULL)
  ),
  CONSTRAINT seats_sold_consistent CHECK (
    (state = 'sold' AND booking_id IS NOT NULL)
    OR (state <> 'sold')
  )
);

CREATE INDEX seats_sweep_idx ON seats (held_until)
  WHERE state = 'held';

CREATE INDEX seats_booking_idx ON seats (booking_id)
  WHERE booking_id IS NOT NULL;

CREATE TYPE hold_state AS ENUM ('active', 'consumed', 'released', 'expired');

CREATE TABLE holds (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id      UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  departure_id     UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  user_id          UUID REFERENCES user_accounts(id),
  seat_labels      TEXT[] NOT NULL,
  state            hold_state NOT NULL DEFAULT 'active',

  -- TTL is always strictly greater than the payment window. Inverted, the
  -- seat is released out from under someone entering their PIN.
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ NOT NULL,

  -- A retried request with the same key returns the EXISTING hold, never a
  -- second one, so a flaky connection cannot accumulate holds.
  idempotency_key  TEXT NOT NULL,

  -- 'app' | 'console' | 'agency'. Cash sales take the same holds through the
  -- same code path — there is no back door, which is what makes agent and
  -- digital sales reconcile.
  channel          TEXT NOT NULL DEFAULT 'app',

  UNIQUE (idempotency_key),
  CONSTRAINT holds_expire_after_creation CHECK (expires_at > created_at),
  CONSTRAINT holds_have_seats CHECK (cardinality(seat_labels) > 0)
);

CREATE INDEX holds_sweep_idx ON holds (expires_at) WHERE state = 'active';

-- ── Booking ─────────────────────────────────────────────────────────────────

CREATE TYPE booking_state AS ENUM (
  'pending_payment', 'confirmed', 'cancelled', 'refunded', 'expired'
);

CREATE TABLE bookings (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Short Crockford base32, read aloud over a bad line and typed by an agent.
  ref                    TEXT NOT NULL UNIQUE,
  operator_id            UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,
  departure_id           UUID NOT NULL REFERENCES departures(id) ON DELETE RESTRICT,
  hold_id                UUID REFERENCES holds(id),
  purchaser_user_id      UUID REFERENCES user_accounts(id),

  state                  booking_state NOT NULL DEFAULT 'pending_payment',
  fare_minor             BIGINT NOT NULL,
  service_fee_minor      BIGINT NOT NULL,
  total_minor            BIGINT NOT NULL,
  currency               CHAR(3) NOT NULL,

  channel                TEXT NOT NULL DEFAULT 'app',
  idempotency_key        TEXT,

  -- Judged forever by the policy version it was sold under. Changing
  -- tomorrow's policy must never change yesterday's customer's entitlement —
  -- the most important rule in ADR-0015.
  refund_policy_id       UUID,
  refund_policy_version  INTEGER,

  -- Set when an operator caused a change. Permanently exempts the booking
  -- from fees and fare differences (ADR-0016).
  involuntary_change     BOOLEAN NOT NULL DEFAULT FALSE,

  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  confirmed_at           TIMESTAMPTZ,
  cancelled_at           TIMESTAMPTZ,

  CONSTRAINT bookings_total_is_sum
    CHECK (total_minor = fare_minor + service_fee_minor),
  CONSTRAINT bookings_amounts_non_negative
    CHECK (fare_minor >= 0 AND service_fee_minor >= 0)
);

CREATE INDEX bookings_user_idx ON bookings (purchaser_user_id, created_at DESC);
CREATE INDEX bookings_departure_idx ON bookings (departure_id);
CREATE INDEX bookings_operator_created_idx ON bookings (operator_id, created_at DESC);

CREATE TABLE booking_seats (
  booking_id       UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  seat_label       TEXT NOT NULL,
  passenger_name   TEXT NOT NULL,
  -- Distinct from the purchaser. This one column is what makes "buy a ticket
  -- for my mother" a first-class flow rather than a hack.
  passenger_phone  TEXT,
  passenger_id_number TEXT,
  fare_minor       BIGINT NOT NULL,

  PRIMARY KEY (booking_id, seat_label)
);

-- ── Ticketing ───────────────────────────────────────────────────────────────

CREATE TABLE tickets (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id       UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  operator_id      UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,
  departure_id     UUID NOT NULL REFERENCES departures(id) ON DELETE RESTRICT,
  seat_label       TEXT NOT NULL,

  -- base45(CBOR) + Ed25519 signature, under 300 bytes so the QR stays
  -- low-density and scans fast on a cracked screen in daylight (ADR-0007).
  payload          TEXT NOT NULL,
  signature        BYTEA NOT NULL,
  -- Selects the public key, so rotation is seamless.
  key_id           INTEGER NOT NULL,
  -- Seeds the 30-second code shown beneath the QR. A screenshot still scans;
  -- its code is frozen, which is what fails the freshness check.
  rotating_secret  BYTEA NOT NULL,

  issued_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Set at refund APPROVAL, not completion, so a refunded ticket cannot board
  -- while the money is still in flight.
  voided_at        TIMESTAMPTZ,

  UNIQUE (booking_id, seat_label)
);

CREATE INDEX tickets_departure_idx ON tickets (departure_id);

CREATE TYPE redemption_mode AS ENUM ('scan', 'manual', 'override');

-- One row per ticket, ever. The PRIMARY KEY is the double-boarding guard:
-- a second scan cannot insert, so the conductor sees DÉJÀ EMBARQUÉ with the
-- first scan time rather than boarding someone twice.
CREATE TABLE redemptions (
  ticket_id     UUID PRIMARY KEY REFERENCES tickets(id) ON DELETE CASCADE,
  departure_id  UUID NOT NULL REFERENCES departures(id) ON DELETE CASCADE,
  operator_id   UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  scanned_at    TIMESTAMPTZ NOT NULL,
  device_id     TEXT,
  scanned_by    UUID REFERENCES user_accounts(id),
  mode          redemption_mode NOT NULL DEFAULT 'scan',
  -- Recorded, never rejected: leaving a paying passenger at the roadside
  -- because our clock disagreed is not an acceptable outcome.
  code_was_stale BOOLEAN NOT NULL DEFAULT FALSE,
  synced_at     TIMESTAMPTZ
);

CREATE INDEX redemptions_departure_idx ON redemptions (departure_id);

COMMIT;
