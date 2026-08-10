-- 0016_signin_source_quota — a bound on how many codes one host may ask for.
--
-- Codes are rate-limited per *destination* today: sixty seconds between sends
-- to one address, five attempts per code. That bounds the cost of hammering
-- one inbox and bounds nothing at all about one host asking for codes to a
-- thousand different addresses — and every one of those is an email or an SMS
-- we pay for. **This is a cost control before it is a security control**, and
-- the distinction is not rhetorical: it decides how tight the limit may be.
--
-- It cannot be tight. In this market a very large share of traffic arrives
-- from behind carrier-grade NAT and from cybercafés, so one address is
-- routinely one *building*. A limit strict enough to stop a determined
-- attacker would lock out an agency, and locking out an agency to save a few
-- hundred francs of SMS is the wrong trade. What this stops is the accident
-- and the opportunist — a loop left running, a script pointed at us — which
-- is most of what actually happens.
--
-- The address is never stored. What is stored is an HMAC of it under the same
-- server-side key the codes are hashed with, so this table does not become a
-- log of who asked for a code from where, and a dump of it cannot be turned
-- back into addresses without the key.

BEGIN;

ALTER TABLE auth_challenges ADD COLUMN source_hash TEXT;

-- Null for every row written before this migration, and null in any
-- deployment where the request had no usable address at all. Counted as
-- "unknown" rather than as one bucket: lumping them together would let a
-- forged header put every anonymous caller into one shared limit.
CREATE INDEX auth_challenges_source_idx
  ON auth_challenges (source_hash, created_at DESC)
  WHERE source_hash IS NOT NULL;

COMMIT;
