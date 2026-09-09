# BilletEnLigne — The platform other companies can join

**Status:** Specification and implementation roadmap · **Date:** 2026-09-09
**Reads with:** [`03-operator-lifecycle.md`](03-operator-lifecycle.md), [`07-trip-sharing-tracking.md`](07-trip-sharing-tracking.md), [`16-markets.md`](16-markets.md)
**Depends on:** [ADR-0031](adr/0031-markets-are-context.md) M1–M6 · **Related:** [ADR-0014](adr/0014-trip-tracking-maps.md), [ADR-0022](adr/0022-standalone-scanner-app.md), [ADR-0024](adr/0024-email-first-signin.md), [ADR-0026](adr/0026-the-ticket-you-can-always-get-to.md)

## 0. What this document is

Thirteen slices, **J1–J13**, that close the distance between the funnel that
exists and the marketplace the business is describing: a company decides to
use us, picks its country, is approved, activates, puts its fleet on the road
with a named crew, and a traveller anywhere in that country compares every
company's coaches on one screen, buys, boards, and watches the coach move.

It is written the way `16-markets.md` is written, and for the same reason:
**almost all of this is wiring, not invention.** Six of the thirteen slices
turn on a column, an enum value or a DTO field that has existed since
migration `0001` and that nothing reads.

Four things to hold on to:

1. **The catalogue is already cross-operator.** `postgres_departure_catalogue.dart`
   joins `operators` and filters by one only when asked. Nothing about
   multi-company search needs building on the server.
2. **A person is not a role.** `user_accounts` is the human;
   `operator_staff` is a membership pointing at that same `user_id`. A driver
   who buys a ticket is one account with two facts about it, and that already
   works. **Do not build a second identity.**
3. **The market of the operator and the market of the traveller are different
   questions.** One decides commission, service fee and payout currency; the
   other decides which wallets appear on the payment screen. They coincide
   today because one country is configured. §3 keeps them apart on purpose.
4. **Some of this is already built and merely unreachable.** Say so in the
   slice rather than rebuilding it — §1 is the list.

---

## 1. What is already true

Written down because the expensive failure here is building something twice.
Each row was verified in the tree on 2026-09-09, not read off a status table.

| The business asks for | State | Where |
|---|---|---|
| Company self-signs up, submits, we review, we approve | ✅ built | Onboarding wizard; admin queue, six decisions, audit trail, 48-hour SLA |
| Activation makes the applicant the first `org_owner` | ✅ built | `postgres_platform_console.dart:261`, in the same transaction as the status change |
| Fleet, routes, timetables, stations, seat layouts | ✅ built | The console, including the section-by-section layout builder |
| Logo, cover, accent, pattern, tagline; a public page | ✅ built | The vitrine, rendered server-side at `blt.cg/o/<code>` |
| Search shows every company on the road | ✅ built | `postgres_departure_catalogue.dart:137` — `JOIN operators`, no operator clause unless one is passed |
| Filter by one company | ✅ **server only** | `SearchDeparturesQuery.operatorId`, `trip_dto.dart:179`. No control anywhere in the app |
| Buy · cancel · reschedule · pay the difference | ✅ built | Every reschedule row priced before selection |
| Boarding validation at the coach door, offline | ✅ built | `apps/scanner`, five verdicts, SQLite boarding log |
| A conductor says "we have passed Dolisie" | ✅ built | `road_progress.dart`, `0043_checkpoints.sql`; queued offline, device clock, append-only |
| Somebody who was sent a link watches the coach | ✅ built | `follower_page.dart`, via the `followed_trip(TEXT)` function |
| Another company sells our stranded passengers a seat | ✅ built | Protection agreements **and** the open protection call |
| One person, staff of a company **and** a customer | ✅ built | `operator_staff.user_id → user_accounts.id`. Nothing to do |
| Two languages everywhere | ✅ built | fr/en, including the scanner |
| Reliability score on a search row | ✅ built | Nightly worker pass |

