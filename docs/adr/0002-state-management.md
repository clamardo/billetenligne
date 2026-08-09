# ADR-0002 — Riverpod for state management

**Status:** Accepted · **Date:** 2026-08-09

## Context

Presentation must stay thin (ADR-0001). We need: compile-safe dependency injection, easy override in tests, cancellation of in-flight searches, and cheap rebuilds on low-end devices.

## Decision

**Riverpod 2.x with code generation** (`riverpod_generator`), plus `AsyncNotifier` for anything that touches a use case.

- Riverpod providers **are** the DI container. No `get_it` service locator — a locator hides the graph and makes tests order-dependent.
- Every use case is exposed as a provider; every port is exposed as a provider overridden in tests with a fake.
- Controllers are `AsyncNotifier`s that call **exactly one** use case per method and map `Result` → UI state. Zero business rules.
- `ref.watch` with `select` on anything list-shaped, so a seat-map tap rebuilds one seat, not 60.
- `autoDispose` by default; keep-alive only where we explicitly want a cache (search results, ticket wallet).

## Alternatives considered

| Option | Verdict |
|---|---|
| **flutter_bloc** | Excellent, and the more common choice for Clean Architecture in Flutter. But event/state boilerplate is heavy for CRUD screens and it still needs `get_it` for DI. Riverpod gives DI + state in one graph. Close call; either would have worked. |
| **get_it + ChangeNotifier** | No compile-time safety, easy to leak. Rejected. |
| **GetX** | Global mutable state, encourages exactly the layering violations ADR-0001 forbids. Rejected. |
| **signals / solidart** | Promising, smaller ecosystem. Not for a system handling money. Rejected. |

## Consequences

Test setup is `ProviderContainer(overrides: [...])` — no mock frameworks needed for the graph. The team must learn Riverpod's lifecycle (the `autoDispose` + `keepAlive` interaction is the usual footgun); a `core/state/README.md` documents the three patterns we allow and nothing else.
