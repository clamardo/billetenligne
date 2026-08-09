# BilletEnLigne — Delivery Roadmap

**Status:** v2, rewritten against what actually shipped · **Date:** 2026-08-09

Sequencing principle, unchanged and now proven: **the long poles are commercial, not technical.** Telco merchant onboarding runs 4–12 weeks and an anchor operator contract runs longer. Engineering sequences around those, never behind them — which is why the pilot below still ships without a single PSP integration.

Per-feature state, updated on every push: **[`10-build-status.md`](10-build-status.md)**.

---

## Where we actually are

```
Search → Seat map → Hold → Sign in → Book → Pay → Ticket → Board
  ✅        ✅        ✅       ✅       ⬜     ⬜      ⬜       ✅
```

Boarding is done because the scanner came early — it was the cheapest way to prove the ticket format was real. Sign-in is done as of this week, which unblocks everything to its right: until it existed, every hold in the system belonged to one demo user and nothing downstream of identity could be built honestly.

The gap is now squarely the middle: **there is no way to pay, and nobody can create a departure except by running SQL.**

**Done:** the domain, the schema with its tenancy and ledger guarantees, the public sales boundary, the API's browse-and-hold surface, phone-less email sign-in end to end, the typed client, the Kilo component library, the traveller app's funnel through to a held seat, the standalone boarding scanner, and CI that executes all of it.

456 tests · 57 smoke checks · 26 executed schema guarantees · 37 of those tests against real Postgres.

---

## Phase 0 — Foundations · **complete**

Everything after this is faster because of it, and that turned out to be true in a way worth recording: the layer check, the schema guarantees and the smoke suite each caught a real defect during Phase 1 that review had already passed over.

- ✅ Monorepo, pub workspace, CI with the layer-boundary check (ADR-0001)
- ✅ `bel_domain` — money, market, policies, seat layouts, state machines
- ✅ `bel_localization` — YAML catalog, fr + en, with the drift guards
- ✅ `bel_contracts` — the wire format
- ✅ `bel_crypto` — Ed25519 and HMAC, against published vectors
- ✅ `bel_design` — Kilo tokens, three themes, nine components
- ✅ `bel_client` — the typed API client, shared by every surface
- ✅ Postgres schema, RLS, double-entry ledger, append-only audit
- ✅ **The public sales boundary** (ADR-0023) — not in the original plan, and the single largest thing this phase learned
- ✅ Dart Frog skeleton, auth and idempotency middleware
- ✅ `infra/dev` — Postgres, Firebase emulator, Azurite, Mailpit

**Not done, and deliberately deferred:** the component gallery app. Useful for review, not on the path to a sale.

---

## Phase 1 — Cash-only pilot · **in progress**

Ships without a PSP. The point is to prove inventory, ticketing, boarding and the console while telco paperwork is in flight.

### Done

- ✅ Search, seat map, hold, release — API and app, against real Postgres
- ✅ The traveller app's browse-and-hold funnel, fr + en
- ✅ Conductor mode: offline scan, five verdicts, standalone app
- ✅ **Identity — sign in with a one-time code** (ADR-0024). Email leads, not phone: Firebase phone OTP needs a real billed project and we have no provisioned SMS sender, so we run the challenge over a rail we control and answer a correct code with a Firebase *custom token*. This is the fallback ADR-0018 already documented. Phone is a config value away — the channel is a column, an enum and a switch, and the SMS template is already written.

### Remaining, in dependency order

Each slice below is blocked by the one above it. That ordering is not a preference — it is what the data model requires.

**1. Reference data — the cities endpoint.**
Small. The traveller app's city list is currently hardcoded in `main.dart`.

**2. Operator console — the minimum that lets somebody sell.**
Sign-in and RBAC · vehicles and the cabin-section seat-layout designer · routes · schedules and departure materialisation · the guichet (cash sale over the counter, through the *same* hold path) · manifests.
*Blocks the pilot entirely: right now departures exist only because a SQL fixture created them.*

**3. Booking and cash payment.**
Convert a hold into a booking, take cash, post the double-entry ledger rows that already have their tables and their balance trigger waiting.

**4. Ticket issuing and delivery.**
The payload, the signing, the rotating code and the verifier are all built and tested. What is missing is the endpoint that issues one, the SMS that delivers it, and the printable version.

**5. Operator onboarding and admin approval.**
The admin back office, the KYB queue, approval and suspension (`03-operator-lifecycle.md`). Can trail the console: the anchor operator will be onboarded by hand.

**6. The vitrine.**
Logo, header text, accent from the closed set of eight. Cheap, and it is what makes an operator feel the platform is theirs.

**7. Refund policy wizard and cash refunds.**
The policy engine is built and tested; the wizard and the execution path are not.

**8. `services/worker`.**
Hold sweeper, expired-challenge sweeper, SMS outbox, scheduled departure materialisation. Not urgent: `claim()` already treats a lapsed hold as available and an expired challenge is refused by the write that consumes it, so nothing is stranded by its absence — this is a tidy-up, not a guarantee.

