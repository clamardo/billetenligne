# BilletEnLigne — Delivery Roadmap

**Status:** v2, rewritten against what actually shipped · **Date:** 2026-08-10

Sequencing principle, unchanged and now proven: **the long poles are commercial, not technical.** Telco merchant onboarding runs 4–12 weeks and an anchor operator contract runs longer. Engineering sequences around those, never behind them — which is why the pilot below still ships without a single PSP integration.

Per-feature state, updated on every push: **[`10-build-status.md`](10-build-status.md)**.

---

## Where we actually are

```
Search → Seat map → Hold → Sign in → Book → Pay → Ticket → Board
  ✅        ✅        ✅       ✅       ✅     ✅      ✅       ✅
```

**Phase 1 is functionally complete.** A traveller signs in with an emailed code, holds a seat, names their passengers, gets a payment code, walks into an agency, a vendor takes the cash at a real till, the ledger balances, a signed ticket is issued and queued for delivery, and a conductor scans it offline. An operator draws a seat layout, adds a coach, opens a route, publishes a timetable and prints a manifest — in a browser, with no curl anywhere.

Every step of that is executed by a test, most of them against real Postgres.

What remains before a pilot is **commercial, not technical**, which is what this roadmap said in its first line and is now literally true: an anchor operator has to sign, and somebody has to sit with them while they configure their fleet.

**Done:** the domain, the schema with its tenancy and ledger guarantees, the public sales boundary, the whole traveller API surface, email sign-in, booking and cash payment with double-entry postings, ticket issuing, the operator console's API, `services/worker`, the typed client, the Kilo component library, the traveller app through to a payment code, the standalone boarding scanner, and CI that executes all of it.

791 tests · 186 smoke checks · 32 executed schema guarantees · 165 further tests against real Postgres, and 10 against real Azurite.

