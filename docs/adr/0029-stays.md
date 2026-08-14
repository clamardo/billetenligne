# ADR-0029 — Stays: hotels, guesthouses and the fourth seam

**Status:** Accepted · **Date:** 2026-08-14 · **Depends on:** ADR-0027 · **Reads with:** ADR-0030, `13-stays.md`

## Context

Unlike coaches, aircraft and rental cars, hotels in this region **do** have an online channel. Booking.com, Expedia and Jumia Travel all operate here. So the question is not "does this exist" but "why is it bad", and the answer decides whether there is a product.

Four things are wrong with the incumbent channel in this market, and each of them is addressable:

**The commission is 15–18%.** On a 45 000 XAF room night that is up to 8 100 XAF, taken from a property whose margin is not a European property's margin. Our platform's default is 500 basis points — 5% — and it is already netted at source through a ledger that balances. Being the cheap channel is not a marketing position here; it is arithmetic that changes whether a property lists at all.

**Coverage is thin and skewed.** The listed supply is the international-brand and business-hotel end. The auberges, résidences meublées and small family hotels that are most of the actual room stock are largely absent, because onboarding to a global OTA requires a bank account, an English-language contract, a channel manager and a photographer.

**Payment does not fit.** The OTAs want a card. A large share of travellers in this market do not have one, and would not use it here if they did. Mobile money is the rail, and we have four of them working with a balanced ledger behind them. That is the moat, and it is the same moat that makes the bus product work.

**The vocabulary is wrong.** An OTA amenity list has *minibar*, *spa*, *concierge*. What decides a booking in Brazzaville is whether there is a **groupe électrogène** that actually runs when the grid drops, whether there is **eau chaude**, whether the **wifi** works or is a sticker on a wall, and whether parking is **gardé**. None of these are expressible on the incumbent channel. A property with a good generator has no way to say the one thing a local traveller most wants to know.

The user's framing was exact: *"focus on the africa region with low cost fees"*, and *"check the existing standard as other built theirs and integrate"*. §3 is the second half of that.

## Analysis

### Why a stay is not a rental, even though both are date ranges

This is the distinction that decides the schema, and getting it wrong is the classic mistake in the category.

**A rental sells a unit. A stay sells a type.** ADR-0028 sells you *that* Land Cruiser, plate TN-4471, and the constraint is that nobody else can have it over your interval. A hotel sells you *a* chambre double standard, of which it has eight. Which physical room you get — 214 or 309 — is decided by the front desk at check-in and is none of the platform's business. Modelling stays as units would mean the platform allocating room numbers, which no hotel would accept and which breaks the moment they upgrade someone.

So the availability mechanism is genuinely different:

- Rental: an **exclusion constraint** over intervals on a unit. Overlap is impossible.
- Stay: a **per-night counter** per room type. Overbooking is impossible because a count cannot exceed an allotment.

```sql
CREATE TABLE stay_availability (
  room_type_id UUID NOT NULL REFERENCES stay_room_types(id) ON DELETE CASCADE,
  night        DATE NOT NULL,
  allotment    INTEGER NOT NULL,
  sold         INTEGER NOT NULL DEFAULT 0,
  closed       BOOLEAN NOT NULL DEFAULT FALSE,

  PRIMARY KEY (room_type_id, night),
  CONSTRAINT stay_availability_not_oversold CHECK (sold <= allotment),
  CONSTRAINT stay_availability_sane CHECK (allotment >= 0 AND sold >= 0)
);
```

`CHECK (sold <= allotment)` is the structural guarantee, and it is the same class of thing as the ledger's balance constraint and rental's exclusion constraint: the database refuses, whatever the application believes.

**A three-night stay touches three rows and must touch them in one transaction, `ORDER BY night`.** Locking them in a different order in two concurrent bookings is a deadlock, and it is the single most common bug in this category. Written into the ADR rather than a code comment, because it is the kind of thing that gets refactored away by someone who does not know why the `ORDER BY` is there.

### Nights, not days

A stay from the 3rd to the 6th is **three nights**, and the 6th is not sold. Off-by-one here is the most common bug in the whole category and it shows up as phantom availability on checkout days.

The domain gets a type whose job is to make it unrepresentable:

```dart
final class StayPeriod {
  StayPeriod({required this.checkIn, required this.checkOut})
      : assert(checkOut.isAfter(checkIn));
  final DateTime checkIn;   // a DATE, in the market's timezone
  final DateTime checkOut;
  int get nights => checkOut.difference(checkIn).inDays;
  /// The nights actually sold: [checkIn, checkOut). Never includes checkOut.
  List<DateTime> get nightsCovered => ...;
}
```

Every availability read and write goes through `nightsCovered`. Nothing anywhere iterates dates by hand.

### The fourth seam arrives: rate plans

ADR-0017 warned that a fourth seam would mean re-examining it. `11-air.md` §3.4 found one — fare families — and deferred it, correctly, because air can ship one fare per cabin section.