And the seven things this document exists for:

| The business asks for | State | The precise reason |
|---|---|---|
| The company chooses its country at onboarding | ⬜ **not built** | `ApplicationFacts` has no country field, and `routes/public/v1/operator-applications/index.dart:91` passes `context.read<Services>().market.code` — the server's one configured market |
| Activation waits for a verified collection account | ⬜ **not built** | `03-operator-lifecycle.md` §1 says it does. `decide()` checks the transition's legality and nothing else. Money control, specified, unenforced |
| A departure has a crew | ⬜ **not built** | No driver table, no crew column, nothing anywhere links a person to a departure |
| The driver closes the departure when they leave | ⬜ **not built** | `departure_status` has carried `boarding`, `departed` and `arrived` since `0001_foundation.sql:254`. Only disruptions ever write to that column, and only `delayed`/`cancelled` |
| The passenger on the coach watches it move | ⬜ **not built** | The checkpoints exist and only the **follower** page reads them. A passenger would have to open their own share link |
| Sort and filter the results | ⬜ **not built** | No control in `results_screen.dart`. Interacts with the keyset cursor — §6.2 |
| The company's logo on the ticket | ⬜ **not built** | `BookingDto` carries `operatorName` and `operatorAccentHue` and no logo. The logo exists only on `VitrineDto` |
| A web traveller surface | ⬜ **not built** | `apps/console` and `apps/admin` have `web/`. `apps/traveller` has `android/` and `ios/` |
| Telling a passenger who has not arrived | 🔨 **plumbed, switched off** | Templates, drain and channel all exist; no provisioned ACS sender number, so the API answers 503 for the phone channel |

---

## 2. The shape of the gap

Read down the second table and the pattern is one sentence:

> **Everything about selling a seat is built. Almost nothing about the coach
> actually leaving is.**

A departure, today, is a row that inventory is sold against. It has no crew, no
state after `scheduled`, and no way to say it has gone. That single absence is
underneath four of the seven gaps — the driver dashboard has nothing to be a
dashboard *of*, GPS has nothing to attach to, "close the trip" has nothing to
close, and "tell the passenger who is missing" has no moment at which somebody
is missing.

So J3 and J4 are the spine of this document. Build them first even though they
are the least visible thing in it.

---

## 3. The two markets, kept apart

A market answers two different questions and they must not be merged into one
field on one screen.

**The operator's market** — set at onboarding, read-only afterwards, changed
only by platform staff in `apps/admin` (the rule `offerings` already follows:
a tenant that can edit its own licence scope does not have one). It decides:

- the commission the conversation *starts* at (`markets.yaml: defaultCommissionBps`),
- the service fee charged per seat,
- the currency of settlement and payout,
- which cities their routes may originate in.

**The traveller's resolved market** — never chosen on a splash screen, resolved
per request by the chain in `16-markets.md` §2: explicit → profile → phone
country code → locale → fallback. It decides:

- which cities the picker offers,
- which currency fares are displayed in,
- **which wallets appear on the payment screen.**

They coincide today because `config/markets.yaml` configures exactly one
market. They stop coinciding the day a Gabonese traveller buys a seat from a
Congolese operator, and the code that assumed they were the same field will be
found at settlement rather than at review.

**J1 does not build the resolution chain.** That is M1–M6 in `16-markets.md`,
already specified, and this document depends on it rather than restating it.
J1 builds only the missing input: the country the applicant picks.

### 3.1 The refusal that comes with it

Cross-currency is refused at route creation, with a reason
(`16-markets.md` §6):

```
errors.console.routeCrossesCurrency
  "Un trajet entre {a} et {b} traverse deux monnaies. Pas encore pris en charge."
```

