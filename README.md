# BilletEnLigne

**Online bus and coach ticketing for Congo.** Mobile-money first, offline-capable, bilingual.

Congo has real intercity coach demand and effectively zero digital ticketing. Today you queue at the *gare routière*, pay cash, and receive a carbon-copy ticket with no seat guarantee, no refund and no record. Meanwhile mobile money is already ~71% of non-cash transactions in the CEMAC zone.

The wedge is not the traveller — it is the operator's cash leakage. **Travellers get convenience; operators get provable revenue.**

---

## Status

**Every engineering item through Phase 4 is built.** A traveller signs in with
a one-time code, searches Brazzaville → Pointe-Noire, picks a seat off a
diagram, holds it with a countdown running, pays — cash at an agency, MTN,
Airtel or Orange Money, or a card — and gets an Ed25519-signed ticket that
renders in airplane mode. A conductor boards them from a separate app with no
network at all. An operator draws a seat layout, opens a route with its stops,
publishes a timetable, sells segments of it, works refunds and reschedules,
declares a breakdown and has another company carry their passengers. We
approve them, watch their paperwork expire, and pay them under two-person
control with the statement in their inbox.

What is left is **not code**: production credentials from three telcos and a
card processor, an Azure Communication Services sender, the two app stores,
and a manual smoke on real SIMs with real money. Track those, and everything
deliberately unfinished, in
**[`docs/10-build-status.md`](docs/10-build-status.md)** — updated on every
push, including the gaps.

| | State |
|---|---|
| Product, architecture and design docs | ✅ `docs/` |
| Architecture decision records (26) | ✅ `docs/adr/` |
| `bel_domain` · `bel_localization` · `bel_contracts` · `bel_crypto` | ✅ 603 tests |
| `bel_design` — Kilo tokens, components, contrast gates | ✅ 67 tests |
| `bel_backoffice` · `bel_secure_store` — shared sign-in, Keychain/Keystore | ✅ 16 tests |
| `bel_client` — typed API client, retries, idempotency | ✅ 41 tests |
| `services/api` — three surfaces, middleware, every route | ✅ 263 tests + 445 smoke checks |
| `services/worker` — outbox, payments, refunds, sweeps, compliance | ✅ 74 tests on real Postgres |
| Database — schema, RLS, ledger, public sales boundary | ✅ 45 guarantees verified |
| Everything against real Postgres | ✅ 505 integration tests |
| `apps/traveller` — search, seat map, pay, wallet, offline tickets | ✅ 230 tests |
| `apps/scanner` — offline boarding, signed manifest, SQLite log | ✅ 47 tests |
| `apps/console` — fleet, routes, timetables, refunds, payouts | ✅ 125 tests |
| `apps/admin` — approvals, compliance, payouts, analytics | ✅ 35 tests |
| Local dev stack, seeded demo world, VS Code debugger | ✅ `infra/dev`, `.vscode/` |
| CI — analyze, format, layers, tests, schema, integration | ✅ `.github/workflows/ci.yml` |
| Production deployment — containers, IaC, cron | ⬜ Next |

```bash
dart test packages/bel_domain                   # 2 s, no containers
dart run tool/check_layers.dart                 # onion dependency rule, 414 files
./infra/migrations/check.sh                     # 45 schema guarantees (needs Docker)
./tool/integration.sh                           # 505 tests on real Postgres
./tool/smoke_api.sh                             # 445 checks, incl. the Dart client
```

