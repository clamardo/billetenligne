# ADR-0028 — Vehicle rental

**Status:** Accepted · **Date:** 2026-08-14 · **Depends on:** ADR-0027 · **Reads with:** `12-rental.md`

## Context

Renting a car in Brazzaville or Pointe-Noire is a phone call. The companies exist, they have real fleets, and every booking is a WhatsApp thread, a verbal price and a handshake at a counter. Across most of the region it is the same. The failure modes are the ones the coach industry had before this product: you cannot see what is available, you cannot see what it costs until you ask, and you have no proof of anything until you are standing at the desk.

Three facts about this market that are not true of the European one, and each changes the model:

**Chauffeur-driven is not an upsell, it is often the default.** *Voiture avec chauffeur* is how a large share of business rental is sold here. The customer does not want a licence check, does not want to drive Brazzaville traffic, and expects a driver included. A model that treats "with driver" as an extra checkbox has the product backwards.

**Vehicle class is about the road, not the badge.** The difference that decides a booking is whether it can do the route: a 4×4 or a pickup for anything off the paved corridor, versus a saloon for in-town. Engine size and leather seats are not the axis. A class vocabulary copied from Hertz would sort the fleet by the wrong property.

**The security deposit has no rail.** Card pre-authorisation — the mechanism the entire global rental industry rests on — does not exist on mobile money. MTN and Airtel take money or they do not; there is no hold, no capture, no release. This is the single hardest constraint in the feature and §5 is about nothing else.

## Analysis

### Why this is not a `TransportMode`

Settled by ADR-0027 §2. A rental is an occupancy of one specific unit over a continuous interval; a departure is an event with a capacity. Forcing one into the other corrupts search, availability, the seat map, the manifest, the scanner, IRROPS and the segment model.

ADR-0027 also rejects the subtler unification — one `InventoryKind` enum, one polymorphic `bookings` row, one set of seam types stretched over every vertical. Rental is **its own domain package, its own Postgres schema and its own API surface**: `packages/bel_rental` on top of `bel_platform`, schema `rental`, routes under `/rental/v1/`. It does not import `bel_domain` and `tool/check_layers.dart` fails the build if it ever does.

### Why it is not a separate product either

Also ADR-0027. The rental flow needs operators, KYB, staff RBAC, identity, `Money`, the ledger, commission netted at source, payouts, statements, refunds, notifications, localization, the design system, the vitrine and the deployment. Every one of those exists and is tested. The genuinely new surface is inventory, availability, one artefact and one operational flow.

### The one thing that must be structurally impossible

A double-booked car is the failure that ends the business relationship, because unlike an oversold coach there is no next seat — there is one Land Cruiser and two people at the counter.

For departures, that guarantee comes from seat holds inside a transaction. For rentals it comes from Postgres directly:

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE rental_occupancies
  ADD CONSTRAINT rental_occupancies_no_overlap
  EXCLUDE USING gist (
    vehicle_id WITH =,
    period     WITH &&
  ) WHERE (state <> 'released');
```

Two overlapping occupancies of one vehicle cannot exist, whatever the application does. That is the same class of guarantee as the ledger's `CHECK` that a transaction balances at `COMMIT`, and it is chosen for the same reason: a constraint the database enforces survives a refactor, and application-level locking does not.

The `period` is a `TSTZRANGE` and is **half-open**, `[pickup, return)`. A car returned at 10:00 is rentable at 10:00. Getting this wrong in the other direction costs an operator a booking a day, every day, silently.

Buffer time between rentals — cleaning, refuelling, inspection — is an operator setting that widens the stored period, not a second concept. A 2-hour buffer means the stored range ends two hours after the contracted return, and the customer never sees it.

### The driver is inventory too

If chauffeur-driven is a first-class product, a driver is a resource with availability, and two rentals cannot have the same driver. That is the identical constraint on a different table, and it is worth building the same way rather than inventing a scheduling system:

```sql
ALTER TABLE rental_driver_assignments
  ADD CONSTRAINT rental_driver_no_overlap
  EXCLUDE USING gist (driver_id WITH =, period WITH &&)
  WHERE (state <> 'released');
