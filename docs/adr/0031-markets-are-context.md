# ADR-0031 — Markets are context, not partitions

**Status:** Accepted · **Date:** 2026-08-14 · **Amends:** ADR-0006 · **Reads with:** `16-markets.md`

## Context

The multi-country model has been in the schema since migration `0001`. `operators.market_code`, `cities.market_code` and `user_accounts.market_code DEFAULT 'CG'` are written on every insert, and `packages/bel_platform/test/market_test.dart` stands up a complete second market — the DRC, with its own currency, its own dialling plan and its own carrier mix — in test code alone, proving that adding a country is data plus an adapter.

None of it does anything.

`market_code` is **read exactly once in the entire tree**: `postgres_platform_console.dart:617`, to print it on an admin screen. It filters nothing. The city-picker query in `postgres_departure_catalogue.dart:517` selects every city that any active route touches, with no market clause at all. `Market.current` is a compiled-in singleton, four use cases take it as a default parameter, and `market_test.dart` asserts that `Market.all` has length one.

So the state today is: **modelled, tested, and inert.** Seed Gabon tomorrow and a traveller in Brazzaville sees Libreville and Port-Gentil in their origin picker, mixed in with Congolese cities, with nothing to tell them apart. It is the same shape of defect as `TripDto.mode` — a value carried faithfully from Postgres to the handset and read by nobody.

The question that surfaced it: should the traveller choose a country first, should it live on their profile, and should an operator's country scope what their inventory is found by? And behind that, a bigger one — whether to think regionally at all, given that Gabon, Cameroon, Chad and the Central African Republic have the same underdeveloped-transport problem Congo does.

## Analysis

### Two designs to reject first

**Country as a mandatory first step in search.** Ninety-odd per cent of searches are domestic, and a country picker in front of every search taxes every user on every search to serve a rare case. It is also the wrong category: **country behaves like language and currency, both of which this product already resolves rather than asks.** Nobody is made to choose French before they can search. A market is the same kind of fact.

**Country as a partition of inventory.** Filter departures by market and the model looks clean right up until the first cross-border route, and then it is wrong in an expensive way. Brazzaville→Libreville is a real corridor. So is Douala→N'Djamena. A departure partitioned into one market either disappears for the traveller at the other end, or has to be duplicated into two markets, which is the beginning of a synchronisation bug that ends in double-selling one coach.

There is no correct answer to *"which market is the Brazzaville→Libreville coach in?"*, and the reason is that the question is malformed. A departure does not have a market. **An operator has a market, because an operator is licensed and taxed and settled with somewhere. A city has a market, because a city is in a country. A departure just connects two cities.**

### What a market actually scopes

Once stated that way the answer falls out, and it is narrower than it first appears:

- **The city catalogue is scoped.** This is the real bug today, and fixing it fixes the reported symptom.
- **The traveller's context is scoped** — their currency display, their dialling plan, their default language, the payment rails they are offered, the service fee they see.
- **The operator is scoped**, and this one is an enforcement rather than a display: an operator registered in CG must be refused when publishing a route whose *origin* is in Gabon. They are not licensed to run a domestic Gabonese service. That is a rule the API should hold, not a hint the console should give.
- **Departures, routes and bookings are not scoped.** They are found by city pair. A pair that spans a border works with no special case at all, which is the whole return on this design.

### Resolution, and the rung nobody else has

A resolved market needs a chain, ordered by confidence:

1. **An explicit choice**, from the chip on the search screen or the profile. It wins, always, and it is remembered.
2. **`user_accounts.market_code`**, which already exists and is already written.
3. **The dialling code of the user's phone number.** +242 is Congo, +241 Gabon, +237 Cameroon, +235 Chad, +236 the CAR. This is the strong rung and it costs nothing: `MsisdnPrefixTable` already parses MSISDNs and resolves carriers from prefixes, and a country code is the part it strips first.
4. **The device locale's region**, weak but free.
5. **`config/markets.yaml`'s `defaultMarket`.**

Rung 3 deserves a caveat rather than enthusiasm. Sign-in is email-first (ADR-0024) and a large share of accounts will have no phone number at all, so the chain has to be genuinely a chain and not a phone lookup with fallbacks bolted on afterwards.

### Currency is the one hard edge

A market has one currency, and a booking has one. For a cross-border route the answer is **the operator's market's currency**, because the operator is who we settle with, net commission from, and pay out to.

That is clean inside **CEMAC**, where it is not even a question: Congo, Gabon, Cameroon, Chad, the Central African Republic and Equatorial Guinea all use **XAF**, pegged to the euro. A Brazzaville→Libreville coach prices in XAF at both ends.

It is not clean between currency zones. A Brazzaville→Kinshasa service crosses XAF into CDF, and answering it properly means a display currency, a settlement currency, a rate, a rate source, and who carries the movement between quote and capture. That is an FX feature, and it is not this one.

**So v1 permits cross-border routes only within a single currency zone**, and refuses the others at the API with a message that says why. A refusal that names its reason is a feature request from an operator; a silently wrong price is a dispute.

### Thinking regionally — the case, and the limit

The four countries named alongside Congo — Gabon, Cameroon, Chad, the CAR — are all CEMAC, and the alignment is better than intuition suggests:

