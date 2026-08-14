# BilletEnLigne — Markets: making the country column live

**Status:** Specification and implementation roadmap · **Date:** 2026-08-14 · **Implements:** [ADR-0031](adr/0031-markets-are-context.md) · **Reads with:** [ADR-0006](adr/0006-payment-rail-sequencing.md), [`11-air.md`](11-air.md) §4.1

## 0. What this document is

ADR-0031 decided that a market is context rather than a partition. This says how to build it: eight slices, each with its files and its tests.

Four things to hold onto:

1. **`market_code` already exists everywhere and is read once.** This is not a modelling exercise. It is wiring up a column that three tables have carried since migration `0001`.
2. **Departures have no market column, and must never get one.** ADR-0031 §3. That absence is what makes cross-border work. If you find yourself adding `AND d.market_code = @market` to a search query, stop and read §5 of this document.
3. **A market is data.** No handler branches on a market code. `config/markets.yaml` is the authority and `Market.congoBrazzaville` is only the offline fallback.
4. **Build for the region; launch in one country.** Slices M1–M6 are engineering and can land now. M7 and M8 add a second market and are gated on a commercial decision, not on this document.

---

## 1. Current state, precisely

**Written, everywhere:**

- `operators.market_code TEXT NOT NULL` — `0001_foundation.sql:32`
- `user_accounts.market_code TEXT NOT NULL DEFAULT 'CG'` — `0001_foundation.sql:78`
- `cities.market_code TEXT NOT NULL` — `0001_foundation.sql:152`

**Read, once:** `postgres_platform_console.dart:617`, `marketCode: r['market_code'] as String`, to display it on an admin operator page. That is the only read in the tree.

**Never read at all:** `user_accounts.market_code`. Written with a default on every account and consulted by nothing.

**The city picker has no market clause.** `postgres_departure_catalogue.dart:517`:

```sql
SELECT c.code, CASE WHEN @language = 'en' THEN c.name_en ELSE c.name_fr END AS name,
       c.lat, c.lng
  FROM cities c
 WHERE EXISTS (SELECT 1 FROM routes r
                WHERE r.active AND (r.origin_city = c.code OR r.destination_city = c.code))
 ORDER BY name
```

**`Market` is a compiled-in singleton.** `Market.all` is `<Market>[congoBrazzaville]`, `Market.current` is `congoBrazzaville`, and `market_test.dart` asserts `Market.all` has length 1 — a test that must change in M8 and not before.

**Four use cases default to it:** `search_departures.dart:84`, `hold_seats.dart:124`, `reserve_booking.dart:65`, `pay_for_booking.dart:78`, each `this.market = Market.current`.

**The server already resolves a live catalogue.** `MarketCatalog` loads `config/markets.yaml` at startup, `composition.dart:389` and `:552` take `marketCatalog(env).defaultMarket`, and `routes/public/v1/market.dart` serves it with an ETag. The plumbing for *many* markets exists; only one is configured and nothing chooses between them.

**`routes` has no market and needs none** — `origin_city` and `destination_city` reference `cities(code)`, and each city carries its country. A route's market is derived from its origin, and a cross-border route is one whose destination resolves elsewhere.

---

## 2. The resolved market

**NEW** `packages/bel_platform/lib/src/market/market_resolution.dart`

```dart
/// Which rung of the chain answered, kept because it is the difference
/// between "we know" and "we guessed" — and the chip in M4 says so.
enum MarketSource { explicit, profile, phone, locale, fallback }

final class ResolvedMarket {
  const ResolvedMarket(this.market, this.source);
  final Market market;
  final MarketSource source;

  /// Only an explicit choice is worth writing back to the profile. Writing a
  /// guess would make the guess permanent and unfalsifiable.
  bool get isWorthRemembering => source == MarketSource.explicit;
}

/// The chain, in one place. ADR-0031 §1.
///
/// Every argument is nullable because every rung is genuinely absent for
/// somebody: a first-time visitor has no profile, an email-first account
/// (ADR-0024) has no phone, and a server-to-server call has no locale.
ResolvedMarket resolveMarket({
  required List<Market> configured,
  required Market fallback,
  String? explicitCode,
  String? profileCode,
  String? phoneE164,
  String? localeRegion,
}) { ... }
```

The phone rung reads the country code off an E.164 number and matches it against each configured market's `msisdn.countryCode`. `MsisdnPrefixTable` already holds `countryCode` — `'242'` for Congo — so this is a lookup, not a parser.

