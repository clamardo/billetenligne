# BilletEnLigne

**Online bus and coach ticketing for Congo.** Mobile-money first, offline-capable, bilingual.

Congo has real intercity coach demand and effectively zero digital ticketing. Today you queue at the *gare routière*, pay cash, and receive a carbon-copy ticket with no seat guarantee, no refund and no record. Meanwhile mobile money is already ~71% of non-cash transactions in the CEMAC zone.

The wedge is not the traveller — it is the operator's cash leakage. **Travellers get convenience; operators get provable revenue.**

---

## Status

**Phase 0 is complete. Phase 1 has begun with the piece everything else sits
on: holding a seat.** A traveller's request now goes route → use case →
Postgres, and fifty concurrent claims for the last seat produce exactly one
ticket — proven against the lock manager that will actually arbitrate it, not
against a fake.

Per-feature detail, including what is deliberately unfinished:
**[`docs/10-build-status.md`](docs/10-build-status.md)** — updated on every push.

| | State |
|---|---|
| Product, architecture and design docs | ✅ `docs/` |
| Architecture decision records (23) | ✅ `docs/adr/` |
| `bel_domain` — money, market, policies, layouts, payment state machine | ✅ 78 tests |
| `bel_localization` — FR/EN YAML catalog | ✅ 15 tests |
| `bel_contracts` — wire format, error codes | ✅ 29 tests |
| `bel_design` — Kilo tokens + contrast gates | ✅ 38 tests |
| `services/api` — Dart Frog, middleware, **holds** | ✅ 57 tests + 27 smoke checks |
| Database — schema, RLS, ledger, public sales boundary | ✅ 23 guarantees verified |
| **Seat inventory under concurrency** | ✅ 14 integration tests on real Postgres |
| Local dev stack | ✅ `infra/dev` |
| CI — analyze, format, layers, tests, schema, integration | ✅ `.github/workflows/ci.yml` |
| Traveller app, operator console, admin back office | ⬜ Next |

```bash
dart test packages services/api                 # 241 tests, ~3 s, no containers
cd packages/bel_design && flutter test          # Kilo contrast gates
dart run tool/check_layers.dart                 # onion dependency rule
./infra/migrations/check.sh                     # 23 schema guarantees (needs Docker)
./tool/integration.sh                           # the seat race, on real Postgres
./tool/smoke_api.sh                             # 27 checks over a real socket
```

---

## What it is

Six surfaces, one domain, one language.

| Surface | Who | Built with |
|---|---|---|
| **Traveller app** | Aline, buys a seat from her phone | Flutter, iOS + Android |
| **Boarding scanner** | Pascal, boards 60 people in 10 min with no network | **Separate app**, operator-owned device |
| **Operator console** | Jean-Marc, runs 14 coaches | Flutter Web |
| **Admin back office** | Us — approvals, payments, support | Flutter Web |
| **API + workers** | | Dart Frog |
| **Follower page** | A relative tracking a trip | Plain HTML, ~50 KB |

---

## The decisions that shape everything

| | Decision | Why |
|---|---|---|
| **Market** | Congo-Brazzaville, XAF | The brief names Airtel + MTN, and MTN does not operate in the DRC. Country is configuration, not code. |
| **Payments** | Mobile money is the *default*, not an option | Airtel Money and MTN MoMo pre-selected from the phone number's prefix. Card is a quiet second tab. Orange Money (45% share) is a fast follow. |
| **Language** | Dart end to end | The refund quote the traveller sees is computed by the same function the server charges with. They cannot disagree. |
| **Architecture** | Onion, dependencies inward only | Enforced by CI, not by convention. `bel_domain` has zero dependencies and runs in 2 seconds. |
| **Offline** | A product feature, not an optimisation | Tickets render in airplane mode. Boarding validation needs no network at all. |
| **Tickets** | Ed25519-signed CBOR in the QR, + a 30-second rotating code | Verifiable offline in under 2 s. The rotating code is what kills the screenshot attack. |
| **Disruption** | Operator self-service, modelled on airline IRROPS | Breakdowns are weekly here. A dispatcher on the RN1 at 04:00 cannot wait for our office to open. |
| **Policies** | Refund and reschedule rules are versioned *data* | Operators configure their own via a wizard. A booking is judged forever by the policy version it was sold under. |
| **Devices** | Android 5.0+, ≤ 15 MB APK, ≤ 2.5 s cold start on 2 GB | Enforced in CI. This is the market, not an edge case. |
| **Design** | Forêt & Latérite + Inter | Built for direct equatorial sun on a scratched 720p panel. |

Full reasoning: **[`docs/adr/`](docs/adr/)** — 23 records, each with the alternatives that were rejected and why.

---

## Documentation

