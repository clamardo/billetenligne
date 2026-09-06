---
name: feature-slice-refactor
description: Build or refactor one BilletEnLigne feature through its Dart domain, application ports, PostgreSQL adapters, Dart Frog routes and Flutter presentation while preserving company scope and existing contracts.
---

# One BilletEnLigne feature slice

Read the relevant `docs/` feature and ADR first, especially ADR-0001 and ADR-0004.
Use the existing repository layout; do not create a parallel architecture to match an
example from another project.

## Existing locations

| Responsibility | Location |
|---|---|
| Pure business rules and value objects | `packages/bel_domain/lib` |
| Shared wire contracts | `packages/bel_contracts/lib` |
| API orchestration and ports | `services/api/lib/src/application` |
| PostgreSQL adapters | `services/api/lib/src/infrastructure/postgres` |
| Other API adapters | `services/api/lib/src/adapters` |
| HTTP binding and authorization | `services/api/routes` |
| Composition | `services/api/lib/src/composition.dart` |
| Background processing | `services/worker` |
| Flutter surfaces | `apps/traveller`, `apps/console`, `apps/admin`, `apps/scanner` |

1. Identify one user intent and its acceptance criteria, existing callers and persisted
   state. For a company operation, trace the trusted membership-derived operator ID.
2. Put business decisions in Domain and orchestration in Application. Keep ports small
   and concerned with the use case; no SQL, Dart Frog request contexts or Flutter widgets
   in business rules. Preserve existing result/error types.
3. Implement adapters with scoped transactions and explicit atomicity. Read
   [tenant-isolation](../tenant-isolation/SKILL.md) before changing company data. Do not
   replace a company scope with platform authority to make a query work.
4. Keep routes thin: bind, authorize, call, map response. Preserve capability, station,
   traveller ownership, idempotency and error behavior. Wire dependencies in composition.
5. Update Flutter controllers/pages and wire consumers together when contracts change.
   Check traveller, console, admin, scanner and worker callers rather than assuming only
   the edited screen consumes the shape. Preserve localization and offline behavior.
6. Use a new numbered forward migration for deployed schema changes. No psql meta-commands
   in migration files: the worker applies SQL over the Dart PostgreSQL driver.
7. Test observable branching with pure Dart tests, persistence/tenancy with real PostgreSQL,
   and changed UI behavior with Flutter tests. Run `dart run tool/check_layers.dart`.
8. Remove obsolete wiring and duplicate paths after callers move. Follow
   [regression-check](../regression-check/SKILL.md), and
   [mutation-check](../mutation-check/SKILL.md) when decisions changed.

A refactor is complete when the intended behavior and existing affected behavior are
verified, dependencies still point inward, scope is preserved, and no competing old path
remains. Do not introduce business behavior changes under the label of a mechanical move.