**Ambiguity is a real case and must not be guessed at.** Two configured markets sharing a dialling code would make the phone rung meaningless; there are none today and there will be none in CEMAC, where every country has its own. If `configured` ever contains two markets with the same `countryCode`, the phone rung yields nothing and resolution falls through. Asserted by a test.

### 2.1 Carrying it

The resolved market joins the request context beside the language, in `services/api/lib/src/middleware/`. Resolved **once**, per request, never re-derived in a handler.

An explicit choice arrives as `X-BEL-Market` — a header rather than a query parameter, so it applies uniformly to every route without each one growing an argument, and so it never ends up in a URL that gets cached or logged as though it were part of the resource.

---

## 3. What the traveller sees

**The chip.** On the search screen, beside the title: the market's name from the catalog, tappable, opening a short list of configured markets. It renders only when more than one market is configured — the same rule as the transport-mode chooser (`11-air.md` §4.1) and for the same reason.

**Not a step.** No country splash, no modal on first launch, nothing between opening the app and typing a city. ADR-0031 rejects that explicitly.

**Changing it changes three things visibly**: the city list, the currency the fares are shown in, and the payment rails offered. It does **not** clear an in-flight booking — somebody who taps the chip while holding a seat has not abandoned the seat.

---

## 4. What an operator sees

Their market is set at onboarding from their application and shown, read-only, on their profile. Only platform staff change it, in `apps/admin` — the same rule `offerings` follows (ADR-0027 §4): a tenant that can edit its own licence scope does not have one.

Route creation gains one refusal:

```
errors.console.routeOriginOutsideMarket
  "Votre licence couvre {market}. L'origine {city} est en {other}."
```

Named, in both languages, and specific. A refusal that names its reason is a feature request; a bare "refusé" is a support call.

---

## 5. The prohibition

**No query that returns departures may filter on a market.**

Not `departures`, not `trips`, not the seat map, not the manifest, not the boarding bundle. Departures are found by city pair, and a pair that spans a border is not a special case.

This is stated as a prohibition because it will look like an oversight. Every other table has a `market_code`; a careful engineer tidying up will reach for the missing one. **The absence is the enforcement.** `departures` has no market column to filter on, adding one is the way this breaks, and this paragraph exists where somebody about to add it would be reading.

The corollary for search: a traveller whose resolved market is CG searching Brazzaville→Libreville gets results. The city picker showed them Libreville because M1 lets the picker reach past the border on request; the search itself never knew there was one.

---

## 6. Money

Service fee, commission and settlement currency come from **the operator's market**, never the traveller's. The operator is who we net commission from and pay out to.

The four use cases stop defaulting to `Market.current`:

- `search_departures` — the fee shown on a row is the fee that row's operator charges
- `hold_seats`, `reserve_booking`, `pay_for_booking` — the fee actually charged, from the operator on the booking

**Cross-currency is refused, with a reason.** A route whose origin and destination markets have different currencies is rejected at creation:

```
errors.console.routeCrossesCurrency
  "Un trajet entre {a} et {b} traverse deux monnaies. Pas encore pris en charge."
```

Inside CEMAC this never fires — Congo, Gabon, Cameroon, Chad, the CAR and Equatorial Guinea are all XAF. It fires on Brazzaville→Kinshasa, which crosses XAF into CDF, and answering that properly needs a display currency, a settlement currency, a rate, a rate source and a decision about who carries the movement between quote and capture. That is an FX feature and it is not this one.

---

## 7. Contracts

- `MarketDto` — unchanged in shape. It describes **one** market, the resolved one.
- **NEW** `MarketSummaryDto` — `code`, `nameKey`, `currency`, `flagEmoji`. For the chip.
- **NEW** `GET /public/v1/markets` — the configured list. Small, cacheable, rarely changes.
- `CityDto` — unchanged. A city's market is a server concern; the client asked for a market's cities and got them.

### 7.1 The ETag, which now varies

`routes/public/v1/market.dart` hashes the response body into a weak ETag. The body now depends on the caller, so **the resolved market code must be part of the hash**, and the response needs `Vary: X-BEL-Market`.

Miss this and a Gabonese traveller is served a cached Congolese market by whatever sits in front of the API — which is exactly the class of bug an ETag is otherwise excellent at hiding, because it looks like a cache working.

---

