# ADR-0027 — Verticals are separate; the platform is shared

**Status:** Accepted · **Date:** 2026-08-14 · **Amends:** ADR-0017 · **Governs:** ADR-0028, ADR-0029, ADR-0030

## Context

ADR-0017 answered one question — *is air a second product or a mode of this one?* — and answered it with a first-class `TransportMode`. That was right, and `11-air.md` shows why: the inventory model needed almost no change, because an aircraft and a coach are the same shape of thing. A dated, timed event, with a capacity, sold as seats, boarded at a door.

Two new verticals arrived together, and neither is that shape.

**Car rental.** There is no meaningful way to rent a car online in Congo, and largely none across the region. The companies exist, they have fleets, and every booking is a WhatsApp thread and a handshake at a counter.

**Hotels and guesthouses.** Here the incumbents *do* operate — Booking.com, Expedia, Jumia Travel — at 15–18% commission, over a thin and skewed slice of the actual room stock, on a card rail most travellers here do not use, describing African properties with a vocabulary invented for European ones.

Both are obviously the same *business*: an operator with inventory, a customer with a phone, and money that has to move over rails almost nobody else has integrated. The question this ADR answers is what "the same business" licenses in the code.

## Analysis

### The first trap: one more enum value

The tempting move is `TransportMode.car` and `TransportMode.hotel`, because it is a one-line change and everything downstream compiles.

Everything in this system rests on `departures`: a row with a `route_id`, a `departs_at`, an `arrives_at`, a `capacity`, a `seat_layout_id` and a `status`. Sixteen migrations, the search query, the seat map, the hold, the manifest, the boarding scanner, the checkpoint model, the segment model (ADR-0025) and the whole disruption subsystem (ADR-0016) are written against it.

To express a rental car as a departure you would create one departure per car per day, `capacity = 1`, with a one-seat layout. Then: search breaks, because `SearchDeparturesQuery` is (origin, destination, date) and a rental is (place, two dates, class); availability breaks, because a five-day rental is one occupancy and not five bookings; the seat map breaks, because a one-seat cabin section is a drawing of nothing; the manifest breaks, because nobody is aboard; the scanner breaks, because there is no door; IRROPS breaks, because a hotel has no next departure; and the segment model breaks, because a room has no road.

Seven subsystems corrupted to save one enum value. The tell is the direction of the damage: with air, generalising the seat map to cabin sections *improved* the bus case. Here every generalisation makes the existing thing worse.

Rejected, and the reasoning is recorded at this length so that the next person tempted by it can see the bill.

### The second trap, and this one was in the first draft of this ADR

Having rejected the enum, the next move is a *bigger* abstraction: an `InventoryKind { scheduled, rental, stay }` in `bel_domain`, a polymorphic `bookings` row with a discriminator and a nullable foreign key per kind, and one set of seam types — `PartyRequirements`, `ServiceWindowPolicy` — generalised across all three.

That was the first draft of this document, and it is wrong. It is a subtler version of the same mistake: unifying things whose only shared property is that a person paid for them.

What it costs:

- **Every reader handles three shapes.** A booking query that today knows exactly what it is holding becomes a switch, forever, in every consumer.
- **Release cadence couples.** A stays migration touches a table the coach product's boarding flow reads. Nothing about a hotel should be able to break a conductor's scanner at 05:40.
- **The seam types get worse the more they cover.** `PartyRequirements` spanning a coach passenger, an air passenger, a rental driver and a hotel guest is a map of enum values to enum values with four disjoint populated regions. That is not an abstraction; it is four types in a trench coat, and the compiler stops helping.
- **The inclusions "seam" was never one.** Baggage (kg), fuel and mileage (litres and km) and occupancy (beds and breakfast) share a sentence and nothing else. Any supertype over them is a name.

And what it buys: nothing. The models genuinely share nothing above the booking. There is no query that wants a coach seat and a hotel room in the same result set, no operator screen that manages both with one form, and no business rule that spans them.

**The right response to "these are the same business" is not one model. It is one platform under several models.**

### The third trap: separately deployed services, now

