-- 0012_platform_staff_reads — the admin surface becomes reachable.
--
-- `platform_staff` has existed since 0001 and nothing has ever read it, which
-- means `Principal.isPlatform` has been false for every request this system
-- has ever served and `/admin/v1` could not have worked if it existed. This
-- migration is the missing half: the same lookup that answers "who is this,
-- and which operator do they work for" now also answers "…and are they one of
-- ours".
--
-- The reasoning is 0009's, unchanged. Resolving a bearer token happens BEFORE
-- the request has a surface, because its result is what decides which surface
-- the request gets — so the read cannot live in the admin scope it would be
-- authorising. `bel_identity` gains SELECT on one more table that carries no
-- money and no inventory, and gains nothing else: it still cannot grant a
-- role, revoke one, or sell a seat.
--
-- What this deliberately does NOT do is let the identity surface *write* a
-- platform role. Granting our own staff their authority is an administrative
-- act with an audit trail; reading it is not, and the two must not share a
-- role.

BEGIN;

GRANT SELECT ON platform_staff TO bel_identity;

REVOKE INSERT, UPDATE, DELETE ON platform_staff FROM bel_identity;

ALTER TABLE platform_staff ENABLE ROW LEVEL SECURITY;

CREATE POLICY platform_staff_identity_read ON platform_staff
  FOR SELECT USING (app_is_identity());

-- The admin surface reads its own roster — the "who else can approve this"
-- question a four-eyes rule will ask — and cannot alter it either. Adding or
-- removing our own staff is a migration or a break-glass session as
-- `postgres`, on purpose: it is the one privilege escalation that would make
-- every other control here decorative.
CREATE POLICY platform_staff_admin_read ON platform_staff
  FOR SELECT USING (app_is_platform());

GRANT SELECT ON platform_staff TO bel_admin;
REVOKE INSERT, UPDATE, DELETE ON platform_staff FROM bel_admin;

COMMIT;
