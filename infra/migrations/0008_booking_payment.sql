-- 0008_booking_payment — what a booking needs before money can touch it.
--
-- 0002 modelled a booking as the *result* of a payment: a row with a state, a
-- total and a refund policy. What it did not model is the gap in the middle —
-- the four hours between a traveller reserving a seat in the app and walking
-- into an agency with 9 300 francs (`04-payments.md` §4.4). That gap is the
-- entire cash-only pilot, so it needs columns.
--
-- Three things go in, and one of them is a constraint that will look
-- pedantic until the first time it fires.

BEGIN;

-- ── Where the money was taken ───────────────────────────────────────────────
--
-- The till is scoped to a STATION, not to an operator, because a drawer is
-- counted by the person who closes it and "the operator's cash" is not a
-- thing anybody can count. `Account.till(operator, station)` in the domain
-- builds the account name from exactly this column.

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS station_id UUID REFERENCES stations(id),
  ADD COLUMN IF NOT EXISTS payment_method TEXT,
  ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sold_by UUID REFERENCES user_accounts(id);

-- ── Reserve now, pay at the agency ──────────────────────────────────────────
--
-- The code is what the traveller reads to the vendor. Crockford base32 like
-- the booking reference and for the same reasons — read aloud over a bad line,
-- typed by an agent, written on paper — but SHORTER and separate, because it
-- is a bearer: whoever holds it can pay for and collect this booking. A
-- booking reference is an identifier and appears on manifests; a payment code
-- is a secret and expires.
--
-- Nullable: a counter sale is paid at the moment it is made and never has one.

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS payment_code TEXT,
  ADD COLUMN IF NOT EXISTS payment_deadline TIMESTAMPTZ;

-- Unique only among the ones that can still be used. A code is reusable once
-- its booking is paid or expired, which matters at this length: five
-- characters is ~33 million values, and a global unique index would slowly
-- fill up with dead codes and start colliding.
CREATE UNIQUE INDEX IF NOT EXISTS bookings_payment_code_live
  ON bookings (payment_code)
  WHERE payment_code IS NOT NULL AND state = 'pending_payment';

CREATE INDEX IF NOT EXISTS bookings_payment_deadline_idx
  ON bookings (payment_deadline)
  WHERE state = 'pending_payment';

-- ── The constraint that will look pedantic ──────────────────────────────────
--
-- A confirmed booking must say how it was paid and when. Without this, the
-- failure mode is a booking that is confirmed, has a ticket, boarded a
-- passenger, and has no ledger entry anywhere — which is indistinguishable,
-- at the end of the month, from theft. It is not a hypothetical: it is what
-- happens if a code path posts the ledger outside the transaction that
-- confirms, and the ledger write fails.

ALTER TABLE bookings
  DROP CONSTRAINT IF EXISTS bookings_confirmed_is_paid;

ALTER TABLE bookings
  ADD CONSTRAINT bookings_confirmed_is_paid CHECK (
    state <> 'confirmed'
    OR (payment_method IS NOT NULL AND paid_at IS NOT NULL)
  );

-- Cash taken over a counter has to say WHICH counter, because that is the
-- drawer it has to reconcile against.
ALTER TABLE bookings
  DROP CONSTRAINT IF EXISTS bookings_cash_has_a_till;

ALTER TABLE bookings
  ADD CONSTRAINT bookings_cash_has_a_till CHECK (
    payment_method IS DISTINCT FROM 'cash' OR station_id IS NOT NULL
  );

-- ── The public surface may read its own payment code ────────────────────────
--
-- 0005 grants the traveller SELECT and INSERT on bookings under
-- `purchaser_user_id = app_user_id()`. Reserving now needs UPDATE too — a
-- traveller cancelling their own unpaid reservation — and deliberately not
-- DELETE: a booking that was reserved and abandoned is data we want, because
-- the abandonment rate at the agency door is the number that decides whether
-- reserve-then-pay is worth keeping.
GRANT UPDATE ON bookings TO bel_public;

CREATE POLICY bookings_public_update ON bookings
  FOR UPDATE
  USING (app_is_public() AND purchaser_user_id = app_user_id())
  WITH CHECK (app_is_public() AND purchaser_user_id = app_user_id());

-- A traveller reads their own tickets already (0005). They also need the seats
-- on their own booking, which 0005 granted but never gave a read policy for on
-- the *insert* path alone.
GRANT SELECT ON stations TO bel_public;

CREATE POLICY stations_public_read ON stations
  FOR SELECT USING (app_is_public());

COMMIT;