- **One currency across all six.** No FX in the ledger, no multi-currency payouts, no work in `Money` or `Currency` at all.
- **All six are UTC+1 with no daylight saving.** The local-day question the entire search rests on — *"departures on the 15th"*, which `postgres_departure_catalogue.dart` asks Postgres rather than deriving in Dart — has the same answer in every one of them.
- **MTN and Airtel operate across several.** The API integration is the same; the merchant contract is almost certainly a separate per-country entity, and that should be assumed rather than hoped.

There is an irony worth recording: the second market this codebase already rehearses in test code is the **DRC**, which is CDF — the *hardest* neighbour, currency-wise. The easy ones are the four that were named.

**And the limit.** Building for N countries is cheap now and expensive after two markets hold real data. Launching in N countries is not cheap at all: each one needs its own telco merchant onboarding — four to twelve weeks, per carrier, per country — a local entity or partner, a regulator posture, an anchor operator and cash agencies. Congo has none of those closed today: no LOI, and no merchant application submitted.

`09-roadmap.md`'s first line has been true since it was written: **the long poles are commercial, not technical.** Regional expansion is the single most attractive way to feel productive while both of those gates stay shut.

## Decision

**A market is request context, resolved rather than asked. It scopes the city catalogue, the traveller's presentation and the operator's licence. It does not partition inventory. Build for the region; launch in one country.**

### 1. Resolution

The chain in §Analysis, implemented once, in one place, on the server. The resolved market travels on the request context the way the language already does — never re-derived in a handler, never guessed at in a client.

`MarketDto` continues to describe **one** market, the resolved one, because that is what the hot path needs. A separate list endpoint serves the chip.

The `/public/v1/market` ETag must incorporate the resolved market code. The response now varies by caller, and an ETag that does not vary with it hands a Gabonese traveller a cached Congolese market.

### 2. Scoped: the city catalogue

`GET /public/v1/cities` filters on `cities.market_code`, defaulting to the resolved market and overridable by parameter — because a traveller searching a route into the next country needs to be able to see its cities.

### 3. Not scoped: routes, departures, bookings

Found by city pair. A pair spanning a border is not a special case and must not become one. **No query that returns departures may gain a market predicate**, and that is worth stating as a prohibition rather than an omission, because adding one would look like a tidy-up.

### 4. Enforced: the operator's licence

A route's **origin city must be in the operator's market.** The destination may be anywhere. An operator licensed in Congo may run Brazzaville→Libreville; they may not run Libreville→Port-Gentil, which is a domestic Gabonese service they hold no licence for.

Refused at the API with a named reason, not hidden in the console — the console may also hide it, but a rule enforced only in a UI is not enforced.

### 5. Money follows the operator

Service fee, commission and settlement currency all come from **the operator's market**, not the traveller's. The four use cases that today default to `Market.current` — `search_departures`, `hold_seats`, `reserve_booking`, `pay_for_booking` — take the resolved market instead, and for anything that touches an operator's money, the operator's.

Cross-border is permitted only within one currency zone until an FX decision exists. Refused with a reason.

### 6. Visible, and changeable

A chip on the search screen showing the current market, changeable in one tap, remembered on the profile. Not a step, not a modal, not a splash screen. It appears only when more than one market is configured — the same rule the transport-mode chooser follows (`11-air.md` §4.1), for the same reason: a control with one possible answer is a control that makes every screen worse.

### 7. A market stays data

No code branches on a market code. Ever. `market_test.dart` already proves a second market is a `const` in a test file plus a payment adapter, and `config/markets.yaml` already makes enabling one a config push (ADR-0006). Nothing in this decision may erode that; the day a handler says `if (market.code == 'CG')` is the day this ADR failed.

### 8. Sequencing

**Make `market_code` live now; add the second market when a commercial gate opens.** The engineering is two slices' worth and gets much more expensive once two markets hold production data. The launch is a separate decision with separate, commercial, prerequisites, and the roadmap's Phase 5 gate on adjacent markets is unchanged by this ADR.

## Consequences

**Good.** The reported symptom — a city picker that would silently mix countries — is fixed by one `WHERE` clause and the column that was already there. Cross-border corridors, which are among the most valuable routes in the region, work with no special case. `user_accounts.market_code` stops being a column nobody reads. A second CEMAC country becomes a YAML entry, a city list and an operator, with no schema change and no FX. The architecture is honest about being regional while the go-to-market stays honest about being Congolese.

**Bad.** Market resolution is a new piece of request context that every read path has to be correct about, and being wrong about it is quiet — a traveller sees a slightly wrong city list rather than an error. The `/public/v1/market` ETag gets more subtle. The chip is another control on the most important screen in the product.

**Risk — the prohibition in §3 erodes.** Someone will, in good faith, add `AND d.market_code = @market` to a departure query, because every other table has one and it looks like an oversight. That is the day cross-border breaks. The mitigation is that departures have no market column to add — the absence is the enforcement, and `16-markets.md` says so where somebody adding a column would read it.

**Risk — focus, again.** This ADR makes the region look one config file away. It is not. Nothing here shortens a merchant onboarding or produces an anchor operator, and §8 exists to keep those two facts in the same sentence as the architecture.