(That total read 1,091 in an earlier revision. The number was wrong, not the suite: `dart test services/api` had been counted with `services/api/build` present, so `dart_frog build`'s copy of every package was counted a second time. `10-build-status.md` records the correction.)

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

### Also done since
- ✅ **The admin surface** (`/admin/v1`) — operator queue, operator page, approve · activate · request info · reject · suspend · reinstate, and the per-operator commission. `platform_staff` is finally read, which it never had been
- ✅ **Tickets and history in the app** — the QR, the live 30-second code, one ticket per seat, and unpaid reservations listed with the code to pay them. The receipt's "see my ticket" button now shows a ticket rather than returning to a search box
- ✅ **Cities from the server**, so the app holds no copy of an operator's network
- ✅ **Booking and cash payment** — reserve, collect, post the ledger, issue the ticket, all in one transaction
- ✅ **Ticket issuing** — Ed25519, under 300 bytes, inside the capture
- ✅ **The operator console's API** — fleet, routes, timetables and the materialisation the pilot was blocked on
- ✅ **`services/worker`** — the outbox drain that delivers a ticket, the payment poller, the sales horizon, and three sweepers that are deliberately not guarantees
- ✅ **The operator console** — Flutter web: fleet, routes, timetables, the dispatcher's day, the guichet, manifests
- ✅ **The vitrine** — title, tagline, accent from the closed set of eight and a header pattern, with a live preview drawn by the real widgets, plus the public storefront behind `blt.cg/o/<code>` — and now the logo, with the object storage it needed. What we accept is decided by the **bytes**, never by the header a caller sent, and it is a cap rather than a downscale: re-encoding somebody's brand mark is a silent change to the one asset they care about most, so 40 KB and 512 px are refused with the number to get under rather than resampled behind their back
- ✅ **The admin back office** — Flutter web: the review queue, one operator's file with its documents and trail, the six decisions, the negotiated commission, and the `indeterminate` reconciliation queue with its three exits. The stated reason lives in the frame and nothing writes without one
- ✅ **TOTP on both back-office surfaces** (ADR-0013) — RFC 6238, proved against the RFC's own Appendix B vectors before a line of the flow existed. Taken ahead of logo upload because it is a control on a live cross-tenant surface and needed no infrastructure that did not already exist. Three decisions worth restating: **travellers are never asked** (a second factor in front of a coach ticket protects one person's own bookings); **enrolment is not enforced by refusing to sign in** — staff with nothing enrolled get a session and land on the enrolment screen and nowhere else, because the alternative locked out every existing staff account the hour it shipped; and the half-session between the emailed code and the authenticator code is a **signed claim, not a row**. The flow lives in `bel_backoffice` so the console and the admin app cannot drift into asking differently
- ✅ **The seat-layout section builder** — the coach no preset fits, drawn section by section, with the traveller's own seat map redrawn on every keystroke. Three inputs that used to be **500s** are now field-named 400s: `abreast: "abc"` threw out of a capacity getter, `9+9` walked off the end of the seat-letter table, and a hundred-thousand-row section asked the server to build a hundred thousand labels before writing every one of them. The rule about what a seat arrangement may be now lives in `bel_domain` as a parser that returns null instead of throwing, so the console asks the same question the server does and disables the save button with a reason rather than enabling it into a refusal. Not built, and named in `06-fleet-and-routes.md` §3.3 rather than implied: tap-to-cycle blocked cells, placing doors and lavatories, reordering sections, undo/redo — the model already carries all of it, so what is missing is the gesture
- ✅ **Refund terms and cash refunds** (ADR-0015) — the policy engine has been built and tested since week one and had never refunded anybody. Now: a wizard where the operator answers questions and the **domain writes the sentences**, so the terms a traveller reads before paying are generated from the numbers the server executes; policies append-only **by grant**, with `(policy_id, version)` copied onto every booking at sale time; and the counter path — quote, approve, collect. A refund **moves a debt** rather than undoing a sale, so the share the policy retained stays credited to the operator where they earned it. The ticket voids at approval and the seat goes back on sale in the same transaction; the claim code is single-use because the state moves in the statement that reads it. Not built and named rather than implied: `source` — disbursement back down a mobile-money rail — is a different API with a separately funded float, so it stops at `approved` and posts the debt without moving money
- ✅ **Scheduled materialisation in the worker** — the sales horizon extends itself. A rolling twenty-one days of inventory, filled by a pass that enumerates every active pattern of every active operator under the worker's own platform scope and then materialises each one back under its tenant, so the pass can *see* across tenants and can still only *write* inside one. Idempotent on the key the console's button already relies on, which is what makes a half-finished run safe to simply run again. Two refusals are deliberate: a **suspended** operator gains no new inventory, because inventory that cannot be boarded is worse than none; and a batch that hits its limit says **`more due`** in the pass name rather than finishing quietly, because a scheduler running nightly against a hundred operators should see a backlog as a number, not as travellers who cannot book three weeks out. Still by hand and named rather than implied: **nothing invokes the worker on a timer yet** — that is a cron trigger in the deployment environment, not a line of Dart
- ✅ **Operator onboarding as a wizard** (§2.2) — the first row in `operators` no longer arrives by SQL. The shape that mattered: **the application *is* the operator**, in the early lifecycle states the spec already names, so the review queue, the audit trail and the six decisions all keep working rather than being rebuilt for a second entity. The applicant is a **member of the public** — a traveller session, no tenant, writing into the table that defines tenancy — so the boundary is column-level rather than a handler that remembers: INSERT pinned by policy to `application_draft`, UPDATE granted on four columns, and the one transition an applicant genuinely causes routed through a SECURITY DEFINER function whose body is one UPDATE and the audit row they have no grant to write. **Activation creates the `org_owner`**, which is the line that removes the phone call — before it, "approved" still meant somebody ran an INSERT by hand. The checklist is one function in `bel_domain`: the applicant's progress bar, the reviewer's list of gaps and the server's refusal to accept a half-filled submission are three readings of it. Not built and named rather than implied: **document photographs**. The scans belong in `kyb_documents`, the public role has no grant on it, and `verify_public.sql` refuses to let one be added — so what the wizard takes is the pair §3.3 enforces against, a number and an expiry, and a reviewer collects the images by asking. The agreement is an acceptance with a timestamp, not a countersigned PDF
- ✅ **A bound on how many codes one host may ask for**, and the switch that turns the phone channel on — the engineering half of Phase 1's last item. The per-destination cooldown is real and cannot see the shape that actually costs money: one host walking a list of a thousand addresses never triggers it once, and every one of those is an email or an SMS we pay for. Thirty per hour per source now, env-tunable, and **deliberately loose** — carrier-grade NAT means one address in this market is routinely one *building*, so a bound tight enough to stop a determined attacker would lock out an agency counter. It is a **cost control before it is a security control**, and saying so is what decides the number. Two details are load-bearing: the address is never stored, only an HMAC of it under the same key the codes are hashed with, so the table cannot become a log of who asked from where; and the source is the **rightmost** `X-Forwarded-For` hop rather than the leftmost, because the leftmost is whatever the caller felt like typing. Alongside it, `/public/v1/market` now announces which channels the deployment can actually deliver on and the traveller app renders the option from that announcement — so the day a sender number is provisioned is a config push rather than a release (ADR-0006), in a market where a large share of users never update. What remains is the number itself, which is a purchase

