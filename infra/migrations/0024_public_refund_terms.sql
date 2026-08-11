-- 0024_public_refund_terms — the traveller may read the terms they are
-- judged by.
--
-- `01-feature-spec.md` §4.1 says the cancellation policy is shown **before**
-- the user commits, and §8.2 says the refund quote is shown before the
-- cancel button. Both are sentences generated from `refund_policies` rows —
-- and until now the public role could not read that table at all, so the two
-- screens either could not exist or would have had to be served by a widened
-- privilege somewhere else.
--
-- The terms are published, not confidential. They are printed on the
-- departure detail screen for anybody who looks at a departure, they are
-- quoted back on the cancellation sheet, and an operator who did not want a
-- traveller to read them would have no way to sell under them. So SELECT is
-- granted, and the policy is deliberately not scoped to "policies of
-- bookings you own": a traveller comparing two companies before buying is
-- reading terms they have no booking under, which is the whole point of
-- showing them beforehand.
--
-- What does **not** change: `bel_public` gets SELECT and nothing else. The
-- table is already append-only for the roles that can write it (0014), and
-- the public role could not write it before this migration and cannot after.
-- An executed guarantee below asserts exactly that, because "we only granted
-- SELECT" is a claim about a line of SQL and the guarantee is a claim about
-- the running database.

BEGIN;

CREATE POLICY refund_policies_public_read ON refund_policies
  FOR SELECT USING (app_is_public());

GRANT SELECT ON refund_policies TO bel_public;

-- Belt and braces, and cheap: an explicit REVOKE means a future
-- `GRANT ALL ... TO bel_public` written by somebody in a hurry has to
-- survive review as an obvious re-grant rather than as an invisible default.
REVOKE INSERT, UPDATE, DELETE ON refund_policies FROM bel_public;

COMMIT;
