-- 0014_refund_policies — the policy a booking is judged by, forever.
--
-- The table has existed since 0003 and nothing has ever written to it. Every
-- booking sold so far carries a NULL `refund_policy_id`, which means the one
-- rule ADR-0015 calls the most important — "a booking stores the version it
-- was sold under and is judged by that version forever" — has been true only
-- because no refund has ever been issued.
--
-- Two changes make it real.
--
-- **An operator has a default policy, and it is a foreign key to a version.**
-- Not to a policy: to `(id, version)`. A booking copies both columns at sale
-- time, and the composite reference is what makes "the version it was sold
-- under" a thing the database can still resolve in two years, rather than a
-- pair of numbers pointing at whatever the policy has since become.
--
-- **Policies become append-only by grant, not by convention.** A comment
-- saying "immutable and versioned" is a comment; `REVOKE UPDATE` is a rule.
-- A new version is an INSERT with the same id and the next version number,
-- which is exactly what the console does — and an UPDATE that would have
-- silently rewritten yesterday's customer's entitlement now raises instead.
--
-- The migration deliberately does NOT backfill a default onto existing
-- operators. A refund policy is a commercial term somebody agreed to; picking
-- one on their behalf and stamping it onto their next sale is inventing a
-- contract. Operators with no default sell exactly as they do today, with a
-- NULL policy and no self-service refund, until somebody chooses one.

BEGIN;

ALTER TABLE operators
  ADD COLUMN default_refund_policy_id      UUID,
  ADD COLUMN default_refund_policy_version INTEGER,

  -- Both or neither. Half a reference is a policy id nobody can resolve.
  ADD CONSTRAINT operators_default_policy_complete CHECK (
    (default_refund_policy_id IS NULL) = (default_refund_policy_version IS NULL)
  ),

  ADD CONSTRAINT operators_default_policy_fk
    FOREIGN KEY (default_refund_policy_id, default_refund_policy_version)
    REFERENCES refund_policies (id, version)
    -- RESTRICT rather than SET NULL: a policy that is somebody's default
    -- cannot be deleted out from under them, and since policies are now
    -- append-only this can only fire for a platform-level mistake.
    ON DELETE RESTRICT;

-- The console lists an operator's policies on every visit to the screen.
CREATE INDEX refund_policies_operator_idx
  ON refund_policies (operator_id, id, version DESC);

-- ── Immutable, by grant ─────────────────────────────────────────────────────

REVOKE UPDATE, DELETE ON refund_policies FROM bel_app, bel_admin;

CREATE TRIGGER refund_policies_append_only
  BEFORE UPDATE OR DELETE ON refund_policies
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

COMMIT;