### Remaining, in dependency order

**Nothing.** Every engineering item on this phase's list is built. What is left is commercial: an ACS sender number for SMS, telco merchant onboarding, and an anchor operator's signature.

The unbuilt engineering has moved to Phase 2, where it belongs: the re-accommodation plan, payout runs, and the `config/markets.yaml` loader.

**Stated, not hidden.** The **phone channel has no sender number**, so the API answers 503 for it and the market announces `email` alone. Everything behind it — the challenge, the template, the drain, the app's own control — is built and switched off by config rather than by a missing code path. An application collects **no document photographs** — the numbers and the expiry dates, which is what §3.3 actually enforces against, and a reviewer asks for the images. That is a schema guarantee rather than a shortcut: the public role has no grant on `kyb_documents` and `verify_public.sql` refuses to let one be added. The worker's nightly run is a **cron trigger that does not exist yet** — the horizon pass is built, tested and idempotent, and until something invokes it on a schedule the far edge of the sales window moves when somebody runs the worker. A refund to `source` — back down the rail it was paid on — posts the debt and stops there; only the cash counter path completes, which is what the anchor operator actually needs and is the honest half to have built first. The section builder has no tap-to-cycle for blocked cells, no way to place a door or a lavatory, no reordering and no undo — the storage format carries all four and everything downstream honours them, so what is missing is the gesture, not the model (`06-fleet-and-routes.md` §3.3). There is **no QR code** on the TOTP enrolment screen — a QR encoder is a few hundred lines of Reed–Solomon and this repository has no independent decoder to check one against, so a bug would ship as a code that scans cleanly and produces a factor that never matches; the setup key is typed instead, which every authenticator app accepts. The TOTP **seed is not encrypted at rest**: a KMS key living in the same environment as the database is reassurance rather than a control. And a **cover photo** can be uploaded by the API but has no control in the console — the storefront was designed to look complete without one, and building the picker for a field most operators will never fill was not worth the slice.

**Exit:** the anchor operator sells real seats through our console for real cash, and conductors board with our scanner. *Revenue: zero. Learning: maximum.*

Everything that exit requires is now built. What is left is a signature.

**In parallel, from now:** Airtel and MTN merchant paperwork, the Orange Money conversation, the anchor operator LOI. **This is the actual critical path and no amount of engineering shortens it.**

---

## Phase 2 — Mobile money · **built, awaiting credentials**

The engineering is done. What is missing is a merchant agreement, which is the long pole this roadmap has said it was from the first line.

