---
name: tenant-isolation
description: Review or change BilletEnLigne company isolation across operator membership, Dart request scopes, PostgreSQL RLS, SQL relationships, workers, and cached data. Use for tenant-owned data, company onboarding, authorization scopes, migrations, or isolation tests.
---

# Company isolation in BilletEnLigne

A tenant is one onboarded company, represented today by `operators.id`. Tenant-owned
rows usually carry `operator_id`; Dart uses `operatorId`, the authenticated principal
uses `tenantId`, and PostgreSQL uses `app.tenant_id`. A market, city, station, user,
or departure is not a company boundary. Do not substitute `market_code` for tenancy.

This is a shared PostgreSQL database with logical isolation, not a database per company.
Private company data must never become available to another company through reads,
writes, references, exports, replay responses, files, or background work.

## Read before changing the boundary

- `docs/adr/0011-tenancy-rbac-back-offices.md`: company and platform authority.
- `docs/adr/0023-public-sales-boundary.md`: traveller access.
- `docs/tenant-isolation-audit.md`: observed gaps and verification limits. Recheck the
  implementation before treating a reported gap as still open or already fixed.
- `services/api/lib/src/infrastructure/db/database.dart`: actual transaction scoping.
- `services/api/lib/src/infrastructure/postgres/postgres_identity.dart`: membership lookup.
- `infra/migrations/0004_rls_grants.sql`, `0005_public_sales_access.sql`, and subsequent
  migrations affecting the tables under review: effective policies are cumulative.

Do not interpret architecture comments as proof. `TenantScope` exists, but many ports
accept a plain `String operatorId`; `SessionVariables` in middleware is not the database
adapter's actual `DbScope.sessionVariables` implementation. Follow the executing path.

## Resolve authority before data access

Trace verified Firebase identity through the server-side account and accepted,
non-revoked staff membership on an active operator, then through console middleware
to the use case and repository. Tenant identity comes from that resolved membership,
never a body, URL, header, public departure lookup, or unverified claim.

`TenantScope` and `PlatformScope` are separate authorities. Preserve the distinction
through application ports; do not import HTTP middleware into Application just to
introduce a scope type. An application-owned authority type is preferable when improving
the existing string-based ports. Station and assigned-departure restrictions are
additional boundaries within a company, not substitutes for company isolation.

## Database reads and writes

- Use `Database.transaction` with the correct `DbScope`. Keep `SET LOCAL ROLE` and
  transaction-local `set_config(..., true)` together; reset all scope fields each time.
  Missing company context must expose no private company rows. Test pooled reuse after
  both commit and rollback, including platform-to-company transitions.
- For each new company table, add the owner discriminator, RLS read/write policies,
  explicit grants, and deliberate `FORCE ROW LEVEL SECURITY`. For a child without its
  own discriminator, prove ownership through its parent in both read and write policies.
- Check `USING` on the old row and `WITH CHECK` on the new row. A write cannot reassign
  another company's row to the caller or insert data under a foreign company.
- Scope SQL in repositories as a second layer. Parameterize values; a tenant column in
  `SET` or `RETURNING` does not constrain an update's target rows.
- Enforce same-company references with composite foreign keys or an equivalent database
  invariant. Two independent valid UUID foreign keys do not prove common ownership.
- Audit views, functions, grants, role membership, and all permissive policies. An RLS
  enabled table does not imply a view is safe, a policy filters correctly, or a client-set
  session flag is authority. Do not add another flag-only platform bypass.
- The API currently logs in as `bel_api`, which can select several surface roles. This
  is not isolation from arbitrary SQL execution or a compromised API process. Do not
  claim separate credential boundaries until they are actually implemented.

## Deliberate sharing

The marketplace intentionally publishes selected routes, fares, and operator identities.
Travellers may buy from several companies but must see only their own private bookings.
Platform support and workers have explicit cross-company responsibilities; protection
agreements and rescue requests may name two companies. These are narrow, documented
flows, never authority to browse either company's unrelated passengers or finances.

For shared flows, document participants, visible fields, permitted transitions, and
audit attribution; test an unrelated third company. Public browsing must use the public
surface, not elevate an anonymous visitor to the departure's company. Platform actions
require platform authorization and attributable audit records with a reason.

Namespace company caches, idempotency/replay state, files and offline queues by company
and any necessary actor/resource identity. Authorize before returning cached bytes or
issuing a download URL. Clear or partition handset data on account/company changes.
Workers must derive the company from trusted persisted work and validate every referenced
resource; a broad worker role is not permission for an unscoped business operation.

## Tests that prove the boundary

Use real PostgreSQL under the runtime roles, with at least companies A and B. Seed using
the fixture's privileged connection; perform assertions using the restricted app path.
Check own reads/writes succeed, foreign reads are absent, foreign writes/reparenting fail,
and refusal leaves both companies unchanged. Include missing scope, parent-child mismatch,
identical replay keys, aggregate views and alternating pooled scopes. For shared flows,
add company C and two unrelated travellers. Never count an unrelated SQL error as denial.

`./infra/migrations/check.sh` exercises schema guarantees; `./tool/integration.sh`
exercises API adapters and workers against PostgreSQL. Use dedicated disposable container
names and a free integration port. Their runners recreate databases; never point them at
a user or production database. Fast `services/api/test/tenancy_test.dart` checks scope
objects and capabilities, not actual RLS. For changes to isolation logic, apply
[mutation-check](../mutation-check/SKILL.md) and
[regression-check](../regression-check/SKILL.md).

Coverage must include parent-owned tables, nonstandard discriminators such as
`sending_operator_id`/`receiving_operator_id`, views and privileged functions. The current
schema coverage check only detects missing RLS on ordinary `operator_id` tables; do not
describe it as exhaustive policy coverage.