Inside CEMAC this never fires — Congo, Gabon, Cameroon, Chad, the CAR and
Equatorial Guinea are all XAF, which is the whole reason to expand along the
franc zone first. It fires on Brazzaville→Kinshasa, and answering that
properly needs a display currency, a settlement currency, a rate, a rate
source and a decision about who carries the movement between quote and
capture. That is an FX feature. It is not this one.

---

## 4. The crew, and who may say where a coach is

### 4.1 Driver is not conductor

On a Congolese intercity coach the person driving and the person taking
tickets at the door are usually two people. ADR-0011 already has a `conductor`
role and `apps/scanner` is built for whoever holds the operator-owned handset.

**This document adds `driver` as a role and a crew assignment, and does not
give the driver the scanner.** The distinction is not pedantry: it decides who
gets a device, who can mark a passenger boarded, and — in J5 — whose tap is
evidence in a delay dispute.

### 4.2 A driver ID is an identifier, never a credential

The request was "the driver logs in with their driver ID and their email".
Half of that is right.

ADR-0024 is email-first: a one-time code to an inbox, plus TOTP for anyone who
can move other people's money. Adding a memorised driver ID on top adds **a
secret to phish, not a factor to hold** — and a driver ID is written on the
roster, printed on the manifest and stuck to the dashboard of the coach, so it
is a secret in the way a company name is a secret.

**Decision:** `operator_staff.staff_ref` is a short human identifier the
operator assigns — shown on the roster, printed on the manifest, searchable in
the console, usable by a station manager to find the right person in a list of
two hundred. It is **never** accepted at a sign-in prompt.

### 4.3 The handset belongs to the departure, not to the person

`BEL_DEVICE_ID` already names a provisioned handset (`apps/scanner/lib/main.dart:133`).
A checkpoint or a position report is attributed to **the departure the handset
is pinned to**, and the crew row says which human was responsible for it. That
ordering matters: a coach with a broken phone borrows another one, and the
claim about where the coach was must survive that.

---

## 5. The road reports itself

### 5.1 What exists, exactly

Tier 2 of ADR-0014 is built and works: the conductor taps a stop, it is
confirmed once (a second tap on a moving coach is a double tap, not a
correction), it queues on the device because the RN1 is four hours with no
usable signal, **the device's clock is what is recorded** and ours only as
*when we heard*, and the row is append-only — no `UPDATE` grant, no `DELETE`
grant, because a claim about where a coach was is evidence in a delay dispute.

### 5.2 The two things missing

**Nobody is ever asked.** Confirming a stop is a control on a screen a
conductor may never open. A coach whose conductor never taps shows an honest
estimate for four hours, and honest is not the same as useful.

**The passenger cannot see it.** `followed_trip(TEXT)` is granted to
`bel_public` and keyed on a share token. A passenger *on the coach* has no
token unless they minted a link to share with somebody else. The person with
the most reason to want this — and the one whose phone is already in their
hand — is the only one who cannot see it.

### 5.3 What we will not do

**Not a live GPS dot in the traveller app.** `07-trip-sharing-tracking.md` §5
already refuses it and the refusal holds for two reasons that have not
changed: a map SDK is several megabytes of binary and real memory on a 2 GB
device against ADR-0009's 15 MB budget, and — the stronger one — **a moving
dot is a promise the network cannot keep on the RN1.** A stale dot is worse
than an honest bar, which is why the UI is required to state which tier it is
showing.

**Not compulsory in the punitive sense.** "Force them to enter" is the right
instinct and the wrong mechanism. A conductor who cannot dismiss a modal at a
coach door with a queue behind them will put the handset in a drawer. J5
prompts at the moment the timetable says the stop is due, makes the tap one
gesture, and makes the *miss* visible to the dispatcher — a number on a screen
in an office, not a wall in front of somebody working.

**Tier 1 (GPS), when it comes, is store-and-forward.** Breadcrumbs batched on
the handset and uploaded when signal returns, backfilling the trail. That is
what the road actually allows. It is J-out-of-scope and named here so the
crew work in J3 is built to receive it.