The opposite over-correction is three services with three databases, unified only in the app. That is genuinely attractive — independent deploys, independent blast radius, per-vertical scaling — and it is premature here for one concrete reason.

`infra/migrations/verify_unbalanced.sql` proves that an unbalanced ledger transaction is **rejected at `COMMIT`**. That guarantee is a single-database, single-transaction guarantee: a payment settles, the postings are written, the constraint fires, and the whole thing rolls back together or not at all.

Put a service boundary between a stay reservation and the ledger and that becomes a distributed transaction. The honest options are two ledgers — the second copy of a double-entry ledger is exactly where money goes missing — or a saga around settlement, which is a compensating-transaction state machine written by one engineer for a product with nothing deployed to any cloud yet.

There is also a plain operational fact: no environment has ever been applied. Three services before one is running is three of something that is currently zero.

So the boundary is drawn now, hard, in packages and schemas — and the *deployment* stays single until there is a reason. The work to extract a service later should be moving a directory and pointing a client at a new host, not untangling a model.

## Decision

**Each vertical is its own domain, its own schema, its own API surface and its own business model. They share the platform beneath — identity, money, the ledger, the payment rails, operators, notifications, localization and the design system — and they share a shell in the app. They share no inventory model, no seam types and no booking table.**

### 1. Package topology

Today `bel_domain` holds the transport domain and calls itself the domain. It gets a more honest name and three siblings.

```
packages/
  bel_platform      NEW — Money, Currency, market config, the ledger's domain
                          types, payment-rail types, operator identity and
                          lifecycle, staff capabilities, refund-policy
                          machinery, notification types, IDs, time.
                          Knows nothing about seats, cars or rooms.

  bel_domain        transport: departures, routes, seat layouts, cabin
                    sections, TransportMode, tickets, boarding, disruption,
                    segments. Depends on bel_platform. Unchanged in content.

  bel_rental        NEW — ADR-0028. Depends on bel_platform. Does NOT depend
                    on bel_domain and must never import it.

  bel_stay          NEW — ADR-0029. Same rule.

  bel_reviews       NEW — ADR-0030. The one genuinely cross-vertical concern,
                    and it depends only on bel_platform.

  bel_contracts     splits the same way: bel_contracts (platform + transport,
                    unchanged), bel_rental_contracts, bel_stay_contracts.
```

`tool/check_layers.dart` gains the rule that makes this real and not a convention:

> **`bel_rental`, `bel_stay` and `bel_domain` may not import one another.** A single import is the whole decision undone, and the checker already walks 447 files to enforce the onion — this is one more edge in the same graph.

`bel_domain` keeps its name. Renaming it to `bel_transport` would touch every file in the repository to express something the dependency graph already says.

### 2. Schema topology

One Postgres cluster, one database, **separate schemas**.

```
public   →  the platform: operators, staff, user_accounts, sessions,
            ledger_accounts, ledger_entries, payment_intents, payouts,
            refunds, disbursements, kyb_documents, cities, markets.
            Migrations 0001–00NN, the sequence that exists today.

rental   →  ADR-0028. Its own migration sequence, rental/0001 onward.
stay     →  ADR-0029. Its own migration sequence, stay/0001 onward.
review   →  ADR-0030.
```

Transport keeps `public` rather than moving, because moving sixteen migrations' worth of live tables to express a boundary is a large risk for a small statement.

**Cross-schema references go one direction only: a vertical schema may reference `public`; `public` may never reference a vertical schema.** A `stay_reservations` row may carry `operator_id UUID REFERENCES public.operators(id)`. Nothing in `public` may carry a `stay_` anything. That single rule is what makes extraction mechanical later, and `infra/migrations/check.sh` gains a check that fails the build if a `public` table grows a foreign key into a vertical schema.

Roles follow: `bel_rental_app` and `bel_stay_app` are new members of the existing role family, granted on their own schema and on exactly the platform tables they need. ADR-0011's rule is unchanged — `bel_api` is `NOLOGIN NOINHERIT` and privileges arrive only through `SET LOCAL ROLE`.

**There is no shared `bookings` table.** `bookings` stays exactly as it is and stays transport's. `rental.occupancies` and `stay.reservations` are their own aggregates with their own states, their own refs and their own lifecycles. Nothing gains a discriminator column, and nothing gains three nullable foreign keys.