| Doc | Contents |
|---|---|
| [`00-product-brief.md`](docs/00-product-brief.md) | Market, personas, business model, risks |
| [`01-feature-spec.md`](docs/01-feature-spec.md) | Every surface, screen by screen |
| [`02-architecture.md`](docs/02-architecture.md) | Onion layers, data model, key flows, API design |
| [`03-operator-lifecycle.md`](docs/03-operator-lifecycle.md) | Onboarding, KYB, approval, vitrine, suspension, offboarding |
| [`04-payments.md`](docs/04-payments.md) | Ledger, intent state machine, rails, **billing and refunds** |
| [`05-design-system.md`](docs/05-design-system.md) | Kilo — tokens, components, accessibility gates |
| [`06-fleet-and-routes.md`](docs/06-fleet-and-routes.md) | Vehicles, cabin-section seat designer, routes, schedules |
| [`07-trip-sharing-tracking.md`](docs/07-trip-sharing-tracking.md) | Shareable trip links, live tracking tiers, maps |
| [`08-disruption.md`](docs/08-disruption.md) | IRROPS — breakdown, re-accommodation, protection |
| [`09-roadmap.md`](docs/09-roadmap.md) | Phased delivery and the five risks that decide this |
| [`10-build-status.md`](docs/10-build-status.md) | **What is built, what is half-built, and what is missing** — updated every push |

---

## Repository

```
billetenligne/
├─ packages/
│  ├─ bel_domain/         pure Dart, ZERO dependencies. Shared client + server.
│  ├─ bel_localization/   YAML i18n catalog. Shared by apps AND server.
│  ├─ bel_design/         "Kilo" design system.
│  ├─ bel_contracts/      wire DTOs + error codes.
│  ├─ bel_crypto/        Ed25519 + HMAC behind the domain's ports.
│  └─ bel_client/         typed API client.                   (planned)
├─ apps/
│  ├─ traveller/          Flutter mobile — booking, wallet.    (planned)
│  ├─ scanner/           Flutter mobile — boarding, offline.
│  ├─ console/            Flutter Web — operator.             (planned)
│  └─ admin/              Flutter Web — BilletEnLigne.        (planned)
├─ services/
│  ├─ api/                Dart Frog — middleware, routes.
│  └─ worker/             reconciliation, outbox, sweeps.     (planned)
├─ infra/
│  ├─ dev/                local stack — see its README
│  └─ migrations/         schema + RLS + `check.sh`
├─ config/markets.yaml    country facts: rails, prefixes, currency
├─ tool/check_layers.dart the onion rule, enforced
└─ docs/                  product, architecture, ADRs
```

`bel_domain` is the asset: the only package with no dependencies at all, compiled into both the apps and the server, and the most heavily tested code we own.

---

## Getting started

```bash
git clone <repo> && cd billetenligne
dart pub get

# Domain work needs no containers at all
dart test packages/bel_domain

# Full local stack: Postgres, Firebase Auth emulator, Azurite, Mailpit
cd infra/dev && cp .env.example .env && docker compose up
```

No cloud credentials and no network are required. The Firebase project is `demo-billetenligne`, which cannot reach the cloud, and `COMMS__CONNECTIONSTRING` is blank by default so SMS is logged and email lands in Mailpit — nobody's handset receives anything from your laptop.

See [`infra/dev/README.md`](infra/dev/README.md).

---

## Testing

Five layers, each answering a different question ([ADR-0021](docs/adr/0021-test-strategy.md)):

| Layer | Question | Count | Budget |
|---|---|---|---|
| Domain unit | Is the rule right? | ~2000 | < 5 s |
| Widget / golden | Does the screen render, in fr + en, at 3 text scales? | ~400 | < 60 s |
| **Integration** | Does this component talk to Postgres / Firebase / the PSP correctly? | ~250 | ~2 min |
| ↳ *running today* | Does one seat go to exactly one of fifty simultaneous buyers? | 14 | ~3 s |
| **End-to-end** | Can a real person complete a real journey? | ~40 | ~15 min |
| Manual smoke | Real SIM, real money, real sunlight | — | pre-release |

Integration and E2E are deliberately **separate**: one names the broken component, the other tells you the journey is broken. Merged, you get E2E's flakiness with integration's volume. They share fixtures and the emulator stack — that is where the reuse belongs.

---

## Contributing rules that are enforced, not suggested

- `bel_domain` imports **nothing** — not Flutter, not `dart:io`, no packages.
- `presentation/` never imports `infrastructure/`.
- No raw `Color(0x…)`, magic `EdgeInsets` number or `TextStyle` literal outside `bel_design`.
- No hardcoded user-facing string. Every one goes through the YAML catalog.
- Every money amount is rendered by `Money.format(locale)`. No exceptions.
- Every screen defines loading, empty, error, offline **and** success. Four out of five is not done.
- French is the source language. Design against the French string — it runs 15–25% longer.
