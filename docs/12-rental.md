# BilletEnLigne — Vehicle rental, end to end

**Status:** Specification and implementation roadmap · **Date:** 2026-08-14 · **Implements:** [ADR-0028](adr/0028-vehicle-rental.md) · **Governed by:** [ADR-0027](adr/0027-verticals-are-separate.md) · **Reads with:** [ADR-0030](adr/0030-reviews.md), [`14-reviews.md`](14-reviews.md)

## 0. What this document is

ADR-0028 decided what rental is and what it is not. This says how to build it: every package, schema, column, DTO, route, screen and test, in dependency order.

Written to be executed by somebody who has not read the rest of the repository. Three things to hold onto before starting:

1. **Nothing here reuses the transport model, and that is deliberate.** `packages/bel_rental` may not import `bel_domain`, and `tool/check_layers.dart` fails the build if it does. If a rental type starts to look like a departure, that is the signal to re-read ADR-0027 §2, not to add an import.
2. **Double-booking is prevented by the database, not by the code.** §4 is the most important section in this document. Application-level checking of overlaps is a race condition with good intentions.
3. **The platform does not touch the security deposit.** ADR-0028 §5 explains at length why. Every screen that shows a price shows who holds the deposit and in what form.

---

## 1. Current state

There is no rental anything. `grep -ri 'rental' --include=*.dart --include=*.sql --include=*.yaml .` returns nothing outside these documents.

What exists and is reused unchanged: operators and their KYB documents, the self-serve application wizard (`03-operator-lifecycle.md`, migration `0015`), staff accounts and capability-driven navigation, email sign-in and TOTP, `Money` and the market's currency handling, the double-entry ledger, all five payment rails, refunds and disbursement, the notification outbox, the localization catalog, the Kilo design system, the vitrine, the public-token artefact pattern, and the whole of `infra/`.

That reuse is the entire business case. What follows is only the part that is new.

---

## 2. Prerequisite: the platform split

**[`15-platform-split.md`](15-platform-split.md)** — slices P1–P5. Blocking, and shared with stays: whichever vertical starts first builds it, the other gets it free.

In one paragraph: `bel_platform` is extracted out from under `bel_domain` — 19 of its 38 files, 2 802 of its 6 862 lines, with zero overlap in public type names. `tool/check_layers.dart` gains the rule that `bel_domain`, `bel_rental` and `bel_stay` may not import one another. The migration runner learns per-schema sequences so `infra/migrations/rental/` has its own ledger without disturbing the 45 rows already applied. `check.sh` learns that no table in `public` may hold a foreign key into a vertical schema. And `public.payables` becomes the one narrow seam through which rental asks for money, carrying an opaque `subject_ref` the platform never joins on.

Rental additionally needs P4's schema and role: `rental`, and `bel_rental_app` as a new member of the existing role family, granted on its own schema and on exactly the platform tables it reads.

---

## 3. The domain — `packages/bel_rental`

All of this is pure Dart with no I/O, in `packages/bel_rental/lib/src/`.

### 3.1 What a vehicle is

```dart
/// Named for what the vehicle DOES on these roads, not for a market segment.
/// `quatreQuatre` and `pickup` are separate because a pickup carries goods
/// and a 4x4 carries people, and that is the question being asked here.
enum VehicleClass { citadine, berline, suv, quatreQuatre, pickup, minibus, utilitaire }

enum Transmission { manuelle, automatique }
enum FuelType { essence, diesel, hybride, electrique }

final class RentalVehicle {
  const RentalVehicle({
    required this.id,
    required this.operatorId,
    required this.branchId,
    required this.vehicleClass,
    required this.make,
    required this.model,
    required this.year,
    required this.transmission,
    required this.fuel,
    required this.seats,
    required this.registration,
    this.airConditioning = true,
    this.photos = const [],
    this.status = VehicleStatus.active,
  });
  // ...
}

enum VehicleStatus { active, maintenance, retired, blockedCompliance }
```

`blockedCompliance` is set by the expiry job in §10 and is the reason §3.5 exists.

### 3.2 The period, and the half-open rule