**Stays cannot defer it.** *Non-remboursable, −15%* against *Tarif flexible, annulation gratuite jusqu'à 18h la veille* is not a discount; it is how the category prices, it is what a revenue manager tunes, and a property that cannot express it will not list. It is also what makes prepayment acceptable to a traveller who is nervous about it: the flexible plan is the trust product and the non-refundable one is the cheap product, and offering both is the honest way to sell prepayment in a market that distrusts it.

A rate plan is a bundle of four things sold as one: a price, a cancellation rule, an inclusion set (breakfast or not), and a payment timing. That is not a `PriceModifier` and must not be smuggled in as one.

`RatePlan` lives in `bel_stay` and nowhere else. When a carrier eventually asks for fare families, air writes its own type in `bel_domain` and **borrows the design, not the code** — `bel_domain` may not import `bel_stay` (ADR-0027 §1, §7).

### Payment timing, and why it decides whether we get supply

The single biggest obstacle to signing small properties is that they do not want a channel holding their money, and their guests do not want to prepay a place they have not seen.

```dart
enum PaymentTiming {
  /// Paid in full at booking, through our rails. The property is paid on the
  /// normal payout cycle, commission netted at source.
  prepaid,

  /// The guest pays the property directly at check-in. We take a small
  /// booking fee from the GUEST at booking, and no commission from the
  /// property at all.
  payAtProperty,

  /// First night prepaid to hold the room; the balance at the property.
  firstNight,
}
```

`payAtProperty` is the one that unlocks supply, and it has a real commercial problem: we cannot net a commission at source from money we never touch, and invoicing small properties for commission means chasing them — which `04-payments.md` §6.2 exists to avoid.

**Decision: on `payAtProperty` the property pays no commission, and the guest pays a booking fee.** The fee is small, flat, per booking, disclosed before payment, collected on our rails, and it does three jobs at once: it makes the channel free for the property (which is the pitch), it is collectible without chasing anybody, and **a booking that cost something is a booking somebody turns up for** — no-shows are the thing that makes properties distrust free channels.

`firstNight` is the middle option and is likely where most properties settle once they trust the channel.

### Rooms are sold on photographs

This is a real product requirement the codebase does not have. Today there is `operators.logo_asset`, `operators.cover_asset`, `vehicles.photo_asset` and a single-asset route at `console/v1/vitrine/[asset].dart`. Stays need ordered galleries per property and per room type, with generated thumbnails, on connections where a 4 MB hero image is a lost booking.

Two rules that are policy, not engineering:

- **No stock photography.** A property uploads photographs of itself or it does not list. This is the difference between a channel a traveller trusts and a catalogue.
- **Photos are dated.** Each one carries the date it was uploaded, shown on the gallery. A 2019 photograph of a room is a claim about today, and letting a property make that claim silently is how a channel loses its reputation.

### The amenities that matter here

A closed vocabulary, because free text cannot be filtered on and every property would write the same thing differently. The list is chosen for this market and it is the most important product decision in the ADR:

`groupe_electrogene` · `eau_chaude` · `climatisation` · `wifi` · `parking_garde` · `petit_dejeuner` · `restaurant` · `piscine` · `blanchisserie` · `navette_aeroport` · `securite_24h` · `ascenseur` · `chambre_familiale` · `acces_pmr` · `paiement_mobile_sur_place`

The first two are the differentiators no incumbent offers, and `groupe_electrogene` deserves more than a checkbox: a property can state its **backup power hours**, because "we have a generator" and "the generator runs all night" are different products and every traveller here knows it.

## Decision — the standards question

The user asked to check what others have built and integrate. Here is the answer, in full, because "we looked at the standards" is worth nothing without saying which and what we did about them.

### 3.1 What the standards actually are

- **OTA (OpenTravel Alliance)** XML — `OTA_HotelAvailRQ/RS`, `OTA_HotelResRQ/RS`, `OTA_HotelRateAmountNotifRQ`. The lingua franca between channel managers and OTAs since the early 2000s. Verbose, XML, and universally supported.
- **HTNG** — property-systems interop, mostly relevant inside large hotels.
- **ARI** — *Availability, Rates and Inventory*. Not a protocol but the universal three-part shape every channel manager pushes: how many rooms are open per night, what they cost per night per rate plan, and what restrictions apply (minimum stay, closed to arrival, closed to departure, stop-sell).
- **Channel managers** with real presence in Africa: SiteMinder, Cloudbeds, eZee, Hotelogix, RoomRaccoon. Each speaks OTA XML or a JSON dialect of the same ARI shape.
- **Rating scales.** Booking.com uses 1–10 with sub-scores; Airbnb and Google use 1–5. Official star classification is a separate, government-issued thing and many properties in Congo are unclassified.
- **Restrictions everyone implements:** minimum length of stay, maximum length of stay, closed to arrival, closed to departure, stop-sell, release period.

### 3.2 What we adopt

**The ARI shape, exactly.** `stay_availability` is the A and the I; `stay_rate_prices(rate_plan_id, night, price_minor)` is the R; the restriction columns sit beside them with the standard names. This is not deference to a standard for its own sake — it is that a decade of channel managers converged on this shape because it is the shape of the problem.

