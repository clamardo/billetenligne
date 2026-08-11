-- 0026_paid_changes — collecting the fare difference before the coach moves.
--
-- §8.1 prices every candidate departure, and until now a change that owed
-- money was refused with the amount and sent to a counter. That was honest
-- and it was also the commonest upgrade there is: an earlier coach, a nicer
-- one, a bigger one on a feast day. This table is what makes it payable in
-- the app.
--
-- **A change order is a promise that expires, not a change.** It holds the
-- target seats, states what is owed, and waits. Applying it is the capture's
-- job and nobody else's — a change applied on `pending` is the same free
-- journey a ticket issued on `pending` would be (ADR-0005), one departure
-- further along.
--
-- The seats are held by an ordinary row in `holds`, which is what makes the
-- expiry story free: the sweeper that already puts lapsed holds back on sale
-- puts these back too, and this table only has to notice afterwards.

BEGIN;

CREATE TYPE change_order_state AS ENUM (
  'awaiting_payment',
  'applied',
  'expired',
  'cancelled'
);

CREATE TABLE booking_changes (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id         UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  operator_id        UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,

  -- Both ends recorded, because "where it was" is not recoverable from the
  -- booking once the move lands, and a dispute six weeks later is about
  -- exactly that.
  from_departure_id  UUID NOT NULL REFERENCES departures(id) ON DELETE RESTRICT,
  to_departure_id    UUID NOT NULL REFERENCES departures(id) ON DELETE RESTRICT,

  -- The seats this order is holding on the target departure. Kept here as
  -- well as on the hold so that applying the move needs no guesswork about
  -- which of a departure's held seats were meant for this booking.
  seat_labels        TEXT[] NOT NULL,
  hold_id            UUID REFERENCES holds(id) ON DELETE SET NULL,

  -- What was quoted, in the units the ledger thinks in. Stored rather than
  -- recomputed at capture: the terms are the ones that were on the screen
  -- when the traveller agreed, and a re-quote at settlement time would let a
  -- price change between the tap and the PIN.
  fee_minor          BIGINT NOT NULL DEFAULT 0,
  difference_minor   BIGINT NOT NULL DEFAULT 0,
  owed_minor         BIGINT NOT NULL,
  currency           CHAR(3) NOT NULL,

  state              change_order_state NOT NULL DEFAULT 'awaiting_payment',

  created_by         UUID REFERENCES user_accounts(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at         TIMESTAMPTZ NOT NULL,
  applied_at         TIMESTAMPTZ,

  CONSTRAINT booking_changes_owes_something CHECK (owed_minor > 0),
  CONSTRAINT booking_changes_amounts_non_negative
    CHECK (fee_minor >= 0 AND difference_minor >= 0),
  CONSTRAINT booking_changes_have_seats CHECK (cardinality(seat_labels) > 0),
  CONSTRAINT booking_changes_actually_move
    CHECK (from_departure_id <> to_departure_id),
  CONSTRAINT booking_changes_expire_after_creation
    CHECK (expires_at > created_at),
  -- Applied means stamped, and stamped means applied. Without this the
  -- question "when did this booking move?" has two answers that can disagree.
  CONSTRAINT booking_changes_applied_is_stamped CHECK (
    (state = 'applied' AND applied_at IS NOT NULL)
    OR (state <> 'applied' AND applied_at IS NULL)
  )
);

-- One live order per booking. A traveller who taps two departures while the
-- first prompt is still on their handset would otherwise hold two sets of
-- seats and owe two amounts, and only one of those two can ever be applied.
CREATE UNIQUE INDEX booking_changes_one_open_per_booking
  ON booking_changes (booking_id)
  WHERE state = 'awaiting_payment';

CREATE INDEX booking_changes_sweep_idx
  ON booking_changes (expires_at)
  WHERE state = 'awaiting_payment';

-- ── The intent that pays for one ────────────────────────────────────────────
--
-- Nullable, and it is the discriminator: an intent with a change id settles a
-- change, one without settles the booking it names. Both still carry
-- `booking_id`, because a payment that cannot say which journey it belongs to
-- is a payment nobody can reconcile.
ALTER TABLE payment_intents
  ADD COLUMN change_id UUID REFERENCES booking_changes(id) ON DELETE RESTRICT;

CREATE INDEX payment_intents_change_idx
  ON payment_intents (change_id) WHERE change_id IS NOT NULL;

-- A traveller may open an intent against their own waiting order.
--
-- The existing public INSERT policy insists the booking be `pending_payment`,
-- and rightly: without it somebody could pay for a confirmed booking twice.
-- A change is the other case — the booking is confirmed and the debt is the
-- difference — so it gets its own policy rather than a loosened one, with the
-- same three conditions stated for the order instead: theirs, still waiting,
-- not yet lapsed. Policies for one command are OR'd, so this widens exactly
-- the row it describes and nothing else.
CREATE POLICY payment_intents_public_change ON payment_intents
  FOR INSERT WITH CHECK (
    app_is_public() AND change_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM booking_changes c
        JOIN bookings b ON b.id = c.booking_id
       WHERE c.id = payment_intents.change_id
         AND b.id = payment_intents.booking_id
         AND b.purchaser_user_id = app_user_id()
         AND c.state = 'awaiting_payment'
         AND c.expires_at > now()
    )
  );

-- ── Who may see one ─────────────────────────────────────────────────────────

ALTER TABLE booking_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_changes FORCE ROW LEVEL SECURITY;

-- The traveller reads their own and writes none. Creating an order takes
-- seats from a departure and quotes money against stored terms; that is the
-- platform role's transaction, re-checking ownership as it goes, exactly as
-- cancelling is.
CREATE POLICY booking_changes_public_own ON booking_changes
  FOR SELECT USING (
    app_is_public() AND EXISTS (
      SELECT 1 FROM bookings b
       WHERE b.id = booking_changes.booking_id
         AND b.purchaser_user_id = app_user_id()
    )
  );

CREATE POLICY booking_changes_tenant ON booking_changes
  FOR ALL
  USING (NOT app_is_public() AND (app_is_platform() OR operator_id = app_tenant_id()))
  WITH CHECK (NOT app_is_public() AND (app_is_platform() OR operator_id = app_tenant_id()));

GRANT SELECT ON booking_changes TO bel_public;
GRANT SELECT, INSERT, UPDATE ON booking_changes TO bel_app;
-- The platform surface, which is what both halves of this feature run as: the
-- escalated transaction that takes the seats and writes the promise, and the
-- worker one that applies the movement when the money lands.
GRANT SELECT, INSERT, UPDATE ON booking_changes TO bel_admin;

COMMIT;
