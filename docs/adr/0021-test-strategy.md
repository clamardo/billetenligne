# ADR-0021 — Test strategy: integration and end-to-end, and why they are separate

**Status:** Accepted · **Date:** 2026-08-09 · **Related:** ADR-0001, ADR-0020

## Context

This system moves other people's money, holds inventory that physically cannot be oversold, and issues tickets that must verify offline on a roadside. The cost of a wrong answer is not a bad user experience — it is a passenger who paid and cannot board.

The question raised was whether integration and end-to-end tests can be one thing. They cannot, and the reason is worth writing down: **they fail for different reasons and they answer different questions.** An integration test tells you *which component is broken*. An E2E test tells you *whether a real user can complete a real journey*. A suite that tries to be both is slow, flaky, and diagnoses nothing.

## Decision

Five layers. Each has a distinct question, a distinct speed budget, and a distinct trigger.

```
        ▲  fewer, slower, more real
        │
   ┌────┴─────────────────────────────────────────────────────┐
   │ 5 · Manual smoke        real device, real SIM, real money │  pre-release
   ├──────────────────────────────────────────────────────────┤
   │ 4 · End-to-end          real app ↔ real API ↔ emulators   │  ~40 · pre-merge
   ├──────────────────────────────────────────────────────────┤
   │ 3 · Integration         one component ↔ real Postgres/PSP │  ~250 · pre-merge
   ├──────────────────────────────────────────────────────────┤
   │ 2 · Widget / golden     one screen, fake use cases        │  ~400 · pre-merge
   ├──────────────────────────────────────────────────────────┤
   │ 1 · Domain unit         pure Dart, zero I/O               │  ~2000 · on save
   └──────────────────────────────────────────────────────────┘
        │
        ▼  more, faster, more isolated
```

### 1 · Domain unit — `dart test packages/bel_domain`

Pure Dart, no containers, **whole suite under 5 seconds**. This is where the rules live, so this is where most tests live: money arithmetic and allocation, refund and reschedule quoting, seat layout generation, MSISDN parsing, payment state transitions, policy versioning.

Heavy on **property-based tests** for the invariants that must never break under any input:

- Any split of any amount sums exactly back to the original
- A refund never exceeds what was captured
- `hold TTL > payment window`, for every configuration
- Ledger entries sum to zero across all accounts, after any sequence of operations

Runs on file save. If it is slow, it is in the wrong layer.

### 2 · Widget and golden — `flutter test`

One screen with faked use cases. Every component and key screen rendered across **light / dark / plein-soleil × fr / en × text scale 0.85 / 1.0 / 1.3** (ADR-0010). Goldens are the contract that stops the design system drifting on a small team, and they are the only practical defence against French strings overflowing an English-designed button.

Mandatory goldens: ticket, seat map, payment waiting screen (per rail), all five conductor verdicts, disruption banner, refund quote.

### 3 · Integration — real infrastructure, one component at a time

Runs against the ADR-0020 emulator stack with `BEL_TEST_RUN=true`, so every store is ephemeral. Question answered: *does this component talk correctly to the thing it depends on?*

| Area | What is actually exercised |
|---|---|
| Repositories | Real Postgres, real migrations, **real RLS policies** — a tenancy test that stubs the database tests nothing |
| Inventory | Concurrent `HoldSeats` against one seat row. Property: **N concurrent holds → exactly 1 winner**, run at N=50 |
| Payments | `FakePaymentGateway` producing every terminal state **plus** lost callback, duplicate callback, out-of-order callback, callback after timeout, callback for an unknown reference, capture after hold expiry |
| Idempotency | Replaying any key returns a byte-identical response and writes **zero** new ledger rows |
| Auth | Real Firebase emulator: token issue, custom claims, expiry, revocation, conductor custom tokens |
| Notifications | `FakeNotificationGateway`: correct template, correct language, correct channel, no double-send on a retried drain |
| Ticketing | Sign with a test key, verify offline, tamper-detect, rotating-code freshness, key rotation |
| Storage | Real Azurite: KYB upload, operator logo, PDF round-trip |