### 3. The one narrow shared seam: something has to be paid for

Payment is the only place the verticals touch, and the touch has to be narrow enough to be a wire rather than a coupling.

`public.payables` — a thin platform table that a vertical writes one row into when it wants money collected:

```
payable_id      UUID PK
operator_id     UUID REFERENCES public.operators(id)
subject_kind    TEXT   -- 'transport_booking' | 'rental' | 'stay'
subject_ref     TEXT   -- opaque to the platform; the vertical's own reference
purchaser_id    UUID REFERENCES public.user_accounts(id)
amount_minor    BIGINT
fee_minor       BIGINT
currency        CHAR(3)
commission_bps  INTEGER      -- snapshotted; per vertical, see §6
state           TEXT
```

`subject_ref` is **opaque text and the platform never joins on it.** That is the whole design: the platform can collect money, net commission, post a balanced pair of ledger entries, pay out and refund, without knowing what was sold. A vertical listens for the settlement and moves its own aggregate to `confirmed`.

This is also the extraction seam. The day stays becomes its own service, it calls a platform API to create a payable and consumes a settlement event — and the ledger stays in one place, in one transaction, with its constraint intact.

### 4. One flat vocabulary at the edges

Two axes in the code, four products at a segmented control. The flattening happens at exactly three places and nowhere else:

- `public.operators.offerings TEXT[]` — `bus`, `air`, `rental`, `stay`. The capability flag ADR-0017 asked for, generalised. Settable **only** by platform staff; an operator granting itself the right to sell flights is a capability flag that does not work.
- `MarketDto.offerings` — which products this market sells, from `config/markets.yaml`, cached against an ETag, so enabling a vertical is a config push rather than an app release. Same argument as the payment rails (ADR-0006), in a market where many users never update.
- The traveller app's chooser, which renders only when the market sells more than one.

`offerings` is a **configuration and presentation vocabulary**. No domain package defines it, and nothing in `bel_platform`, `bel_domain`, `bel_rental` or `bel_stay` switches on it.

### 5. The app: one shell, four feature packages

The user's framing was exact — *"living in the same UX as frontend microservice"* — and Flutter expresses that with package boundaries and a route registry, not a build-time bundle trick.

```
apps/traveller/            the shell: startup, market fetch, theme, sign-in,
                           the chooser, "my bookings", the deep-link router.
                           Depends on every feature package and on none of
                           their internals.

packages/bel_feature_transport   search → seat map → hold → passengers → pay
                                 → ticket. The screens that exist today,
                                 lifted out of apps/traveller unchanged.
packages/bel_feature_rental      its own search, its own flow, its own agreement.
packages/bel_feature_stay        its own search, its own flow, its own voucher.
```

Each feature package exports one object:

```dart
abstract interface class TravelFeature {
  String get offering;                  // 'bus' | 'air' | 'rental' | 'stay'
  Widget buildEntry(BuildContext c);    // its own search screen
  Route<dynamic>? onGenerateRoute(RouteSettings s);
  Future<List<BookingSummary>> myBookings(...);  // for the shared list
}
```

The shell holds a `List<TravelFeature>`, filters it by `market.offerings`, and renders the chooser from what survives. **Adding a vertical adds a package and one line in the registry.** Removing one removes a line. A feature package that is not registered is not compiled into the flows, and no screen in one vertical can import a screen from another — `check_layers.dart` enforces that with the same rule as §1.

The shared surfaces are deliberately few and are all the shell's: sign-in, the chooser, "mes réservations", the ticket/voucher/agreement list, settings, and the deep-link router. Everything else is per vertical.

The console splits the same way: one shell, one navigation built from staff capabilities, and a feature module per vertical, so that a hotel's receptionist never sees a seat-layout builder.

### 6. Separate business models, and that is the point

The verticals are *not* required to share commercial mechanics, and forcing them to would be the same mistake as sharing a model:

