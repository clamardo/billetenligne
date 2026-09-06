# Company isolation review — 2026-09-06

BilletEnLigne already models each onboarded company as an **operator tenant**:
`operators.id` → `operator_id` on owned rows → `operatorId` in Dart → `app.tenant_id`
inside PostgreSQL transactions. Companies share a database. Markets and stations are
not tenants. There is meaningful isolation today, but **complete company isolation is
not yet established**: four database-boundary gaps were reproduced on a freshly
migrated disposable PostgreSQL 17 database.

This review adapts five project skills under `.claude/skills/` and records findings.
It does not change production code, migrations, roles, or deployed infrastructure.

## Existing protections

- Console middleware requires a `TenantScope`; identity resolution rereads accepted,
  non-revoked staff membership and requires an active operator. See
  [identity adapter](../services/api/lib/src/infrastructure/postgres/postgres_identity.dart)
  and [console middleware](../services/api/routes/console/_middleware.dart).
- [Database.transaction](../services/api/lib/src/infrastructure/db/database.dart)
  selects a surface role and sets all scope fields transaction-locally. This is the
  implementation that matters for pooled connection reuse.
- [Migration 0004](../infra/migrations/0004_rls_grants.sql) enables and forces RLS,
  including read and write checks, on foundational company tables. Later migrations
  add policies for additional features. Several child tables resolve ownership through
  a parent. Missing tenant identity hides private tenant rows under ordinary scope.
- [Migration 0005](../infra/migrations/0005_public_sales_access.sql) separates public
  sales grants and traveller ownership from company access. Admin routes require a
  platform scope; platform actions have audit mechanisms.
- Existing SQL tests exercise two-company denial cases and other shared-flow boundaries.
  Some same-company foreign keys already exist, such as station references in migration
  0028. These protections must be retained during hardening.

## Confirmed gaps

The probes ran after all migrations 0001–0045 and the existing schema checks. Assertions
used `SET LOCAL ROLE bel_app` with a company setting, matching the operator SQL role;
setup used the fixture administrator. All probe writes were rolled back. These results
demonstrate database permission/integrity failures, not a proven public HTTP exploit.

| Priority | Finding and observed result | Cause and required correction |
|---|---|---|
| High | Finance aggregate views bypass the tenant-visible ledger. Company A saw **0** base ledger rows but **4** `account_balances` rows and **1** `ledger_txn_balances` row. | Migration 0003 creates default owner-context views; 0004 grants access broadly. With the migration owner used by the test runner, views expose aggregates the caller cannot read directly. Revoke unnecessary company view access or use caller-enforced view security with tenant-safe aggregation, and test under the actual deployment owner. |
| High | `bel_app` could set `app.platform=on` and see **4** fixture routes across companies. The existing verification script also explicitly treats this flag-based widening as success. | `app_is_platform()` trusts a mutable session setting; policies are not tied to an independently authorized platform database role. Bind elevated policies to role authority, and remove platform-role switching ability from company-facing credentials if process/SQL compromise must also be contained. |
| High | Company B read a synthetic company-A replay record and deleted it: **1** row read, **1** deleted. | `idempotency_keys` has no company discriminator; `idempotency_staff` permits all non-public sessions. Its primary key is global. Add appropriate company/actor ownership, scoped unique keys and read/write policies; verify replay ownership before returning stored responses. |
| High | Company A inserted a `departure_patterns` row naming company B's route: **1** mismatched row accepted. | Independent foreign keys validate existence, not matching company ownership. Add same-company composite references (or equivalent validated constraints), after inspecting existing data, and cover other route/departure/booking/vehicle references. |

Sources: [finance view definitions](../infra/migrations/0003_payments_ledger.sql),
[RLS helper and grants](../infra/migrations/0004_rls_grants.sql),
[idempotency policy](../infra/migrations/0005_public_sales_access.sql),
[pattern foreign keys](../infra/migrations/0001_foundation.sql), and
[idempotency adapter](../services/api/lib/src/infrastructure/postgres/postgres_idempotency_store.dart).