---

## 6. Choosing between companies

### 6.1 What the industry does, and what we keep

Standard practice on this kind of results screen is sort by **earliest ·
cheapest · fastest**, and filter by **operator · departure window · price
ceiling · amenities**. We add one rule of our own that is already in the code
and worth keeping:

> **Sold-out coaches are shown dimmed, not filtered out**
> (`results_screen.dart:10`). Seeing that the 06:00 is full is information —
> it is how somebody decides to take the 05:30 instead of coming back
> tomorrow.

A filter that hides them would delete that. So filters narrow **what is
offered**, never **what is knowable**.

### 6.2 The trap: sorting and the cursor

Search pagination is a **keyset cursor**, and a keyset cursor is defined
against a sort order. Changing the sort is not a client-side re-sort of a page
— it is a different query with a different cursor, and a cursor minted under
one order is meaningless under another.

**Decision:** the sort key is part of the cursor and the server refuses a
cursor whose sort does not match the request:

```
errors.travel.searchCursorSortChanged
```

Refused rather than silently re-sorted, because silently re-sorting produces
duplicate and missing rows across a page boundary — the failure mode that
looks like the inventory being wrong.

---

## 7. The ticket, and the web

### 7.1 The logo travels with the ticket

The ask is right and the implementation has one hard constraint: **a ticket
must render at a coach door with no network.** So the logo cannot be a URL the
ticket screen fetches. It is cached into the SQLite ticket vault when the
ticket is issued, at the size it will be drawn, and a ticket whose logo never
downloaded renders the accent and the trading name exactly as it does today.

The 40 KB / 512 px cap that the vitrine already enforces is what makes this
affordable. A logo is refused at upload, never resampled — re-encoding
somebody's brand mark is a silent change to the one asset they care about
most.

### 7.2 `billet.cg` sells; it does not hold

Full parity with the app is the wrong target, and the reasons are already
written down:

- **Secure storage on web is obfuscation.** Known gap #4: the web
  implementation puts an AES key in `localStorage` beside the value it
  encrypts. The honest web equivalent of a persisted session is a same-site
  cookie set by the server, and that is a slice of its own.
- **The ticket vault is `sqlite3_flutter_libs`**, and the camera and push have
  no place on this surface at all.

**Decision:** the web surface is a **sales** surface — search, results, seat
map, hold, pay — and it hands over an **ADR-0026 ticket link** rather than
building a wallet. That link already exists, is already the answer to "my
phone died / I have no app", and is already the thing a traveller forwards to
whoever is paying for their seat.

This is not a lesser product. It is the correct product for somebody who
cannot install 15 MB, and it is roughly a third of the work of parity.

---

## 8. The operator that stops selling

`03-operator-lifecycle.md` §1 states the governing rule:

> **`suspended` and `offboarding` both stop new sales but honour issued
> tickets.** A platform that strands paying passengers to punish an operator
> has punished the wrong party.

It is stated and it is not proven. J13 makes it a schema guarantee rather than
a sentence: with an operator suspended, a `SELECT` on their future departures
from the public surface returns nothing **and** every already-issued ticket for
those departures still validates at a door. No implementation that simply
hides the operator's rows can satisfy both halves, which is what makes the
guarantee regression-proof.

---

## 9. Slices

Each slice is independently shippable and independently revertible. Dependencies
are named; nothing here is a big-bang.

### Part A — the company arrives

#### J1 — the application asks which country
**Depends on:** M1–M2 (`16-markets.md`)
`ApplicationFacts` gains `marketCode`; step 1 of the wizard gains a picker that
renders **only when more than one market is configured** — the same rule as the
traveller's chip and the transport-mode chooser. `operator-applications/index.dart:91`
stops reading `Services.market.code` and reads the application.
Refusal: `errors.onboarding.marketNotConfigured`.
*Tests:* an application in an unconfigured market is refused; a single-market
deployment renders no picker and still writes `CG`; the admin operator page
shows the chosen market.