**9. Phone as the second sign-in channel, and a per-IP limit on codes.**
The channel is plumbed and switched off for want of a provisioned ACS sender number. Ships with it: codes are rate-limited per *destination* today — 60 seconds between sends, five attempts per code — which bounds the cost of hammering one address, and nothing yet bounds one host asking for codes to a thousand different addresses. Every one of those is a message we pay for, so this is a cost control before it is a security control.

**Exit:** the anchor operator sells real seats through our console for real cash, and conductors board with our scanner. *Revenue: zero. Learning: maximum.*

**In parallel, from now:** Airtel and MTN merchant paperwork, the Orange Money conversation, the anchor operator LOI. **This is the actual critical path and no amount of engineering shortens it.**

---

## Phase 2 — Mobile money

Starts the day the first production credentials land, and overlaps Phase 1 rather than following it.

- Payment orchestration and the intent state machine (`indeterminate` is a first-class state, not an afterthought)
- Airtel Money and MTN MoMo adapters, in whichever order credentials arrive
- The ledger in anger: payout runs, operator statements, commission netted at source
- The full failure taxonomy, each case with its own copy
- **The `indeterminate` queue and its reconciliation console — before launch, not after the first incident**
- **Disruption / IRROPS tooling** (`08-disruption.md`) — P0 here, because the first breakdown will happen in week one and the operator must handle it without calling us
- The `config/markets.yaml` loader, so enabling a rail is a config push rather than a release

**Exit:** a traveller pays with Airtel Money and boards. Payment success ≥ 88% first attempt.

---

## Phase 3 — Public launch

- Play Store, plus a per-ABI APK for agency sideloading
- iOS release
- Trip sharing and the follower page (ADR-0014)
- Reschedule, cancel, self-service refunds at volume
- Card via PSP, for the diaspora
- Analytics, funnel, operator reliability scores
- Offline: Drift/SQLite on device, so a ticket bought yesterday renders in a tunnel today
- Manual smoke on real SIMs, real money, real sunlight (ADR-0021 layer 5)

**Exit:** 55% search→ticket conversion · 99.5% crash-free · ≤ 2.5 s cold start on the 2 GB reference device.

---

## Phase 4 — Depth

- **Orange Money** — ~45% of the market, and the largest single growth unlock
- Section-based layouts in the console for buses, which validates the cabin-section model on a low-risk case before air needs it
- Inter-operator protection agreements at scale
- Segment selling — Brazzaville→Dolisie on a Pointe-Noire coach
- Self-serve onboarding for low-risk operators, without a human reviewer
- Sold-out alerts, rebooking from past trips
- Search pagination — today there is a hard `LIMIT 100` and no cursor, which is fine for one route on one day and stops being fine the moment the console can create a hundred departures

---

## Phase 5 — Adjacent markets

Each is a deliberate decision with a gate, not an assumption.

| Bet | Why | Gate |
|---|---|---|
| **Air** (ADR-0017) | Same manual problem, higher value per booking. The seat map already renders a two-class cabin | One design-partner carrier **and** the compliance package: ID capture, check-in, baggage, exit rows |
| **Colis / parcels** | Already an informal business on the same coaches, high margin | The anchor operator asks for it |
| **DRC** | Larger market; config plus one PSP adapter. `market_test.dart` already stands up a full DRC market in test code | Congo-Brazzaville unit economics proven |
| **River ferry** | Manual, high volume, structurally identical to bus | Opportunistic |

---

## What we are deliberately not building

Loyalty programmes · in-app chat · dynamic pricing · ETA machine learning · a traveller web booking portal · multi-leg itineraries · ride-hailing.

Each is reasonable, and each would dilute the one thing that has to be excellent first: **a traveller in Brazzaville can buy a seat with mobile money and board without an argument.**

---

## The risks that decide whether this works

| Risk | Leading indicator | Mitigation | Status |
|---|---|---|---|
| Telco merchant onboarding stalls | Weeks since application, no credentials | Phase 1 ships without it; three rails pursued in parallel | **Unmitigated — no application submitted** |
| Anchor operator does not sign | No LOI | The cash-only console is free and useful on its own; lead with that | **Unmitigated — no LOI** |
| Mobile money success below 85% | Per-rail, per-hour dashboard | Rail fallback plus an aggregator escape hatch (ADR-0006) | Deferred to Phase 2 |
| Travellers do not trust prepayment | Funnel drop at the payment screen | SMS receipts, honest scarcity, visible refund policy, cash retained | Design done; unproven |
| Disruption overwhelms support | Support tickets per disruption | IRROPS is operator self-service and P0 in Phase 2 | Designed, not built |
| **Nobody has used this on a real network** | — | Phase 3 manual smoke | Everything so far is an emulator on a fast connection |
| **Sign-in email does not arrive** | Delivery rate per hour, from day one of the pilot | Phone as a second channel — which is why it is plumbed rather than someday (ADR-0024) | **New. Email is now on the critical path of becoming a customer, and it has no fallback yet** |

The first two are commercial, and they are the ones that decide the outcome. Nothing in the engineering backlog above changes either of them.