- **Transport** — commission netted at source from a prepaid fare, flat service fee per seat, weekly payout. Live today.
- **Rental** — commission on the rental fare only. **The security deposit is never in the commissionable base** and in v1 the platform does not touch it at all (ADR-0028 §5). Deposits flowing through a total would silently take a percentage of somebody's returnable money.
- **Stay** — three payment timings, and on `payAtProperty` the property pays **no commission at all** while the guest pays a small flat booking fee (ADR-0029). That is a different revenue model from every other vertical, and it is the thing that unlocks small-property supply.

Each vertical snapshots its own `commission_bps` onto its own payable. `public.operators.commission_bps` remains the opening number for a contract, per `04-payments.md` §6.2, and a vertical is free to derive from it or ignore it.

### 7. Seams are named per vertical and never generalised

ADR-0017 named three seams and warned: *"If a fourth seam appears, that is a signal to re-examine this ADR."* This is the re-examination, and the finding is that the warning was aimed at the wrong risk. The danger was never too many seams; it was one seam stretched over too many verticals.

- Transport keeps `PassengerRequirements`, `BoardingPolicy` and `BaggagePolicy`, named for transport, living in `bel_domain`. `11-air.md` is unchanged.
- Rental defines `DriverRequirements`, `HandoverPolicy`, `FuelPolicy` and `MileagePolicy` in `bel_rental`.
- Stays define `GuestRequirements`, `StayWindowPolicy`, `RatePlan` and `InclusionsPolicy` in `bel_stay`.

**No supertype is created over any of these.** They are similar in shape and unrelated in content, and the similarity is a fact about people buying things, not a fact about the code.

What *does* carry across, and carries as a rule rather than a type, is ADR-0017's one hard-won principle:

> A Congolese coach passenger must never be asked for a passport number because the aircraft schema has the field.

Every vertical implements it independently, and each implements it the same way: a three-state field requirement where `hidden` is distinct from `optional`, and a test whose only job is to fail if a field from one context is ever stored in another. A hotel guest is never asked for a driving licence number because the rental schema has one.

### 8. When a vertical becomes a service

Not on a schedule and not on a feeling. Any one of these is sufficient:

- A second engineer owns a vertical end to end and is blocked by another vertical's release cadence.
- A vertical's read load meaningfully affects another's latency.
- A vertical needs a different data residency or retention regime.
- A vertical is sold, spun out, or run by a partner.

Until then the boundary is real and the deployment is one. The §1 package rule, the §2 schema rule and the §3 payable seam are what make the eventual split mechanical, and they are worth their cost now even if it never happens — because they are also what stops the four verticals from silently becoming one tangle.

### 9. What must never be duplicated

The list is short and it is the reason this is one platform at all. If a vertical ever gets its own copy of any of these, this ADR has failed:

the double-entry ledger · the payment-rail adapters · operator identity, KYB and lifecycle · user identity and sign-in · the notification outbox · the localization catalog · the design system · payouts, statements and disbursement.

## Consequences

**Good.** Each vertical is understandable on its own, in its own package, with its own schema and its own tests. A stays migration cannot break a conductor's scanner. The seam types stay sharp because each covers one context. The business models are free to differ, which they must. The app is a shell plus registered features, so a vertical ships or ships dark by one registry line and a config push. Extraction to a service later is moving a directory.

**Bad.** More packages, more migration sequences, more roles, more grant surface, and a layering checker with more to say. Some genuine duplication: three search screens, three "my bookings" shapes, three console modules. That duplication is chosen — it is what buys the independence, and the alternative was the polymorphic booking row this ADR spent §2 rejecting.

**Risk — the shared platform becomes the tangle instead.** `bel_platform` is now the thing everything depends on, and the pressure will be to put "just one more" vertical-specific type in it. The rule is that a type belongs in `bel_platform` only if **at least two verticals need it and neither owns it**. A type used by one vertical belongs to that vertical, no matter how general it looks.

**Risk — focus.** `09-roadmap.md`'s first line has been true since it was written: *the long poles are commercial, not technical.* Nothing here moves a telco merchant application or an anchor operator LOI one day closer, and a clean four-vertical architecture makes it easier to feel productive while neither happens. The gate stands: **a vertical ships whole — search to money to artefact to review — or it does not ship.**