**A rail is not production-ready until its full integration matrix passes.** That sentence is the contract with the payments subsystem.

### 4 · End-to-end — the real app against the real API

`integration_test` driving the actual Flutter app against the actual Dart Frog API against the ADR-0020 stack. No mocks anywhere in the app or the API; only the PSP is faked, because there is no sandbox that can be driven deterministically at CI speed.

Question answered: *can a real person complete a real journey?* Kept to ~40 scenarios — the journeys that, if broken, mean we have no business:

1. Fresh install → language → search → seat → phone → OTP → MoMo pay → ticket with QR
2. Same, ending in each distinct payment failure, with the correct recovery offered
3. Payment goes `indeterminate` → seat stays held → later capture → ticket issued → SMS sent
4. **Hold expires mid-payment → capture succeeds → auto-refund** (rare, ugly, must work)
5. Reschedule inside the free window, and outside it with the fee shown before commitment
6. Cancel → refund quote matches what actually arrives → ledger balances
7. Refund with `agency_cash` destination → claim QR → vendor redeems against till
8. **Conductor scans a valid ticket with the network disabled** → VALIDE under 2 s
9. Scan the same ticket twice → DÉJÀ EMBARQUÉ with the first scan time
10. Scan a screenshot with a stale rotating code → CODE PÉRIMÉ
11. Scan a ticket for another departure → MAUVAIS DÉPART
12. Dispatcher declares a breakdown → rebooking wave applies to 42 bookings → every passenger notified and holds a valid ticket
13. Passenger self-selects a different option from the disruption screen; the released seat returns to the pool
14. Operator onboarding: apply → KYB → approve → configure vehicle + layout + route + policy + vitrine → first sale
15. Vendor sells for cash → claim QR → traveller scans → ticket lands in their wallet
16. Cross-tenant probe: operator A's console **cannot** read operator B's data, at the API *and* at RLS
17. Every screen in `fr` and `en` at 1.3× text scale, no overflow

Scenario 4, 8, 12 and 16 are the ones that justify the whole layer.

### 5 · Manual smoke — before every release

The things no emulator can prove: a real handset on a real Congolese SIM, a real Airtel Money and MTN MoMo payment of a small real amount, a real refund, a printed ticket scanned from paper, and a scan in direct sunlight on a low-end device. **Cold start and APK size measured on the 2 GB reference device**, in profile mode, on device.

Documented as a checklist in `docs/release-checklist.md`, signed off by a name.

### Why the two cannot merge

| | Integration | End-to-end |
|---|---|---|
| Question | Does this component talk to its dependency correctly? | Can a user complete a journey? |
| Scope | One component, real infrastructure | Everything, real app |
| Count | ~250 | ~40 |
| Runtime | ~2 min | ~15 min |
| On failure | Names the broken component | Tells you the journey is broken; you then look at layer 3 |
| Flakiness | Low | Inherently higher — real UI, real timing |

Merging them yields a suite with E2E's flakiness and integration's volume, which is the worst available trade. They share the **fixtures, the seeder and the emulator stack** — that is where the reuse belongs, not in the assertions.

## CI

| Trigger | Layers | Budget |
|---|---|---|
| On save (local) | 1 | < 5 s |
| Pre-commit hook | 1, 2 | < 60 s |
| Pull request | 1, 2, 3, 4 | < 20 min |
| Nightly | all + concurrency soak + APK size + cold start | — |
| Pre-release | 5 | manual |

Coverage gates: **`bel_domain` ≥ 95%** (it is pure logic with no excuse), payments and ticketing ≥ 90%, everything else ≥ 70%. Coverage is a floor, not a goal — a 100%-covered refund engine with no property test for "refund ≤ captured" is worse than an 80%-covered one that has it.

## Consequences

Layer 3 and 4 need the ADR-0020 stack in CI, which means Docker in the runner and a slower pipeline than a pure unit suite. Accepted without argument: the alternative is discovering a double-charge in production.

The `FakePaymentGateway` and the seeder are **first-class deliverables**, owned and reviewed like production code. Most of the value in layers 3 and 4 comes from how faithfully those two things model reality.