**The standard restriction vocabulary**, spelled as everyone spells it: `min_stay`, `max_stay`, `closed_to_arrival`, `closed_to_departure`, `stop_sell`. When somebody eventually maps a channel manager onto this, every field has an obvious counterpart, and nobody has to guess what our clever name meant.

**1–5 stars for guest ratings** (ADR-0030). Not Booking's 1–10. The reason is regional: users here read Google Maps ratings, and a 1–5 scale is the one they can interpret without being taught. Half-star display.

**Star classification kept separate and nullable.** `stay_properties.star_rating` is the official classification where one exists, and null where it does not — which is most properties. Never computed from reviews, never displayed as though it were.

### 3.3 What we do not adopt, and when that changes

**No channel-manager integration in v1.** The overwhelming majority of properties in the target supply have no PMS at all — their inventory lives in a paper ledger or a spreadsheet. Building an OTA XML connector first would serve the small minority already served by the incumbents, at the cost of the majority who are the reason to do this.

Inventory is managed directly in our console, exactly as coach operators manage timetables. The console is the product for this supply, and it has to be good enough that a receptionist can keep it current on a phone.

**But the model is ARI-shaped on purpose.** When a property with SiteMinder wants to list, the connector is an adapter over `stay_availability` and `stay_rate_prices` — no migration, no remodelling. That is what "integrate" means at this stage: build so the standard fits later, rather than paying for it now.

**No OTA XML surface of our own**, in or out. We are not a channel manager.

## Decision — the model

**Stays ship as their own vertical — `packages/bel_stay`, schema `stay`, routes under `/stay/v1/`, a feature package in the traveller shell — with room types on per-night allotments, rate plans, three payment timings including pay-at-property, a market-specific amenity vocabulary, and no channel-manager integration in v1.**

Tables, all in schema `stay` (`13-stays.md` §5 has the DDL): `properties`, `room_types`, `rate_plans`, `availability`, `rate_prices`, `restrictions`, `photos`, `reservations`, `guests`. Every one of them may reference `public.operators`; nothing in `public` may reference any of them, and `infra/migrations/check.sh` fails the build if that direction is ever reversed (ADR-0027 §2).

Money moves through the one narrow shared seam: a `public.payables` row with `subject_kind = 'stay'` and an opaque `subject_ref`. On `payAtProperty` the payable is the guest's booking fee alone, which is the whole mechanism by which a property that pays no commission still produces a collectible transaction.

An operator with `stay` in `offerings` (ADR-0027 §4) owns one or more properties. **A property is not an operator.** A small chain has one operator row, one contract, one payout account and three properties — and modelling a property as an operator would give it three contracts and three payout runs.

The fulfilment artefact is a **voucher**: a public token URL (`t/[token]`, ADR-0026) showing the property, the address and map link, the dates, the room type, the guest names, the price breakdown, what is included, the cancellation deadline as an absolute local instant, the payment timing and what remains to pay, and the property's telephone number. It is not scanned. The front desk reads the reference.

Check-in and check-out times, the late-arrival window and the no-show hour live in `StayWindowPolicy` — stays' own type, in `bel_stay`, with no supertype shared with air's `BoardingPolicy` or rental's `HandoverPolicy` (ADR-0027 §7).

Guest data lives in `GuestRequirements`, stays' own type. The lead guest's name and phone are required; an ID number is `optional` and captured only where a property requires it; **a driving licence is `hidden` and a passport is `hidden` for a domestic stay** — the ADR-0017 rule implemented for the fourth time, independently, in the fourth package. Four small implementations of one rule, rather than one type with four disjoint regions (ADR-0027 §7).

## Consequences

**Good.** The largest supply of any vertical here, addressable at a third of the incumbent's commission, on payment rails the incumbents do not have. Pay-at-property removes the two objections that block small properties. The amenity vocabulary says things no competitor can say. Reviews (ADR-0030) are worth more here than anywhere else in the product, because a hotel is the purchase people most want other people's opinion of.

**Bad.** The biggest surface in the roadmap: property management, room types, a rate-plan engine, a per-night availability calendar, restrictions, a photo pipeline, a different search shape, a voucher, and a cancellation model in nights. Photo storage and thumbnailing is genuinely new infrastructure. The console must be usable by a receptionist on a phone, which is a higher bar than the coach console had to clear.

**Risk — inventory staleness.** A property that stops updating its calendar produces the worst failure in the category: a confirmed booking with no room. Mitigations, all in `13-stays.md`: a release period so a stale allotment closes itself rather than overselling, a "last updated" age on the console dashboard, a nightly reminder to properties whose calendar is ageing, and an overbooking incident flow that finds and pays for alternative accommodation before it becomes a review.

**Risk — competing with well-funded incumbents.** We do not win on selection or brand. We win on commission, on payment rails, on the specific vocabulary of this market, and on being the channel that pays out in XAF to a mobile-money number the same week. If those four are not enough, the vertical does not work, and it will be visible within one quarter of the pilot.

**Risk — focus, again.** ADR-0027's gate stands: a vertical ships whole — search to money to artefact to review — or it does not ship. Stays is the largest bet in this document and it must not start until the bus product's commercial gates are cleared or clearly stalled.