#### J2 — activation waits for the money to have somewhere to land
**Depends on:** nothing
`decide(activate)` gains two preconditions: at least one **verified**
collection account, and a recorded agreement acceptance. Both already exist as
data; neither is consulted. Refused with the specific missing one named —
`errors.admin.activationNeedsVerifiedAccount` /
`errors.admin.activationNeedsAgreement` — because a bare "refusé" on a
reviewer's screen is a support call.
*Tests:* activation refused with no account, refused with an unverified one,
allowed with a verified one; **reinstating** a suspended operator is not
blocked by this (they were already trading).

### Part B — the crew and the departure

#### J3 — a departure has a crew
**Depends on:** nothing. **Blocking for J4, J5, J7 and any future GPS.**
New `departure_crew (departure_id, user_id, role, assigned_at, assigned_by)`,
tenant-isolated, where `role ∈ {driver, conductor}`. `operator_staff` gains
`staff_ref TEXT` — §4.2, an identifier and never a credential. The console's
dispatcher day gains an assignment control; the manifest prints the crew.
*Tests:* a person not staff of the operator cannot be assigned; the same person
may hold both roles on one departure (small operators do); a revoked staff
member is dropped from future departures and kept on past ones, because the
past is a record.

#### J4 — the departure lifecycle is written, not just declared
**Depends on:** J3
`boarding`, `departed` and `arrived` become states something writes.
`boarding` when the first ticket is scanned; `departed` on the crew's own
action — the "close the departure" the business asked for — and `arrived` on
the last waypoint or the crew. **`departed` closes new sales on that departure
and nothing else**: it does not invalidate a ticket, because a passenger who
boarded and is sitting down has a valid ticket by definition.
Refusal: `errors.console.departureAlreadyClosed`.
*Tests:* the six-state transition table, legal and illegal; a hold in flight
when a departure closes is released rather than sold; a scan after `departed`
still validates.

#### J5 — confirming a stop is asked for, not hoped for
**Depends on:** J3, J4
The scanner prompts at the timetable's own expected time for the next
waypoint — one gesture, dismissible, re-offered once. The dispatcher's day
gains a **coverage** column: confirmed stops over expected stops, per
departure. The pressure is a number in an office, never a modal at a coach
door (§5.3).
*Tests:* the prompt fires from the timetable and not from a wall clock; a
dismissed prompt is re-offered exactly once; coverage is computed from
`departure_checkpoints` and not from a counter that can drift.

#### J6 — the passenger sees their own coach move
**Depends on:** J5 (useful without it; worth little)
The traveller's ticket screen gains the same progress the follower page draws:
the stop list, what is behind, the tier label. Read through the booking, not
through a share token — a passenger holding a ticket for a departure needs no
link to see where it is. **The tier label is not optional here either**: this
screen must never draw more confidence than the data has.
*Tests:* a passenger sees progress with no share link minted; someone whose
booking was cancelled does not; the label says *estimation* when no checkpoint
has been confirmed.

#### J7 — the passenger who has not arrived is told
**Depends on:** J3, J4 · **Gated commercially:** needs a provisioned ACS sender
At `boarding`, the manifest knows who has scanned and who has not. Twenty
minutes before departure, unscanned passengers get one message with the
boarding point and the departure time. One message, never a sequence, and
never after `departed` — a passenger who has missed the coach needs the missed
-departure policy that already exists, not an SMS telling them to hurry.
*Tests:* one message per passenger per departure, proven by the outbox's own
idempotency; nobody who has scanned is messaged; nothing is sent after
`departed`.

### Part C — choosing between companies

