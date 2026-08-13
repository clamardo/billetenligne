-- The TOTP seed stops being readable from a copy of the database.
--
-- Migration 0013 stored it in the clear and said so, with an argument: a KMS
-- key living in the same environment as the database is reassurance rather
-- than a control. That argument is right about the threat it names — somebody
-- who has the environment has both — and wrong to have stopped there, because
-- it is not the commonest way data leaves. A backup on a laptop, a restore
-- into staging, a read-only injection, a disk sold with a filesystem still on
-- it: each of those is the data *without* the environment, and a key that is
-- not in the table is exactly what separates them.
--
-- So the seed is now sealed by the API before it is written (AES-256-GCM,
-- `SecretCipher`), and the column name that promised base32 no longer tells
-- the truth. Renamed rather than left alone: a column called `secret_base32`
-- holding `v1.<nonce>.<ciphertext>` is the kind of small dishonesty that costs
-- somebody an hour at exactly the wrong moment.
--
-- **Existing rows are not touched here.** They carry no version prefix, the
-- reader returns them as they stand, and the adapter re-seals each one in the
-- transaction that reads it — so a seed is upgraded the next time its owner
-- signs in. A bulk UPDATE is not possible from SQL anyway: the key is in the
-- API's environment and not in this session, which is the point.

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'user_totp' AND column_name = 'secret_base32'
  ) THEN
    ALTER TABLE user_totp RENAME COLUMN secret_base32 TO secret;
  END IF;
END
$$;

COMMENT ON COLUMN user_totp.secret IS
  'The TOTP seed. Sealed by the API as v1.<nonce>.<ciphertext+tag> when '
  'TOTP__ENCRYPTIONKEY is set; base32 as scanned when it is not. A value '
  'without a version prefix predates the control and is re-sealed on read.';

COMMIT;
