# BilletEnLigne — Delivery Roadmap

**Status:** Draft v1 · **Date:** 2026-08-09

Sequencing principle: **the long poles are commercial, not technical.** Telco merchant onboarding runs 4–12 weeks and an anchor operator contract runs longer. Engineering sequences around those, never behind them.

---

## Phase 0 — Foundations (weeks 1–3)

Nothing user-visible. Everything after this is faster because of it.

- Monorepo, Melos, CI with the layer-boundary lint (ADR-0001)
- `bel_domain`: Money, policies, seat layouts, state machines — with the property tests ✅ *started*
- `bel_localization`: YAML catalog, fr + en ✅ *started*
- `bel_design`: Kilo tokens, first components, gallery app
- `infra/dev`: Postgres, Firebase emulator, Azurite, Mailpit ✅ *started*
- Postgres schema + RLS + migrations
- Dart Frog skeleton, auth middleware, idempotency middleware

**In parallel, from day one — these are the real critical path:**
- Airtel Money + MTN MoMo merchant onboarding paperwork started
- Orange Money commercial conversation opened (ADR-0006)
- Anchor operator LOI signed

**Exit:** a developer clones, runs `docker compose up`, and the domain suite is green in 2 seconds.

---

## Phase 1 — Cash-only pilot (weeks 4–9)

Ships without a single PSP integration. This is deliberate: it proves inventory, ticketing, boarding and the console while telco paperwork is still in flight.

- Operator onboarding + admin approval queue (`03-operator-lifecycle.md`)
- Vehicle, seat layout designer, routes, schedules (`06-fleet-and-routes.md`)
- Vitrine — logo, header, accent
- Traveller app: onboarding, search, seat map, hold, **cash payment**, ticket + QR, printable
- Conductor mode: offline scan, all five verdicts
- Operator console: guichet (cash sale), manifests, staff, RBAC
- SMS + push on the ACS/Firebase rails
- Refund policy wizard + refund execution for cash

**Exit:** the anchor operator sells real seats through our console for real cash, and conductors board with our scanner. **Revenue: zero. Learning: maximum.**

---

## Phase 2 — Mobile money (weeks 8–14, overlapping)

Starts the day the first set of production credentials lands.

- Payment orchestration, intent state machine, reconciliation console
- Airtel Money and MTN MoMo adapters, in whichever order credentials arrive
- Double-entry ledger, payout runs, operator statements
- The full failure taxonomy with its own copy per case
- `indeterminate` queue + reconciliation tooling **before launch, not after the first incident**
- Disruption / IRROPS tooling (`08-disruption.md`) — **P0, because the first breakdown will happen in week one**

**Exit:** a traveller pays with Airtel Money and boards. Payment success ≥ 88% first attempt.

---

## Phase 3 — Public launch (weeks 14–18)

- Play Store + per-ABI APK for agency sideloading
- iOS release
- Trip sharing + follower page (ADR-0014)
- Reschedule, cancel, self-service refunds at volume
- Card via PSP (diaspora)
- Analytics, funnel, reliability scores
- Manual smoke on real SIMs, real money, real sunlight (ADR-0021 layer 5)

**Exit:** 55% search→ticket conversion, 99.5% crash-free, ≤ 2.5 s cold start on the 2 GB reference device.

---

## Phase 4 — Depth (months 5–8)

- **Orange Money** — 45% of the market, and the largest single growth unlock
- Section-based layouts in the console for buses (validates ADR-0017 on a low-risk case)
- Inter-operator protection agreements at scale
- Segment selling (Brazzaville→Dolisie on a Pointe-Noire coach)
- Operator self-serve onboarding without a human reviewer for low-risk applications
- Sold-out alerts, rebooking from past trips

---

## Phase 5 — Adjacent markets (months 8–12)

Each is a deliberate decision, not an assumption.

| Bet | Why | Gate |
|---|---|---|
| **Air** (ADR-0017) | Same manual problem, higher value per booking | One design-partner carrier + the compliance package (ID capture, check-in, baggage, exit rows) |
| **Colis / parcels** | Already an informal business on the same coaches, high margin | Anchor operator asks for it |
| **DRC** | Larger market; config + one PSP adapter | Congo-Brazzaville unit economics proven |
| **River ferry** | Manual, high volume, structurally identical to bus | Opportunistic |

---

## What we are deliberately not building

Loyalty programmes · in-app chat · dynamic pricing · ETA machine learning · a traveller web booking portal · multi-leg itineraries · ride-hailing.

Each is a reasonable idea and each would dilute the one thing that has to be excellent first: **a traveller in Brazzaville can buy a seat with mobile money and board without an argument.**

---

## The five risks that decide whether this works

| Risk | Leading indicator | Mitigation |
|---|---|---|
| Telco merchant onboarding stalls | Weeks since application, no credentials | Phase 1 ships without it; three rails pursued in parallel |
| Anchor operator does not sign | No LOI by week 3 | Cash-only console is free and useful on its own — lead with that |
| Mobile money success rate below 85% | Per-rail, per-hour dashboard | Rail fallback + aggregator escape hatch (ADR-0006) |
| Travellers do not trust prepayment | Funnel drop at the payment screen | SMS receipts, honest scarcity, visible refund policy, cash option retained |
| Disruption handling overwhelms support | Support tickets per disruption | IRROPS is operator self-service and P0 (ADR-0016) |