## 8. Slices

House rules as elsewhere: one commit each, pushed; `check_layers` clean; `./tool/sync_i18n.sh` after catalog edits; `rm -rf services/api/build` before smoke; pipe `dart test` through `tr '\r' '\n'`.

### M1 — the city picker learns its country

**The reported bug, and the smallest fix in this document.**

Files: `postgres_departure_catalogue.dart` city query; `routes/public/v1/cities.dart`; `travel_gateway.cities()` and its two implementations; `booking_flow.dart`.

The query gains `AND c.market_code = @market`, and the route gains an optional `?market=` so a traveller can see the next country's cities deliberately.

Tests: with cities seeded in two markets, the picker returns only the resolved market's; `?market=GA` returns Gabon's; an unknown code returns empty rather than everything — **failing closed, because failing open is the bug being fixed**.

### M2 — the market is resolved once, on the server

Files: **NEW** `market_resolution.dart` in `bel_platform`; the request-context middleware; `composition.dart`.

Tests: each rung in isolation; the full chain in order; an email-only account with no phone falls through to locale and then fallback; **two configured markets sharing a dialling code make the phone rung yield nothing**; an unknown `X-BEL-Market` is ignored rather than fatal.

### M3 — the profile remembers, but only a choice

Files: `user_accounts.market_code` read at sign-in and written on explicit change; `/public/v1/me`.

Tests: an explicit choice is persisted and wins next session; **a phone-derived or locale-derived market is not written back** — `isWorthRemembering` is false, and a guess made permanent is a guess that can never be corrected; a user with no phone and no choice reads the default.

### M4 — the chip

Files: `KMarketChip` in `bel_design`; `search_screen.dart`; `MarketSummaryDto`; `GET /public/v1/markets`; catalog keys.

Tests: absent when one market is configured; present with two; choosing one re-fetches cities and re-prices the results; **an in-flight hold survives the change**; goldens in both themes.

### M5 — an operator's licence is enforced

Files: `routes/console/v1/routes.dart`; `postgres_operator_console.dart`; catalog keys.

Tests: an operator in CG creating Brazzaville→Libreville **succeeds**; the same operator creating Libreville→Port-Gentil is **refused at the API**, with the market named; the console hides it too, and the API test is the one that counts.

### M6 — money follows the operator

Files: the four use cases; `search_departures`, `hold_seats`, `reserve_booking`, `pay_for_booking`.

Tests: a row's service fee is its operator's market's, not the traveller's; a cross-border booking settles in the operator's currency; a route across two currencies is refused at creation with a reason; the ledger still balances.

### M7 — a second market exists · **gated on a commercial decision**

Files: `config/markets.yaml` gains Gabon; `Market.all`; the demo world gains a Gabonese operator, cities and one cross-border route; `market_test.dart`'s length-1 assertion changes.

Tests: everything in M1–M6 exercised against two live markets; a Brazzaville traveller sees Congolese cities by default and Gabonese on request; the cross-border route is searchable from both ends.

### M8 — the ETag stops lying

Files: `routes/public/v1/market.dart`.

Tests: the same request with two different `X-BEL-Market` values yields two different ETags; `Vary` is present. **Small, and it is the slice that decides whether M1–M7 survive a CDN.**

---

## 9. The region, and the limit

Gabon, Cameroon, Chad, the Central African Republic and Equatorial Guinea are CEMAC with Congo, and the alignment is unusually good:

- **All six use XAF**, pegged to the euro. No FX, no multi-currency payouts, no work in `Money` or `Currency`.
- **All six are UTC+1 with no daylight saving.** The local-day question the search rests on has one answer everywhere.
- **MTN and Airtel operate across several.** Same API integration; assume a separate merchant contract per country entity rather than hoping otherwise.

The irony worth knowing: the second market this codebase already rehearses is the **DRC**, which is CDF — the hardest neighbour. The easy ones are the four CEMAC states.

**And the limit, which belongs in the same paragraph.** Each additional market needs its own telco merchant onboarding — four to twelve weeks, per carrier, per country — a local entity or partner, a regulator posture, an anchor operator and cash agencies. Congo has none of those closed: no LOI, no merchant application submitted.

M1–M6 are engineering, cost little now and much more once two markets hold production data. M7 is a business decision wearing a slice's clothes, and `09-roadmap.md`'s Phase 5 gate on adjacent markets is unchanged by anything here.