```dart
/// A rental interval. Half-open: [pickup, dropOff). A car returned at 10:00
/// is rentable at 10:00, and the other convention silently costs an operator
/// a booking a day.
final class RentalPeriod {
  RentalPeriod({required this.pickup, required this.dropOff})
      : assert(dropOff.isAfter(pickup));
  final DateTime pickup;
  final DateTime dropOff;

  /// Billable days, rounded UP. Four hours is a day; 25 hours is two. This
  /// is how the market prices and how every customer expects it to work.
  int get days => (dropOff.difference(pickup).inMinutes / 1440).ceil();
  Duration get duration => dropOff.difference(pickup);
}
```

### 3.3 Pricing

```dart
final class RentalRate {
  const RentalRate({
    required this.dailyMinor,
    this.weeklyMinor,     // 7+ days
    this.monthlyMinor,    // 28+ days
    this.driverDailyMinor,
    this.modifiers = const [],
  });
  // `PriceModifier` is a platform type (P2) and is reused for weekend and
  // season adjustments rather than re-invented.
}

final class RentalQuote {
  final int days;
  final Money base;          // tier price x days
  final Money driver;        // zero when self-drive
  final Money oneWayFee;     // zero when returning to the pickup branch
  final Money serviceFee;    // the market's flat fee
  final Money total;
  final Money deposit;       // DISPLAYED ONLY. Never in `total`. See §3.6.
}
```

**`deposit` is never a term of `total`.** A single test asserts it, and it exists because a deposit inside a total would silently take `commission_bps` of somebody's returnable money (ADR-0027 §6).

### 3.4 Who may drive

```dart
enum DriverField { fullName, phone, idNumber, licenceNumber, licenceCategory, licenceIssued, dateOfBirth }
enum FieldRequirement { hidden, optional, required }

final class DriverRequirements {
  const DriverRequirements(this.fields);
  final Map<DriverField, FieldRequirement> fields;
  FieldRequirement of(DriverField f) => fields[f] ?? FieldRequirement.hidden;

  /// The customer drives. Licence details are required.
  static const selfDrive = DriverRequirements({
    DriverField.fullName: FieldRequirement.required,
    DriverField.phone: FieldRequirement.required,
    DriverField.idNumber: FieldRequirement.required,
    DriverField.licenceNumber: FieldRequirement.required,
    DriverField.licenceCategory: FieldRequirement.required,
    DriverField.licenceIssued: FieldRequirement.required,
    DriverField.dateOfBirth: FieldRequirement.required,
  });

  /// The operator drives. The customer is a passenger and is asked for
  /// NOTHING about a licence — every licence field is `hidden`, not
  /// `optional`. This is ADR-0017's rule implemented for the third time.
  static const chauffeured = DriverRequirements({
    DriverField.fullName: FieldRequirement.required,
    DriverField.phone: FieldRequirement.required,
    DriverField.idNumber: FieldRequirement.optional,
  });

  static DriverRequirements forBooking({required bool withDriver}) =>
      withDriver ? chauffeured : selfDrive;
}
```

Minimum age and minimum years held are operator settings checked against `dateOfBirth` and `licenceIssued` at booking, with the defaults 21 and 2. A refusal names which rule and by how much — *"le conducteur doit avoir 21 ans; date de naissance saisie: 19 ans"* — because a bare "refusé" produces a support call.

### 3.5 Handover, and the inclusions

```dart
final class HandoverPolicy {
  const HandoverPolicy({
    required this.pickupGrace,     // default 1h
    required this.returnGrace,     // default 1h
    required this.lateFeePerHour,
    required this.bufferBetween,   // default 2h; widens the stored period
    required this.cancellationFreeUntil, // default 24h before pickup
  });
}

enum FuelPolicy { fullToFull, sameToSame, prepaidFull }

final class MileagePolicy {
  const MileagePolicy({this.includedKmPerDay, this.perExtraKm});
  /// Null means unlimited, which is common for in-town rentals here.
  final int? includedKmPerDay;
  final Money? perExtraKm;
}
```

