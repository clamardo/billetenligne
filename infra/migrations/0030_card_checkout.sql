-- 0030_card_checkout — paying with a card, on somebody else's page.
--
-- Every rail so far pushes a prompt to a handset: the traveller types a PIN
-- into a menu we do not control, and the answer arrives by callback or by
-- poll. A card does not work like that. The traveller is sent to the PSP's
-- hosted page, types a number this system never sees, and comes back — and
-- the URL of that page is the one new fact the schema has to hold.
--
-- **Stored rather than held in memory**, because the app that opened it may
-- be killed while somebody is typing a card number into a browser, and the
-- screen they come back to has to be able to offer the same page again.
-- Minting a second one would be a second transaction at the PSP for one
-- journey, which is how a traveller ends up charged twice.
--
-- Nothing else changes. `msisdn` was already nullable, the state machine is
-- the same one, `railCapture` already posts into `psp:clearing:<rail>` and
-- credits the operator, and the payout run already moves it on. A card is a
-- rail, and that is the whole point of ADR-0006.
BEGIN;

ALTER TABLE payment_intents
  -- Where the traveller enters their card. Null on every push rail, and on a
  -- checkout rail until the PSP has answered with one.
  ADD COLUMN IF NOT EXISTS checkout_url TEXT,

  -- Money in a wallet has a wallet number; money on a card does not. This
  -- says which kind of rail this attempt was opened against, so a support
  -- agent reading the row does not have to know the rail catalogue by heart
  -- to work out why `msisdn` is empty.
  ADD COLUMN IF NOT EXISTS hosted_checkout BOOLEAN NOT NULL DEFAULT FALSE;

-- A push rail's attempt has a wallet to push to. A hosted checkout does not,
-- and inventing one to satisfy a NOT NULL is how "which number did we charge?"
-- gets a confident wrong answer six weeks later.
ALTER TABLE payment_intents
  DROP CONSTRAINT IF EXISTS payment_intents_push_has_a_wallet;

ALTER TABLE payment_intents
  ADD CONSTRAINT payment_intents_push_has_a_wallet CHECK (
    hosted_checkout OR msisdn IS NOT NULL
  );

-- Only a checkout rail has a page to send anybody to. A URL on a push rail is
-- a browser opening for a payment that answers on the handset.
ALTER TABLE payment_intents
  DROP CONSTRAINT IF EXISTS payment_intents_url_is_for_checkout;

ALTER TABLE payment_intents
  ADD CONSTRAINT payment_intents_url_is_for_checkout CHECK (
    hosted_checkout OR checkout_url IS NULL
  );

COMMIT;