#### J8 — sort, then filter
**Depends on:** nothing
Sort by earliest · cheapest · fastest, with the sort key **inside the cursor**
and a refusal when they disagree (§6.2). Filter by operator (the server
parameter already exists), departure window and price ceiling. Sold-out rows
stay visible and dimmed.
*Tests:* a cursor minted under one sort is refused under another; paging under
each sort produces every row exactly once; filtering to one operator does not
hide their sold-out coaches.

#### J9 — the company on the row
**Depends on:** J8
The results row carries the operator's logo and accent beside the reliability
score that is already there. A row is a choice between companies, and a company
the traveller cannot recognise is a company they cannot choose.
*Tests:* a row with no logo renders exactly as it does today; the contrast gate
passes against every accent in the catalogue.

### Part D — the ticket

#### J10 — the logo travels with the ticket
**Depends on:** nothing
`BookingDto` gains `operatorLogoUrl`; the ticket vault caches the bytes at
issue; the ticket draws it. A ticket whose logo never downloaded is a ticket,
not an error (§7.1).
*Tests:* a cold start with no network renders the logo from the vault; a
booking issued before this slice renders without one; the vault's size stays
bounded when a logo changes.

### Part E — the web surface

#### J11 — `billet.cg` sells
**Depends on:** J8
`apps/traveller` gains `web/`, and the funnel through payment. The vault, the
camera and push are **excluded at the composition root** rather than
conditionally compiled, so the exclusion is a thing a reviewer can see.
*Tests:* the web build refuses to link the vault; the funnel completes on web
against a fake rail; first paint under 2 s on 3G.

#### J12 — the ticket link is the wallet on web
**Depends on:** J11, ADR-0026
Payment on web ends in a ticket **link**, delivered in the page and by email,
rather than in a stored ticket. A web session ends when the tab closes and the
link is what survives it (§7.2).
*Tests:* the link opens the ticket with no session; revoking it refuses;
nothing is written to `localStorage` that would read as a credential.

### Part F — the operator that stops

#### J13 — suspension honours issued tickets, provably
**Depends on:** nothing
A schema guarantee in `verify_public.sql`: with an operator suspended, their
future departures are invisible to the public surface **and** every ticket
already issued for them still validates. Both halves in one assertion (§8).
*Tests:* the guarantee itself; a suspended operator's departure is absent from
search; a boarding scan for it succeeds.

---

## 10. Order, and what gates what

```
J3 ─┬─ J4 ─┬─ J5 ── J6
    │      └─ J7 (gated: ACS sender number)
    └─ (any future GPS tier)

J1 (gated: M1–M2)      J2      J13        — independent, land any time

J8 ─┬─ J9
    └─ J11 ── J12
```

**Build J3 and J4 first** even though they are the least visible slices here.
They are the spine (§2): four of the seven gaps are downstream of a departure
having no crew and no state.

**J2 and J13 are the two money-and-trust slices** and neither depends on
anything. They are each a day's work and each closes a distance between what
`03-operator-lifecycle.md` promises and what the code enforces. Do them while
J3 is in review.

---

## 11. What this document deliberately does not do

- **It does not build the market resolution chain.** M1–M6 in
  `16-markets.md`, already specified. J1 is the one input those slices need
  and do not have.
- **It does not add a country splash to the traveller app.** ADR-0031 refuses
  it: no modal between opening the app and typing a city. The chip in M4 is
  the answer, and it renders only when more than one market exists.
- **It does not put conductor mode in the traveller app.** ADR-0022 settled
  that, and the size argument alone settles it: a camera and an ML barcode
  pipeline is a permanent tax on 100% of users to serve well under 1%.
- **It does not build a live map.** §5.3. Tier 1 GPS is a separate slice
  against a separate ADR, and J3 exists partly so that it has somewhere to
  attach when it comes.
- **It does not touch reviews.** V1–V10 in `14-reviews.md`. Relevant to
  choosing between companies and specified elsewhere.
- **It does not solve cross-currency.** §3.1. Expand along XAF; FX is its own
  product.