```

An operator with three cars and one driver can sell three self-drive rentals or one chauffeur-driven one, and the schema says so without anybody writing that rule down.

### Compliance is a gate we can actually enforce

Congolese law requires a vehicle to carry valid insurance and a technical inspection. Operators know this and mostly comply; what nobody has is a system that *notices* when a certificate lapses.

`kyb_documents` already carries `doc_type`, `expires_at`, `verified_at` and a partial index on expiry, and migration `0032_document_expiry.sql` already runs the expiry machinery. The only thing missing is that the documents are operator-scoped and these are vehicle-scoped.

**A vehicle whose insurance or inspection has expired is not rentable.** Not a warning — removed from search, refused at booking, and the operator is told which document and when. This is a genuine trust differentiator that costs one nullable column and one predicate, and it is the kind of thing a customer cannot verify for themselves and would very much like someone to have checked.

### Identity, and what we will not claim

A rental hands a stranger an asset worth 15–40 million XAF. The identity question is categorically more serious than for a coach seat.

We are not going to verify identity documents, and we should not pretend to. There is no reliable document-verification service for Congolese national IDs, and a green tick we cannot stand behind is worse than no tick.

What the platform does instead is **make the operator's existing check happen earlier**: the driver's licence number, its category, its issue date and an ID number are captured at booking and shown to the operator immediately. An operator who is going to refuse this customer refuses them before the customer drives across town, and both parties are better off. The physical documents are still checked at handover, by the person handing over the keys, exactly as today.

## Decision

**Vehicle rental ships as its own vertical — `packages/bel_rental`, schema `rental`, routes under `/rental/v1/`, a feature package in the traveller shell — with overlap-proof availability, chauffeur-driven as a first-class option, a handover artefact instead of a boarding scan, and no platform custody of security deposits in v1.**

### 1. The model

Six new tables (`12-rental.md` §5 has the DDL):

- `rental_branches` — a pickup and return point. **Not `stations`.** A station is a coach terminal with boarding semantics, `is_boarding`/`is_alighting` flags and a position on a road (ADR-0025). Overloading it would repeat the mistake ADR-0027 exists to prevent.
- `rental_vehicles` — one physical unit: class, transmission, seats, fuel type, air conditioning, plate, home branch, photos, odometer, status.
- `rental_vehicle_documents` — insurance and inspection, with expiry. Same shape as `kyb_documents`, vehicle-scoped.
- `rental_rates` — per class or per unit, with daily / weekly / monthly tiers and a `PriceModifier` for weekend and season. `PriceModifier` already exists in `bel_domain` and is reused rather than re-invented.
- `rental_occupancies` — the exclusion-constrained table above. Holds, bookings and operator blocks are all occupancies with a state; a maintenance block and a customer booking compete for the same car through the same constraint, which is the point.
- `rental_agreements` — the artefact. Handover and return condition, odometer, fuel level, photos, and both acceptances.

Plus `rental_driver_assignments` for the chauffeur case.

**There is no link to `bookings`.** `bookings` is transport's aggregate and stays transport's (ADR-0027 §2). A rental's money moves through the one narrow shared seam: the vertical writes a row into `public.payables` with `subject_kind = 'rental'` and its own opaque `subject_ref`, the platform collects on whichever rail the customer chose, nets commission and posts a balanced pair of ledger entries, and the vertical moves its own occupancy to `confirmed` when settlement lands. The platform never learns what a Land Cruiser is.

### 2. `VehicleClass` — a vocabulary for these roads

```dart
enum VehicleClass { citadine, berline, suv, quatreQuatre, pickup, minibus, utilitaire }
```

Named for what the vehicle *does*. `quatreQuatre` and `pickup` are separate because a pickup carries goods and a 4×4 carries people, and in this market that is the question being asked. Displayed from the catalog, never from the enum name.

### 3. Chauffeur-driven is a mode of the rental, not an extra

`RentalBooking.withDriver` is a boolean chosen at search time, filterable, priced as a separate daily rate, and it **changes what we may ask for**: a chauffeur-driven rental asks for no driving licence at all, because the customer is a passenger.

That conditionality is why `DriverRequirements` — rental's own type, in `bel_rental`, with no supertype shared with air's `PassengerRequirements` (ADR-0027 §7) — is data rather than a fixed form. It implements the one rule that does carry across every vertical: three states, with `hidden` distinct from `optional`, and a test whose only job is to fail if a licence number is ever stored on a chauffeur-driven rental.

### 4. The artefact is an agreement, not a ticket

There is no door and nothing to scan. The fulfilment artefact is a rental agreement, reachable at a public token URL the way a ticket is (`t/[token]`, ADR-0026), showing: the vehicle, the period, the branch, the price breakdown, the fuel and mileage policy, the deposit amount and who holds it, and the handover and return condition reports.

Handover is a two-party act: the operator records odometer, fuel level and up to eight condition photos, and the customer accepts on their own handset or on the operator's. Return repeats it. **The photos are the product.** Every dispute in vehicle rental is about damage, and a timestamped pair of condition reports that both parties accepted is worth more than any clause.

Acceptance is a tap with a timestamp and an audit row. It is deliberately **not** claimed to be a qualified electronic signature — we are not going to assert a legal standard we have not met.

### 5. The security deposit — the constraint with no clean answer

Card pre-authorisation does not exist on mobile money. Options, and why each fails:

- **Take the deposit as a real payment and refund it.** Technically possible — the disbursement machinery from migration `0042` can pay it back. But the platform would hold real customer cash for the rental period, on a balance sheet with no licence to do so, and would owe a refund the moment anything goes wrong. That is a regulated activity, not a feature.
- **Take it and pass it to the operator.** Then the platform is visibly the party that took the money and invisibly not the party who has it. Every deposit dispute becomes our support ticket for money we never held.
- **Card pre-auth only.** Excludes the great majority of customers in this market, which is the opposite of the point.

**Decision: in v1 the platform does not touch the security deposit.** The operator collects it at handover by whatever means they already use — cash, their own terminal, a mobile-money transfer to their own number. The platform's job is that **nobody is surprised**: the deposit amount, the form it must take and who holds it are displayed at search, at booking, on the confirmation, in the SMS and on the agreement.

That is not a workaround. It is what the market already does, and displaying it honestly is a real improvement over finding out at the counter. Card pre-authorised deposits are a later slice, gated on a card acquirer existing at all — and there is no merchant account for this market today.

The corollary, and it is a bug waiting to happen: **the deposit is never part of the commissionable base.** `commission_bps` applies to the rental fare and nothing else. Written down here because a deposit that flowed through a total would silently take a percentage of somebody's returnable money.

### 6. Fuel and mileage

Rental's own inclusions types, in `bel_rental`. **No shared supertype with air's baggage allowance** (ADR-0027 §7): a kilogramme and a kilometre share a sentence and nothing else, and any type over them would be a name.

```dart
enum FuelPolicy { fullToFull, sameToSame, prepaidFull }
final class MileagePolicy { final int? includedKmPerDay; final Money? perExtraKm; }
```

`fullToFull` is the default and the fairest. Unlimited mileage is `includedKmPerDay == null` and is common here for in-town rentals. Excess mileage and fuel shortfall are **quoted, settled at return with the operator, and not sold by the platform** — the same decision as excess baggage in `11-air.md` §3.3, for the same reason: it requires an ancillary product line, and the amount is not known until the car comes back.

### 7. One-way rentals

Pickup at one branch, return at another, with a drop fee per branch pair. Supported in the model from day one because retrofitting a second location onto an occupancy is painful, and shown in the UI only when the operator has more than one branch.

## Consequences

**Good.** A category with no online option anywhere in the market, on rails that already work. High value per transaction — a five-day 4×4 rental is worth thirty coach seats — against a commission rate that is already generous by regional standards. Double-booking is impossible by construction. Expired insurance becomes visible, which nothing else in this market does.

**Bad.** A second availability mechanism to understand and test. `btree_gist` is a new extension dependency in every environment including CI. The console gains a whole fleet-and-calendar surface. Condition photos are a real asset-storage requirement — several megabytes per rental, retained for the dispute window.

**Risk, and it is the honest one.** The deposit decision means the platform is not in the loop on the part of the transaction with the most money and the most conflict. An operator who mishandles deposits damages our brand while we hold no lever. The mitigation is reviews (ADR-0030), the operator lifecycle's suspension states, and displaying the deposit terms so prominently that a bad actor's terms are visible before anyone books.

**Risk.** Fraud. A stolen vehicle is an uninsurable loss for a small operator and they will blame the channel that sent the customer. We do not verify identity and we say so. If this becomes the thing that kills the vertical, the answer is a deposit rail and a verification partner — both of which are commercial, not engineering.