- ✅ Payment orchestration and the intent state machine (`indeterminate` is a first-class state, with a queue, a worker pass and a screen that does not call it a failure)
- ✅ **Airtel Money and MTN MoMo adapters**, both against the real APIs. Independent, so whichever set of credentials lands first ships first
- ✅ The in-app experience end to end: choose a wallet, name the number to debit (**not necessarily your own**), confirm where the money is going, watch for the PIN prompt, receipt
- ✅ Operator collection accounts in the console, saved unverified because mobile money has no chargeback
- ✅ The poller, because callbacks get lost — that is a fact about these networks, not a hypothetical
- ✅ **Commission netted at source, at the rate each operator negotiated** — a term of one contract, read from their row when the fare settles, in basis points. Not a market rate and not a constant: the number a large carrier argues for is not the one a two-coach family business gets
- ✅ The full failure taxonomy, each case with its own copy and its own recovery
- ⬜ **Production credentials.** Both adapters run against sandbox hosts today and a fake rail in development
- ✅ **The `indeterminate` reconciliation console — before launch, not after the first incident.** The queue is joined to the booking, the operator and a number to call, with three exits (ask the rail again · captured · failed) and the actor and reason written to the append-only event log. It is a screen in the back office now, and the two terminal exits refuse to fire without a sentence about what was actually seen
- ✅ **Disruption, declared and told** (`08-disruption.md` §1–§4) — the dispatcher declares one of six kinds and everything downstream is derived: the departure's new status, the exemption on every affected booking, one message per passenger, in their own language, from the outbox rather than inline with a roadside request. All of it in **one transaction**, because bookings marked involuntary with no declaration behind them is a refund entitlement nobody can account for. Three properties are load-bearing: a disruption is **public** — the follower of a shared trip link holds no account and is exactly the person who otherwise phones the agency; it is **not editable afterwards**, by a column-level grant rather than a promise, because it is the operator's evidence in a dispute; and there is **one open disruption per departure**, by a partial unique index, so "what is happening to my coach right now?" has exactly one answer. A **short delay entitles nobody to anything** — an hour is the line, it lives in the domain, and the console asks it rather than restating it, so a dispatcher sees what their declaration will cost before they confirm it. The form is built for a roadside on 2G: four large targets, a cause, and a new time chosen in offsets
- ✅ **Disruption — the rescue coach** (`08-disruption.md` §2.2 option ①) — the first thing an operator here actually does about a breakdown: send the spare. The bookings do not move, the passengers keep their journey, and the seats are **remapped by the domain** onto whatever the new coach has — a passenger keeps their label only when the target has one of the same kind, because `1D` is a window on a 2+2 and the middle of the back block on a 2+3, and handing them the same number would be handing them a worse seat while telling them nothing changed. Every ticket is **re-signed in the same transaction as the new manifest**, since the QR carries the seat (ADR-0007); a swap that left the tickets alone would have the scanner admitting somebody to a seat the manifest has given away. A coach that cannot seat everybody is refused **with the number short**, not with a "no" — "9 short" tells a dispatcher which coach to look for next. Holds with nothing behind them are released rather than slid under somebody mid-checkout
- ⬜ **Disruption — the rest of the re-accommodation plan** (`08-disruption.md` §2.2 options ②③⑤ onwards) — what to do when there is no spare: ranked options, the next departure, protection on another operator, the passenger's own choice, and the atomic rebooking wave
- ⬜ The ledger in anger: payout runs and operator statements
- ⬜ The `config/markets.yaml` loader, so enabling a rail is a config push rather than a release

**Exit:** a traveller pays with Airtel Money and boards. Payment success ≥ 88% first attempt.

The *payment path* is built end to end and waiting on a telco. The phase is not: the reconciliation console exists, disruption is declared, told and recorded, and a rescue coach can be sent — but the rest of the re-accommodation plan, the part that moves people when there is no spare, is unbuilt, and so are payout runs. Saying "everything is built" here — as an earlier draft of this section did — is exactly the kind of claim this document exists to refuse.

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
| Mobile money success below 85% | Per-rail, per-hour dashboard | Rail fallback plus an aggregator escape hatch (ADR-0006) | **Both adapters built and tested against a fake that reproduces every terminal state. Unmeasured until real traffic** |
| An operator mistypes their collection number | — | Saved unverified; no rail is offered until somebody has checked it | Mobile money has no chargeback, so this is the one typo in the product that cannot be undone |
| Travellers do not trust prepayment | Funnel drop at the payment screen | SMS receipts, honest scarcity, visible refund policy, cash retained | Design done; unproven |
| Disruption overwhelms support | Support tickets per disruption | IRROPS is operator self-service and P0 in Phase 2 | Designed, not built |
| **Nobody has used this on a real network** | — | Phase 3 manual smoke | Everything so far is an emulator on a fast connection |
| **No operator can configure anything without us** | Time from "yes" to first departure on sale | The console app | **Closed.** An operator configures a fleet and publishes a timetable in a browser |
| Console auth is single-factor | — | TOTP before refunds and payouts exist (slice 3) | Deliberate and dated. The endpoints ADR-0013 protects are not built |
| **Sign-in email does not arrive** | Delivery rate per hour, from day one of the pilot | Phone as a second channel — which is why it is plumbed rather than someday (ADR-0024) | **New. Email is now on the critical path of becoming a customer, and it has no fallback yet** |

The first two are commercial, and they are the ones that decide the outcome. Nothing in the engineering backlog above changes either of them.