**1,427 tests in total**, plus the smoke checks, the schema guarantees, the
integration suite and 10 tests against real Azurite. The full command list is
in [`docs/10-build-status.md`](docs/10-build-status.md).

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
| **Payments** | Mobile money is the *default*, not an option | Airtel Money, MTN MoMo and Orange Money pre-selected from the phone number's prefix; card is a quiet second tab. All four rails are built and behind `config/markets.yaml`, so enabling one is a file, not a release. |
| **Language** | Dart end to end | The refund quote the traveller sees is computed by the same function the server charges with. They cannot disagree. |
| **Architecture** | Onion, dependencies inward only | Enforced by CI, not by convention. `bel_domain` has zero dependencies and runs in 2 seconds. |
| **Offline** | A product feature, not an optimisation | Tickets render in airplane mode. Boarding validation needs no network at all. |
| **Tickets** | Ed25519-signed CBOR in the QR, + a 30-second rotating code | Verifiable offline in under 2 s. The rotating code is what kills the screenshot attack. |
| **Disruption** | Operator self-service, modelled on airline IRROPS | Breakdowns are weekly here. A dispatcher on the RN1 at 04:00 cannot wait for our office to open. |
| **Policies** | Refund and reschedule rules are versioned *data* | Operators configure their own via a wizard. A booking is judged forever by the policy version it was sold under. |
| **Devices** | Android 5.0+, ≤ 15 MB APK, ≤ 2.5 s cold start on 2 GB | Enforced in CI. This is the market, not an edge case. |
| **Design** | Forêt & Latérite + Inter | Built for direct equatorial sun on a scratched 720p panel. |

Full reasoning: **[`docs/adr/`](docs/adr/)** — 26 records, each with the alternatives that were rejected and why.

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
| [`09-roadmap.md`](docs/09-roadmap.md) | Phased delivery, what remains in dependency order, and the risks that decide this |
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
│  ├─ bel_crypto/         Ed25519, HMAC, JWT, sealed secrets.
│  ├─ bel_backoffice/     sign-in and TOTP enrolment, shared by console + admin.
│  ├─ bel_secure_store/   the Keychain and the Keystore, behind one port.
│  └─ bel_client/         typed API client.
├─ apps/
│  ├─ traveller/          Flutter mobile — booking, wallet, offline tickets.
│  ├─ scanner/            Flutter mobile — boarding, offline, SQLite log.
│  ├─ console/            Flutter Web — operator.
│  └─ admin/              Flutter Web — BilletEnLigne.
├─ services/
│  ├─ api/                Dart Frog — three surfaces, middleware, routes.
│  └─ worker/             reconciliation, outbox, sweeps, compliance.
├─ infra/
│  ├─ dev/                local stack — see its README
│  └─ migrations/         schema + RLS + `check.sh`
├─ .vscode/               launch configs for every process — see below
├─ config/markets.yaml    country facts: rails, prefixes, currency
├─ tool/                  the onion rule, the suites, the dev loop
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

# The full local loop
cd infra/dev && cp .env.example .env && docker compose up -d && cd ../..
./tool/migrate.sh     # a fresh volume carries the roles and no schema
./tool/demo.sh        # five companies and twenty people on coaches
./tool/api_dev.sh     # the API on :8080, hot reload, no env to type
```

**In VS Code, none of that is typed.** `.vscode/launch.json` names every
process — the API, the worker and each of the four apps — and the compound
**Everything (API + worker + traveller)** brings up the containers, the
schema, the demo world, the server, the drain and a handset in that order,
with breakpoints in all of them. Two compounds need no containers at all: the
traveller and scanner apps on their demo gateways, which is the configuration
that works on an aeroplane.

No cloud credentials and no network are required. The Firebase project is
`demo-billetenligne`, which cannot reach the cloud, and `COMMS__CONNECTIONSTRING`
is blank by default so SMS is logged and email lands in Mailpit — nobody's
handset receives anything from your laptop.

See [`infra/dev/README.md`](infra/dev/README.md).

---

## Testing

Five layers, each answering a different question ([ADR-0021](docs/adr/0021-test-strategy.md)):

| Layer | Question | Count today | Budget |
|---|---|---|---|
| Domain and application unit | Is the rule right? | 907 | < 10 s |
| Widget / golden | Does the screen render, in fr + en, at 3 text scales? | 520 | < 90 s |
| **Integration** | Does this component talk to Postgres / Azurite / the PSP correctly? | 515 | ~2 min |
| **HTTP smoke** | Is the route mounted, and does the typed client parse it? | 445 | ~40 s |
| **Executed schema guarantees** | Does the *database* refuse what it must? | 45 | ~20 s |
| End-to-end | Can a real person complete a real journey? | — | not built |
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
