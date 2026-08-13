-- 0044_operator_active_for_identity — the console was unreachable.
--
-- Every console request begins with one question: is the person holding this
-- token staff of an operator, and is that operator still trading? It is asked
-- on the identity surface, before any tenant is known, because the answer is
-- *what tenant this is* (ADR-0011 defence #3). The lookup reads
-- `operator_staff` — which 0007 lets the identity surface read, deliberately
-- and narrowly — and then joined `operators` to check the status.
--
-- Nothing grants the identity surface a view of `operators`. Row-level
-- security does not fail loudly; it filters. So the join matched no rows, the
-- LEFT JOIN LATERAL produced a NULL membership, and every single console and
-- back-office request answered 403 to a person who was signed in correctly
-- and really was an org owner. The API tests never saw it because they build a
-- TenantScope directly, and the schema guarantees never saw it because they
-- assert what a surface *cannot* read.
--
-- The fix is not a policy on `operators`. "The identity surface may read every
-- operator row" is a real widening of the tenancy boundary, bought to answer a
-- yes/no question — and it would be the kind of GRANT that looks reasonable in
-- a diff and is load-bearing for a leak three years later.
--
-- One bit, through one function. `app_operator_is_active` is SECURITY DEFINER
-- for the same reason `app_is_applicant_for` is: the caller learns whether a
-- named operator is trading and learns nothing else — not the name, not the
-- code, not that any other operator exists. Passing an id the caller invented
-- returns false, which is all it returns for an operator that is suspended.
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION app_operator_is_active(p_operator UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM operators o
     WHERE o.id = p_operator
       AND o.status = 'active'
  )
$$;

REVOKE ALL ON FUNCTION app_operator_is_active(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_operator_is_active(UUID)
  TO bel_identity, bel_app, bel_admin, bel_public;