The platform-flag probe requires control over executed SQL or an incorrect internal
scope-setting path; a console user is not shown to control it through HTTP. Likewise,
the view and replay probes prove access at the database role, without establishing a
route that returns those rows. The foreign-reference probe proves invalid ownership can
be stored, without claiming the current route validation permits that exact request.
These distinctions limit exploit claims, but do not restore the promised database safety
net when a future application predicate is missed.

## Other weaknesses and review limits

1. **Scope is not enforced end to end by types.** `OperatorConsole` methods accept plain
   strings, and `DbScope.tenant`/`platform` constructors accept identifiers rather than
   proof of authorization. The sampled routes derive the operator ID correctly from
   `TenantScope`, but a future caller can pass another source. Introduce application-owned
   authority types when hardening the ports, without importing HTTP into Application.
2. **The coverage assertion is narrower than its comments.** `verify.sql` checks RLS
   enabled on ordinary tables with an `operator_id` column. It does not verify policy
   semantics, forced RLS, views, or parent-owned/nonstandard company keys. Extend coverage
   and add behavioral tests; merely finding any policy is insufficient.
3. **Shared credentials are a residual trust boundary.** `bel_api` is NOINHERIT but can
   select public, company, admin and identity roles. `SET LOCAL` limits accidental pool
   carryover; it does not prevent arbitrary SQL from selecting another permitted role.
   Separate Flutter builds and URL prefixes do not establish separate database identities.
4. **Membership selection currently chooses the first eligible company** by invitation
   order (`LIMIT 1`). Explicit multi-company switching is not established here. Any future
   selector must verify membership server-side and partition cached/offline state.
5. **Not exhaustively reviewed:** every endpoint, storage URL, cache, export, scanner
   queue, worker, privileged function, onboarding transition, audit retention control and
   deployed role/owner configuration. No production database or production identity was
   accessed. HTTP tests and the complete API/worker integration suite were not run in this
   documentation-and-audit change.

## What strict isolation means for this marketplace

Company-private passengers, bookings, staff, KYB files, finance, internal operations and
replay payloads must remain inaccessible to other companies. Deliberately published
catalogue data remains public. Travellers can purchase from several companies while their
private records remain traveller-authorized. Platform support, payouts and workers require
explicit privileged operations. Protection agreements/rescue requests intentionally name
multiple participating companies; a third company must not gain access, and participants
must not gain unrelated private information.

These are existing product boundaries, not a reason to allow general cross-company access.
Eliminating every shared row or every authorized platform operation would change the
marketplace product; the immediate requirement is to close unintended disclosure and
modification paths while preserving narrowly authorized sharing.

## Verification and next implementation sequence

Executed `BEL_PG_CONTAINER=bel-tenancy-audit-20260906 BEL_KEEP_PG=1
./infra/migrations/check.sh`: all 45 migrations applied; the existing schema, public-sales,
identity and deferred-ledger checks passed. Additional rollback-only probes then reproduced
all four findings above. The passing existing suite therefore does not certify total isolation.

[Reproduction SQL](tenant-isolation-probes.sql) is intended only for the disposable
`belcheck` database populated by that schema runner. It reports vulnerable outcomes;
it is not a passing isolation regression suite. Do not run it against application data.

Recommended implementation order:

1. Add failing restricted-role tests for the four findings, fix finance view access and
   role-bound platform policies, and partition idempotency state.
2. Inspect existing ownership mismatches, then add forward migrations for same-company
   references. Preserve deliberate two-company protection relationships explicitly.
3. Strengthen application scope types and database coverage checks; test table/view/function
   grants, missing context and pool reuse after both success and failure.
4. Exercise authenticated A/B API probes, onboarding/revocation, third-company protection
   denial, traveller ownership, files, exports, offline queues and workers. Run
   `./tool/integration.sh` as well as the schema suite. Mutate the new denial conditions
   to prove that tests detect their removal.
5. Verify deployed migration ownership and role grants before describing deployment as
   isolated. Decide whether separate service credentials are required to contain a
   compromised company-facing process as well as ordinary application defects.

The adapted [tenant-isolation skill](../.claude/skills/tenant-isolation/SKILL.md)
captures these requirements without treating missing protections as already implemented.
