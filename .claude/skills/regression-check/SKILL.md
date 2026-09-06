---
name: regression-check
description: Verify that a BilletEnLigne change preserves existing affected behavior using the repository's Dart, Flutter, HTTP smoke, PostgreSQL and storage checks. Use when finishing a change or preparing a merge or release.
---

# Verify the existing behavior as well as the change

Determine what callers and workflows could be affected, then run the relevant checks.
Record actual results, skipped tests and infrastructure failures. Test counts written in
ADRs are design targets, not evidence of a run.

`melos.yaml` defines the current commands. From the repository root:

| Change | Checks |
|---|---|
| Domain or contract logic | `melos run test:domain` and affected consumer tests |
| API orchestration, middleware or adapters | `melos run test:api` |
| Architecture/dependencies | `melos run layers` and `melos run analyze` |
| Auth, routes or composition | `melos run smoke:api`; PostgreSQL tests when database-backed |
| SQL, company scope, inventory or payments | `melos run test:schema` and `./tool/integration.sh` |
| Worker | `./tool/integration.sh` includes worker tests after API integration tests |
| Flutter UI/session behavior | `melos run test:apps`; `melos run test:scanner` for scanner |
| Shared design | `melos run test:design` plus affected apps |
| Object storage | `melos run test:storage` |

Use focused tests during implementation and broaden to relevant regression checks after
the final change. For a full PR gate, `melos run verify` is the existing aggregate, but it
does not invoke `tool/integration.sh`: run that separately when PostgreSQL adapters or
workers are affected. Docs/skill-only edits need reference/frontmatter/diff validation,
not a fictitious runtime test gate. An accompanying isolation audit can still justify
executing database checks to substantiate its findings.

## Keep the environment trustworthy

- Schema and integration scripts drop/recreate their test databases. Use dedicated
  `BEL_PG_CONTAINER` or `BEL_IT_CONTAINER` names and a free `BEL_IT_PORT`; inspect runner
  behavior before reuse. Never supply production connection strings. Do not reset the
  user's running development data to obtain a green test.
- Integration tests can skip when database configuration is absent. A successful exit
  from `dart test` with skipped database tests does not prove persistence or RLS.
- Do not run competing integrations or edits against the same test database. The runner
  serializes API integration tests and then worker tests for a reason.
- Distinguish a real assertion failure from missing SDKs, Docker permissions, occupied
  ports, dependency/network failures or a teardown error. Fix the harness when warranted;
  never change assertions just to accommodate unrelated environment failures.
- Compare against a baseline before assigning blame. Preserve user changes; use a separate
  scratch copy if needed, not a destructive reset or stash of unrelated work.

## Report evidence

Say what changed, which checks actually ran and passed, what failed/skipped, and what
remains unverified. A green schema suite is only evidence for its assertions. For tenancy,
confirm two-company denial behavior at both SQL and request boundaries; see
[tenant-isolation](../tenant-isolation/SKILL.md). For changed business/security decisions,
use [mutation-check](../mutation-check/SKILL.md) to check whether tests notice their removal.