No supertype with air's `BaggagePolicy` (ADR-0027 §7).

### 3.6 The deposit

```dart
enum DepositHolder { operator }   // v1 has exactly one value, and says so
enum DepositForm { especes, mobileMoney, carteBancaire, cheque }

final class DepositTerms {
  const DepositTerms({
    required this.amount,
    required this.forms,
    this.holder = DepositHolder.operator,
  });
}
```

A one-value enum is deliberate. It documents that the choice was made, and the day a card acquirer exists it gains `platform` and every switch fails to compile until it is handled — which is exactly what should happen.

---

## 4. Availability — the section that matters most

An occupancy is any claim on a vehicle over an interval: a customer's hold, a confirmed rental, or an operator's maintenance block. All three are rows in one table, competing through one constraint.

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE rental.occupancies (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id   UUID NOT NULL REFERENCES rental.vehicles(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,          -- 'hold' | 'rental' | 'block'
  state        TEXT NOT NULL,          -- 'active' | 'released'
  -- Half-open. Includes the operator's buffer, so the customer's contracted
  -- return and the stored upper bound are NOT the same instant.
  period       TSTZRANGE NOT NULL,
  contracted_pickup  TIMESTAMPTZ NOT NULL,
  contracted_return  TIMESTAMPTZ NOT NULL,
  expires_at   TIMESTAMPTZ,            -- holds only
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT occupancies_kind_known CHECK (kind IN ('hold','rental','block')),
  CONSTRAINT occupancies_state_known CHECK (state IN ('active','released')),
  CONSTRAINT occupancies_hold_expires
    CHECK (kind <> 'hold' OR expires_at IS NOT NULL),

  -- THE guarantee. Two overlapping active claims on one vehicle cannot
  -- exist, whatever the application believes.
  CONSTRAINT occupancies_no_overlap EXCLUDE USING gist (
    vehicle_id WITH =,
    period     WITH &&
  ) WHERE (state = 'active')
);
```

Consequences to build around:

- **Insert and catch.** Availability is not checked and then written; it is written, and a `23P01` exclusion violation is translated into `VehicleNoLongerAvailable`. Any read-then-write is a race.
- **An expired hold is not automatically released.** `state` is a column, not a computed property, so a hold whose `expires_at` has passed still blocks. `services/worker` releases them every minute, and the search additionally treats `state = 'active' AND kind = 'hold' AND expires_at < now()` as free. Both, because the worker can be down and the constraint cannot know about time.
- **`btree_gist` must be created in every environment** — CI, the dev compose stack, and the production migration. It is a new dependency and the first thing to check when rental tests fail on a fresh machine.
- **The driver constraint is the same shape** on `rental.driver_assignments`, so an operator with three cars and one driver can sell three self-drive rentals or one chauffeured one, without anybody writing that rule down.

---

## 5. Schema

`infra/migrations/rental/`, its own sequence.

- **`0001_schema.sql`** — schema, role, grants, `btree_gist` (§P4)
- **`0002_fleet.sql`** — `branches`, `vehicles`, `vehicle_documents`, `vehicle_photos`
- **`0003_rates.sql`** — `rates`, `one_way_fees`, `policies` (handover, fuel, mileage, deposit, per operator)
- **`0004_occupancies.sql`** — `occupancies`, `driver_assignments`, `drivers` (§4)
- **`0005_rentals.sql`** — `rentals` (the aggregate), `rental_drivers` (the captured party data)
- **`0006_agreements.sql`** — `agreements`, `condition_reports`, `condition_photos`

Selected details worth stating rather than discovering:

`rental.branches` — `id`, `operator_id → public.operators`, `name`, `city_code → public.cities`, `address`, `lat`, `lng`, `phone`, `opening_hours JSONB`, `status`. **Not `stations`**: a station is a coach terminal with boarding and alighting semantics and a position on a road (ADR-0025).

`rental.vehicle_documents` — `vehicle_id`, `doc_type` in `('insurance','technical_inspection','registration')`, `storage_key`, `expires_at`, `verified_at`, `verified_by`. Same shape as `public.kyb_documents`, vehicle-scoped, with the same partial expiry index. A vehicle with any expired required document is `blockedCompliance` and **not rentable** — removed from search, refused at booking, and the operator told which document and when.

`rental.rentals` — `id`, `ref` (a short human reference, same generator as booking refs), `operator_id`, `vehicle_id`, `occupancy_id`, `pickup_branch_id`, `return_branch_id`, `with_driver`, `state`, the money columns, `deposit_minor`, `payable_id → public.payables`, `created_at`, `confirmed_at`, `cancelled_at`.

**`deposit_minor` is stored beside the totals and is not a term of any of them.** A `CHECK (total_minor = fare_minor + driver_minor + one_way_fee_minor + service_fee_minor)` states it in the schema, where it cannot be forgotten.

`rental.condition_reports` — `rental_id`, `phase` in `('handover','return')`, `odometer_km`, `fuel_level` (eighths, 0–8), `notes`, `recorded_by`, `recorded_at`, `customer_accepted_at`, `customer_accepted_ip`. Up to eight photos each in `condition_photos`, with a `position` for ordering.

---

## 6. Contracts

`packages/bel_rental_contracts`, mirroring `bel_contracts`' conventions exactly — `Wire.compact`, `Wire.requireString`, `Wire.readMoney`, `Wire.readInstant`, and a `fromJson` for everything.

`RentalSearchQuery` — `pickupBranchId` or `cityCode`, `pickupAt`, `dropOffAt`, `withDriver` (`bool?`), `vehicleClass` (`String?`), `transmission`, `seatsMin`, `cursor`, `limit`.

`RentalOfferDto` — the search row: vehicle id, class, make, model, year, transmission, fuel, seats, air conditioning, first photo, branch name and city, the quote broken out (base, driver, one-way, service fee, total), the deposit amount and forms, the fuel and mileage policy, the free-cancellation deadline, and the operator's rating (ADR-0030).

`RentalQuoteDto`, `DriverRequirementsDto`, `DriverDto`, `CreateRentalHoldRequest`, `CreateRentalRequest`, `RentalDto`, `AgreementDto`, `ConditionReportDto`, `RentalPolicyDto`.

Same discipline as every other contract here: **every new field on an existing type is nullable or defaulted**, and `wire_format_test.dart`'s sibling in this package proves round-trips both ways.

---

## 7. API surface

A route tree under `services/api/routes/rental/`, extractable to its own server by moving the directory (ADR-0027 §8).

- `GET  /rental/v1/branches?city=` — pickup points
- `GET  /rental/v1/offers?…` — search. Excludes vehicles that are blocked, in maintenance, or occupied over the requested period. Keyset cursor, same shape as departure search.
- `GET  /rental/v1/offers/[vehicleId]?…` — one vehicle, full detail, live quote
- `POST /rental/v1/holds` — claims an occupancy. `Idempotency-Key` header, never a body field, exactly as `CreateHoldRequest` does today. A repeat returns the existing hold. 15-minute expiry.
- `GET  /rental/v1/holds/[id]`
- `POST /rental/v1/rentals` — hold → unpaid rental, with the driver party data validated against `DriverRequirements`
- `GET  /rental/v1/rentals/[ref]`
- `POST /rental/v1/rentals/[ref]/cancellation`
- `GET  /rental/v1/rentals/[ref]/agreement`
- Payment reuses the existing `/public/v1/payments` surface via the payable. **No second payment funnel.**

Console, under `services/api/routes/console/v1/rental/`: `branches`, `vehicles`, `vehicles/[id]/documents`, `vehicles/[id]/photos`, `rates`, `policies`, `calendar`, `blocks`, `rentals`, `rentals/[ref]/handover`, `rentals/[ref]/return`, `drivers`.

Public artefact: the agreement is reachable at the existing `t/[token]` pattern (ADR-0026), so a customer with no app and a feature phone can open it from an SMS.

---

## 8. Console module

A feature module behind the existing shell, visible only to staff whose operator has `rental` in `offerings`.

- **Branches** — name, city, address, map pin, phone, opening hours
- **Fleet** — a card per vehicle with its photo, class, plate, status, and **its document expiry dates in plain sight**. A vehicle 18 days from an insurance lapse says so on the card, not in a settings page.
- **Vehicle detail** — photos (drag to reorder), specification, home branch, documents with expiry, and its calendar
- **Calendar** — the core operational screen. Vehicles down the side, days across, occupancies as bars coloured by kind: confirmed rental, hold, maintenance block. Drag to create a block. This is the screen an operator will have open all day and it must work on a phone.
- **Rates** — per class or per vehicle, daily/weekly/monthly, the driver day rate, weekend and season modifiers
- **Policies** — handover graces, buffer, late fee, fuel, mileage, deposit amount and accepted forms, minimum age and years held, free-cancellation window. Every field shows the domain default as its placeholder; saving nothing keeps the default and the screen says so.
- **Rentals** — today's pickups and returns first, because that is the operator's actual day
- **Handover / Return** — the two-phase condition report: odometer, fuel level in eighths, notes, up to eight photos, then the customer accepts on their own handset or the operator's

---

## 9. Traveller feature package

`packages/bel_feature_rental`, registered in the shell's feature list (ADR-0027 §5) and rendered only when `market.offerings` contains `rental`.

Screens: search · results · vehicle detail · driver details · review and terms · payment (the shared flow) · confirmation · my rentals · agreement · handover acceptance.

Details that decide whether this feels honest:

- **The deposit is on the results row**, not revealed at checkout. It is often larger than the rental itself and finding out late is the single worst moment this product could create.
- **Free cancellation until** is an absolute local date and time, never "24h before". Relative deadlines get computed wrong by tired people at airports.
- **With / without driver is a toggle at search**, alongside dates and class — not a checkbox at checkout. It changes the price, the availability and what the form asks for.
- **The mileage policy is one line on the row.** *"Kilométrage illimité"* is a selling point and burying it wastes it.
- **Condition photos are shown to the customer at handover** on their own device, before they accept. Accepting a report they have not seen is worthless in a dispute.

---

## 10. Worker

Jobs in `services/worker`, alongside the existing ones:

- **Hold expiry** — every minute; releases occupancies whose `expires_at` has passed
- **Document expiry** — daily; moves vehicles to `blockedCompliance`, notifies the operator at 30, 14, 7 and 1 days, and again on the day. Reuses the mechanism from migration `0032`.
- **Pickup and return reminders** — SMS to the customer 24 hours and 2 hours before pickup, and on the morning of the return
- **Overdue return** — an hour past the grace, notify both sides; four hours past, flag it for the operator's attention
- **Review eligibility** — on return acceptance, write the `review.eligibilities` row (ADR-0030 §5)
- **Aggregate refresh** — the rating rollup

---

## 11. Localization

`./tool/sync_i18n.sh` after every edit; both languages or the build fails.

New files: `i18n/fr/pages/rental.yaml`, `i18n/en/pages/rental.yaml`, plus `enums/rental.yaml` for the vocabularies.

```
rental.search.title            "Louer une voiture"
rental.search.pickup           "Retrait"
rental.search.dropOff          "Retour"
rental.search.sameBranch       "Retour au même endroit"
rental.search.withDriver       "Avec chauffeur"
rental.search.selfDrive        "Je conduis"
rental.search.class            "Catégorie"

rental.offer.perDay            "{price} / jour"
rental.offer.unlimitedKm       "Kilométrage illimité"
rental.offer.includedKm        "{km} km/jour inclus"
rental.offer.extraKm           "Au-delà : {price}/km"
rental.offer.deposit           "Caution : {amount}"
rental.offer.depositHeldBy     "Versée au loueur au retrait, non prélevée par BilletEnLigne."
rental.offer.depositForms      "Formes acceptées : {forms}"
rental.offer.freeCancelUntil   "Annulation gratuite jusqu'au {date} à {time}"

rental.driver.title            "Le conducteur"
rental.driver.licenceNumber    "Numéro de permis"
rental.driver.licenceCategory  "Catégorie"
rental.driver.licenceIssued    "Délivré le"
rental.driver.chauffeurNote    "Un chauffeur conduit. Aucun permis ne vous est demandé."

rental.handover.title          "État des lieux"
rental.handover.odometer       "Kilométrage"
rental.handover.fuel           "Carburant"
rental.handover.photos         "Photos ({count}/8)"
rental.handover.accept         "Je confirme cet état"
rental.handover.acceptedAt     "Confirmé le {date} à {time}"

rental.return.overdue          "Retour en retard de {duration}"
rental.return.lateFee          "Frais de retard : {price}/heure au-delà de {grace}"

enums.vehicleClass.citadine    "Citadine"
enums.vehicleClass.berline     "Berline"
enums.vehicleClass.suv         "SUV"
enums.vehicleClass.quatreQuatre "4×4"
enums.vehicleClass.pickup      "Pick-up"
enums.vehicleClass.minibus     "Minibus"
enums.vehicleClass.utilitaire  "Utilitaire"
enums.fuelPolicy.fullToFull    "Plein à plein"
enums.fuelPolicy.sameToSame    "Niveau identique"
enums.fuelPolicy.prepaidFull   "Plein prépayé"

errors.rental.noLongerAvailable "Ce véhicule vient d'être réservé."
errors.rental.tooYoung          "Le conducteur doit avoir {min} ans."
errors.rental.licenceTooRecent  "Le permis doit avoir au moins {years} ans."
errors.rental.documentExpired   "Ce véhicule n'est pas disponible actuellement."
```

That last string is deliberately vague to the customer and precise to the operator. Telling a traveller that a specific company's insurance has lapsed is the operator's commercially sensitive business, and the same reasoning `0006_departure_presentation.sql` applied to coach compliance applies here.

---

## 12. Demo data

`services/worker/lib/src/demo_world.dart`, purgeable with `--purge` like everything else there.

Operator **Loca Congo Démo**, code `LCD`, `offerings = {rental}`, accent `laterite`. Two branches: Brazzaville centre and Maya-Maya airport. Six vehicles: a Toyota Corolla (`berline`), a Suzuki Swift (`citadine`), two Toyota Land Cruiser Prado (`quatreQuatre`), a Toyota Hilux (`pickup`), a Toyota Hiace (`minibus`). One driver, so the chauffeured-availability constraint is visible with one booking. One vehicle with an insurance document expiring in 10 days, so the compliance banner has something to show. One vehicle already blocked for maintenance next week, so the calendar is not empty.

Rates: 35 000 XAF/day citadine, 45 000 berline, 90 000 quatreQuatre, 75 000 pickup, 110 000 minibus. Driver 25 000/day. Deposit 200 000 for a 4×4, 100 000 otherwise. One-way fee 15 000 between the two branches.

---

## 13. Slices

House rules, every slice: one commit, pushed; `check_layers.dart` clean; `dart format`; `./tool/sync_i18n.sh` after catalog edits; `rm -rf services/api/build` before smoke; pipe `dart test` through `tr '\r' '\n'`; update `10-build-status.md`.

**P1–P5** — the platform split (§2). Blocking, and shared with stays.

**R1 — a schema and a role.** `rental/0001`; the migration runner understands per-schema sequences; `check.sh` enforces the direction rule. *Test:* the runner applies `rental/0001` to a real database, twice, idempotently; a `public` table with a foreign key into `rental` fails `check.sh`.

**R2 — the fleet exists.** `rental/0002`; `bel_rental` domain types for vehicle, branch and document; console branch and vehicle CRUD. *Test:* an operator without `rental` in `offerings` cannot create a branch — refused at the API, not hidden in the UI.

**R3 — two rentals cannot overlap.** `rental/0004`; `RentalPeriod`; the insert-and-catch path. **The slice this feature is judged on.** *Tests, all against real Postgres:* two concurrent overlapping inserts, one succeeds and one raises `23P01`; a rental ending at 10:00 does not block one starting at 10:00 with a zero buffer; with a 2-hour buffer it does; a released occupancy does not block; a maintenance block and a customer hold collide identically.

**R4 — rates and a quote.** `rental/0003`; `RentalRate`, `RentalQuote`. *Tests:* 7 days takes the weekly tier; 6 days does not; 4 hours bills one day and 25 hours bills two; **`quote.total` never includes `quote.deposit`**; a weekend modifier applies only to the weekend days.

**R5 — search.** `GET /rental/v1/offers`, keyset paginated. *Tests:* an occupied vehicle is absent; an expired hold's vehicle is present even before the worker runs; a `blockedCompliance` vehicle is absent; `withDriver=true` excludes vehicles with no driver free over the period.

**R6 — hold.** `POST /rental/v1/holds`, idempotent by header. *Tests:* a repeat with the same key returns the same hold and creates no second occupancy; a hold on a taken vehicle returns `VehicleNoLongerAvailable`; the hold expires and the worker releases it.

**R7 — who may drive.** `DriverRequirements`; `POST /rental/v1/rentals`. *Tests:* self-drive with no licence number fails; **chauffeured with a licence number succeeds and stores nothing** — read the row back and assert null; a 19-year-old is refused with the age in the message; a licence issued 11 months ago is refused with the years in the message.

**R8 — money.** `public.payables` from the rental path; settlement through the existing rails; commission netted. *Tests:* the ledger balances; **`commission` is computed on the fare and not on the deposit**; a fake-rail failure leaves the occupancy released and the vehicle bookable.

**R9 — the traveller flow.** `bel_feature_rental` registered in the shell; search through confirmation. *Tests:* the shell renders no rental entry when `market.offerings` lacks `rental`; the deposit appears on the results row; goldens for the results row in both themes.

**R10 — the calendar.** The console's operational screen. *Tests:* a widget test with overlapping holds, rentals and blocks renders the right bars; creating a block that collides is refused with a readable message.

**R11 — handover and return.** `rental/0006`; condition reports; photo upload; customer acceptance; the agreement at `t/[token]`. *Tests:* a return report cannot be recorded before a handover one; acceptance is recorded once and is not re-recordable; an agreement token resolves without a session, and a revoked one does not.

**R12 — compliance is a gate.** The daily expiry job; the console banner; search exclusion. *Tests:* a vehicle whose insurance expired yesterday is absent from search and refused at booking; the customer-facing message does not name the document; the operator's does.

**R13 — one-way, and the drop fee.** *Tests:* a different return branch adds the fee; the same branch adds zero; a branch pair with no configured fee is not offered as a one-way at all, rather than being offered free.

**R14 — reminders and the overdue path.** The worker's notification jobs. *Tests:* the 24-hour reminder fires once; a return two hours past the grace produces one operator notification and not one per minute.

**R15 — reviews.** The eligibility row on return acceptance; the operator's rating on the search row. Per `14-reviews.md`.

---

## 14. Out of scope for v1

- **Platform-held deposits.** ADR-0028 §5. Needs a card acquirer, and there is no merchant account for this market.
- **Selling insurance or a damage waiver.** An ancillary product line and a regulated one.
- **Charging excess mileage or fuel through the platform.** Quoted, settled with the operator at return — the same decision as excess baggage in `11-air.md` §3.3, for the same reason: the amount is not known until the thing comes back.
- **Cross-border rentals.** Different insurance, different paperwork, a border.
- **Identity verification.** ADR-0028 is explicit: we capture and surface, we do not verify, and we do not imply that we do.
- **Long-term leasing.** A different contract and a different regulator.
- **Fleet telematics.** A hardware business.

---

## 15. Open commercial questions

Each has a defensible default in the code so the conversation starts from something concrete.

Deposit amounts by class — default 100 000 XAF, 200 000 for a 4×4 or pickup. · Free-cancellation window — default 24 hours. · Buffer between rentals — default 2 hours. · Minimum age — default 21; minimum years held — default 2. · Late fee — no default; the field stays null and the app says nothing until a number exists. · Whether operators will accept the calendar as their system of record, or keep a parallel book. · Whether chauffeur rates are per day or per day plus overtime, which is how some operators here actually price it.
