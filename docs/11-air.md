# BilletEnLigne — Air: the flight option, end to end

**Status:** Specification and implementation roadmap · **Date:** 2026-08-14 · **Implements:** [ADR-0017](adr/0017-multimodal-transport.md), [ADR-0027](adr/0027-verticals-are-separate.md) · **Reads with:** [`01-feature-spec.md`](01-feature-spec.md), [`06-fleet-and-routes.md`](06-fleet-and-routes.md), [`09-roadmap.md`](09-roadmap.md)

## 0. What this document is, and how to read it

ADR-0017 decided *that* air happens and *where the seams are*. It did not say what to build. This document does: every file, every column, every DTO field, every route, every test, in the order they have to happen.

It is written to be executed by somebody who has not read the rest of the repository. Where it names a file, that file exists today unless the line says **NEW**. Where it names a line number, that number is from 2026-08-14 and may have drifted; the surrounding quoted code is the real anchor.

Three things to hold onto before starting, because each one is a trap that has already been laid:

1. **The domain is not the gap.** The inventory model for air is finished. Cabin sections, per-section pricing, `TransportMode`, `mode` on layouts and vehicles and departures, the search filter, the DTOs — all shipped, all tested. Somebody starting this work will spend the first hour looking for the hard part and not finding it. The hard part is §3 (three policy seams that do not exist) and §4 (an app that discards the mode it is sent).
2. **A bus passenger must never be asked for a passport number because the aircraft schema has the field.** ADR-0017 says this in one sentence and it is the single rule that decides whether this feature is good or a regression. It is why §3.1 has a *hidden* state distinct from *optional*, and why there is a test whose only job is to fail if an air-only column ever gets written on a bus booking.
3. **Nothing in this document requires a carrier to exist.** Every slice below is buildable, testable and shippable against a demo carrier in `services/worker/lib/src/demo_world.dart`. The commercial gate — one design-partner carrier — gates *selling*, not *building*. Build it all; ship it dark behind the market flag in §4.1.

---

## 1. Where air already is — the honest inventory

Everything in this section works today and has tests.

### 1.1 Domain

`packages/bel_domain/lib/src/catalog/transport_mode.dart`

```dart
enum TransportMode { bus, air }
```

`packages/bel_domain/lib/src/catalog/seat_layout.dart` — the section model, which ADR-0017 called "the tell that this is the right abstraction":

- `CabinSection({required code, labelKey, rows, abreast, numbering = rowLetter, startRow = 1, modifier, pitchCm})`
- `SeatLayout({required version, mode, sections, features = const [], blocked = const {}})`
- `capacity`, `grossCapacity`, `isValid`, `allSeatLabels()`, `fareFor(label, base)`, `sectionForSeat(label)`
- `Abreast` parses `2+3`, `1+2`, `5`; letters `ABCDEFGHJK` with `I` skipped exactly as aviation does it; max 10 across, max 4 blocks
- `SeatNumbering { rowLetter, sequential }`
- `LayoutFeatureType { door, wc, galley, exit, luggage, driver, cockpit, stairs }` — note `galley`, `exit` and `cockpit` are already there
- `PriceModifier` sealed: `MultiplierModifier`, `SupplementModifier`
- `SeatLayout.airTwoClass()` — F: 3 rows of `2+2`, ×2.5, pitch 100 · Y: 10 rows of `2+2` from row 4

### 1.2 Schema

- `seat_layouts.mode TEXT NOT NULL DEFAULT 'bus'` + `CHECK (mode IN ('bus','air'))` — `0001_foundation.sql:201`
- `vehicles.mode` + the same CHECK — `0001_foundation.sql:219`
- `departures.mode` + `departures.amenities`, both **captured from the vehicle at materialisation** — `0006_departure_presentation.sql:24`. Read the comment in that migration before touching anything here: the mode is on the departure and not joined from `vehicles` because `vehicles.status = 'blocked_compliance'` is commercially sensitive and the public role must not see it. That decision holds for air and gets more important, not less.
- `booking_seats.passenger_id_number TEXT` — nullable, exists, is written today, is asked for by nobody

### 1.3 Server

- `postgres_operator_console.dart` `saveVehicle(...)` derives the vehicle's mode from `SELECT mode FROM seat_layouts WHERE id = @layout AND operator_id = @operator`. **The request body cannot set a mode.** Keep it that way: a vehicle whose mode disagrees with its layout is an aircraft with a coach's seat map.
- `postgres_departure_catalogue.dart:99` selects `d.mode`; `:192` filters `AND (@mode::text IS NULL OR d.mode = @mode::text)`; `:239` and `:413` default to `'bus'`
- `routes/console/v1/fleet/layouts.dart` accepts `mode: body['mode'] == 'air' ? TransportMode.air : TransportMode.bus`

### 1.4 Contracts

- `TripDto.mode` — `String`, required, travels from Postgres to the handset
- `SearchDeparturesQuery.mode` — `String?`, serialised as `mode=` in `toQuery()`
- `SeatMapDto.mode`, `SeatMapDto.sections`, `SeatDto.sectionCode`, `SeatDto.fare`, `CabinSectionDto`, `LayoutFeatureDto`
- `HoldDto.mode` — already carried (`postgres_departure_catalogue.dart:413`)

### 1.5 Console

- `layout_builder_screen.dart` — a bus/air picker bound to `console.fleet.builder.modes.${m.name}`
- `fleet_screen.dart:103` — `KChip(layout.mode)`
- Catalog keys exist in both languages: `console.fleet.builder.mode`, `.modes.bus` ("Car"), `.modes.air` ("Avion")

### 1.6 Design system

- `KSeatMap` draws sections, aisles, a marked front, slashed sold seats
- `KSection`, `KSeat.fare`, `KSeatMapLabels`

**That is a lot.** An operator can, today, draw a two-class aircraft cabin, register an aircraft against it, publish departures on it, and those departures are searchable by `mode=air` over the public API. What cannot happen is anybody buying one from a phone, and nothing enforces a single aviation rule.

---

## 2. What is missing — the seven gaps

Each gap maps to slices in §13.

| # | Gap | Evidence | Slices |
|---|---|---|---|
| G1 | No `PassengerRequirements` | `grep -r PassengerRequirements packages services apps` → 0 hits | A2, A3 |
| G2 | No `BoardingPolicy` | 0 hits | A4, A5 |
| G3 | No `BaggagePolicy` | 0 hits | A6 |
| G4 | Traveller app never reads `mode` | nothing in `apps/traveller/lib` references `trip.mode`; the only `mode` is `app.dart:52` (theme) | A7, A8, A9 |
| G5 | No air inventory anywhere | `demo_world.dart` has no air; `demo_travel_gateway.dart:75` and `:196` hardcode `mode: 'bus'`; `infra/dev/seed/` has only roles | A1 |
| G6 | No per-operator air capability | `operators` has no modes column; `capabilities` in the DTOs is staff RBAC, not product | A10 |
| G7 | `LayoutFeature` is modelled, stored, wired and never drawn | `KSeatMap` references `sectionCode` and no feature type | A11 |

---

## 3. The three seams

> **Names confirmed by [ADR-0027](adr/0027-verticals-are-separate.md) §7.** These three types are named for *transport* and stay named for transport. They live in `bel_domain` and **no supertype is ever created over them.** Rental defines its own `DriverRequirements` and `HandoverPolicy` in `bel_rental`; stays define their own `GuestRequirements` and `StayWindowPolicy` in `bel_stay`; the three packages may not import one another and `tool/check_layers.dart` enforces it.
>
> What carries across the verticals is not a type but the rule in §3.1 — three-state field requirements with `hidden` distinct from `optional`, and a test whose only job is to fail if a field from one context is stored in another. Each vertical implements it independently, which is four small implementations instead of one type with four disjoint regions.

ADR-0017 §5 names exactly three, and adds: *"If a fourth seam appears, that is a signal to re-examine this ADR."* §3.4 below reports what happened when this specification was written against that sentence.

All three live in `packages/bel_domain/lib/src/catalog/` beside `transport_mode.dart` and `seat_layout.dart`, are `const`-constructible, hold no I/O, and each has a `forMode(TransportMode)` factory so that a caller with a departure always has an answer.

### 3.1 `PassengerRequirements` — what we may ask, and what we must not

**NEW** `packages/bel_domain/lib/src/catalog/passenger_requirements.dart`

```dart
/// One thing we can know about a passenger.
enum PassengerField {
  fullName,
  phone,
  idType,
  idNumber,
  idExpiry,
  dateOfBirth,
  nationality,
}

/// Three states, not two. `hidden` is the one that matters: a field that is
/// merely `optional` still appears on the form, and a Congolese coach
/// passenger asked for a passport number will assume they need one
/// (ADR-0017).
enum FieldRequirement { hidden, optional, required }

/// What a given departure is allowed to ask its passengers.
final class PassengerRequirements {
  const PassengerRequirements(this.fields);

  /// Every field the caller must consider. A field absent from this map is
  /// `hidden` — the safe default, deliberately, so that adding a field to
  /// the enum never quietly puts it on a coach booking form.
  final Map<PassengerField, FieldRequirement> fields;

  FieldRequirement of(PassengerField f) =>
      fields[f] ?? FieldRequirement.hidden;

  bool isVisible(PassengerField f) => of(f) != FieldRequirement.hidden;
  bool isRequired(PassengerField f) => of(f) == FieldRequirement.required;

  /// In form order. Not alphabetical, not enum order: this is the order a
  /// human fills a form in, and it is a presentation fact the domain owns
  /// because all three clients must agree on it.
  List<PassengerField> get visible => const [
        PassengerField.fullName,
        PassengerField.phone,
        PassengerField.dateOfBirth,
        PassengerField.nationality,
        PassengerField.idType,
        PassengerField.idNumber,
        PassengerField.idExpiry,
      ].where(isVisible).toList(growable: false);

  static const bus = PassengerRequirements({
    PassengerField.fullName: FieldRequirement.required,
    PassengerField.phone: FieldRequirement.optional,
    PassengerField.idNumber: FieldRequirement.optional,
  });

  /// Domestic Congolese aviation. Name, date of birth and a national ID or
  /// passport number are what a domestic manifest and a boarding gate need.
  /// Nationality is required because it is what separates a national-ID
  /// passenger from a passport one at the desk, and it costs one dropdown.
  static const air = PassengerRequirements({
    PassengerField.fullName: FieldRequirement.required,
    PassengerField.phone: FieldRequirement.optional,
    PassengerField.dateOfBirth: FieldRequirement.required,
    PassengerField.nationality: FieldRequirement.required,
    PassengerField.idType: FieldRequirement.required,
    PassengerField.idNumber: FieldRequirement.required,
    PassengerField.idExpiry: FieldRequirement.optional,
  });

  static PassengerRequirements forMode(TransportMode mode) =>
      switch (mode) {
        TransportMode.bus => bus,
        TransportMode.air => air,
      };
}

/// What kind of document the number belongs to. A closed set, because
/// "autre" on a manifest is a passenger the gate cannot check.
enum IdDocumentType { nationalId, passport, residencePermit, driverLicence }
```

**The rule that this type exists to enforce**, and the test that proves it (slice A3):

> Reserving a booking on a **bus** departure with `idExpiry`, `dateOfBirth` or `nationality` present in the request body must succeed, must not error, and must leave those columns `NULL` in `booking_seats`. Silently dropped, not rejected — a rejection here would break an air-aware client that reuses one form widget, and a stored value would be personal data collected without a purpose.

`ReserveBooking` gains two failures beside the existing `PassengerNameMissing`:

```dart
final class PassengerFieldMissing extends ReserveBookingFailure {
  const PassengerFieldMissing(this.field, this.seatLabel);
  final PassengerField field;
  final String seatLabel;
}

final class PassengerFieldRejected extends ReserveBookingFailure {
  const PassengerFieldRejected(this.field, this.seatLabel, this.reasonKey);
  final PassengerField field;
  final String seatLabel;
  final String reasonKey;
}
```

Validation rules, in `ReserveBooking`, applied per passenger against `PassengerRequirements.forMode(departure.mode)`:

- `required` and absent or blank → `PassengerFieldMissing`
- `hidden` and present → **drop it**, do not fail
- `dateOfBirth` in the future, or more than 120 years past → `PassengerFieldRejected(dateOfBirth, …, 'errors.travel.dobImplausible')`
- `idExpiry` before the departure's `departs_at` → `PassengerFieldRejected(idExpiry, …, 'errors.travel.idExpired')`. Only a hard failure when the document *has already expired by the travel date*; an expiry within 90 days is a warning surfaced on the review screen and never a block, because that rule differs per carrier and we do not have a carrier yet.
- `nationality` not an ISO-3166-1 alpha-2 code present in `i18n/*/reference/countries.yaml` → `PassengerFieldRejected`
- `idNumber` — length 4–40, trimmed, no format check. **Do not validate the shape of a Congolese national ID number.** Nobody in this repository knows it, a wrong regex refuses real travellers, and the desk checks the physical document anyway.

**Where the requirements reach the client.** On `HoldDto`, not derived client-side. `HoldDto` already carries `mode`, so deriving is possible — and wrong: a carrier that starts requiring `idExpiry` would need an app release in a market where a large share of users never update. This is the same argument `MarketDto.signInChannels` and `MarketDto.rails` already won (ADR-0006). Add:

```dart
// packages/bel_contracts/lib/src/booking/booking_dto.dart
final class PassengerRequirementsDto {
  const PassengerRequirementsDto({required this.fields});
  /// Field name to one of `hidden` | `optional` | `required`. Fields absent
  /// are hidden. An unknown field name from a newer server is ignored by an
  /// older client, which is the correct behaviour: it cannot render it.
  final Map<String, String> fields;
}
```

`HoldDto.passengerRequirements` is **nullable** on the wire. A null means "an older server that predates this"; the client then falls back to `PassengerRequirements.forMode(mode)` from `bel_domain`. The server always sends it.

`PassengerDto` gains four nullable fields — `idType`, `idExpiry`, `dateOfBirth`, `nationality` — alongside the existing `fullName`, `phone`, `idNumber`, `seatLabel`. All nullable, all `Wire.compact`-elided when null, so a bus booking's wire body is byte-for-byte what it is today.

### 3.2 `BoardingPolicy` — cut-offs, check-in, and how strictly a name is a name

**NEW** `packages/bel_domain/lib/src/catalog/boarding_policy.dart`

```dart
/// How closely the name on the ticket must match the document at the door.
enum IdMatchStrictness {
  /// Nobody is asked for a document. Today's coach.
  none,

  /// A document is asked for and a human judges it. "J. Mabiala" against
  /// "Jean Mabiala" passes.
  loose,

  /// The name must match the document. A correction is a re-issue with a
  /// fee, not an edit — which is why `nameChangeIsReissue` exists below and
  /// is not merely a comment on this value.
  strict,
}

final class BoardingPolicy {
  const BoardingPolicy({
    required this.salesCutoff,
    required this.requiresCheckIn,
    required this.checkInOpens,
    required this.checkInCloses,
    required this.boardingCloses,
    required this.idMatch,
    required this.nameChangeIsReissue,
  });

  /// Sales stop this long before departure. Today this is expressed per
  /// departure as `departures.sales_close_at`; this value is what the worker
  /// fills that column with when the operator did not choose one.
  final Duration salesCutoff;

  /// False for a coach, and that is not a stub — a coach genuinely has no
  /// check-in, and a policy that pretended otherwise would put a
  /// "s'enregistrer" button on a bus ticket.
  final bool requiresCheckIn;

  final Duration checkInOpens;   // before departure
  final Duration checkInCloses;  // before departure
  final Duration boardingCloses; // gate closes, before departure

  final IdMatchStrictness idMatch;
  final bool nameChangeIsReissue;

  DateTime salesCloseAt(DateTime departsAt) => departsAt.subtract(salesCutoff);
  DateTime checkInOpensAt(DateTime d) => d.subtract(checkInOpens);
  DateTime checkInClosesAt(DateTime d) => d.subtract(checkInCloses);
  DateTime gateClosesAt(DateTime d) => d.subtract(boardingCloses);

  bool checkInIsOpen(DateTime departsAt, DateTime now) =>
      requiresCheckIn &&
      !now.isBefore(checkInOpensAt(departsAt)) &&
      now.isBefore(checkInClosesAt(departsAt));

  static const bus = BoardingPolicy(
    salesCutoff: Duration(minutes: 30),
    requiresCheckIn: false,
    checkInOpens: Duration.zero,
    checkInCloses: Duration.zero,
    boardingCloses: Duration(minutes: 5),
    idMatch: IdMatchStrictness.loose,
    nameChangeIsReissue: false,
  );

  /// Domestic Congolese aviation, the conservative end of the range in
  /// ADR-0017's compliance table. A carrier will move these; they are
  /// per-operator data from slice A10 onward and these are the defaults.
  static const air = BoardingPolicy(
    salesCutoff: Duration(hours: 2),
    requiresCheckIn: true,
    checkInOpens: Duration(hours: 24),
    checkInCloses: Duration(minutes: 60),
    boardingCloses: Duration(minutes: 20),
    idMatch: IdMatchStrictness.strict,
    nameChangeIsReissue: true,
  );

  static BoardingPolicy forMode(TransportMode mode) => switch (mode) {
        TransportMode.bus => bus,
        TransportMode.air => air,
      };
}
```

**Check-in, and the one decision that keeps it small.** Air adds a state between "has a ticket" and "may board". The obvious move is a second signed artefact — a boarding pass beside the ticket — and it is the wrong one: it doubles the crypto surface (ADR-0007), doubles the offline story, and gives the traveller two QR codes and no way to tell which one the gate wants.

**Decision: the ticket is the boarding pass. Check-in is a state on it.**

- `tickets.checked_in_at TIMESTAMPTZ` — nullable, set once, never unset by check-in itself
- A ticket on a departure whose policy has `requiresCheckIn == true` and whose `checked_in_at IS NULL` is **not boardable**
- The scanner learns this the way it learns everything else offline: the departure manifest it already downloads carries a per-ticket `checkedIn` flag. A scanner holding a stale manifest sees a passenger as not-checked-in and falls back to the manual path that already exists in `apps/scanner/lib/src/presentation/pages/manual_boarding_page.dart` — which is the correct failure: a human at a gate resolves it in ten seconds, and the alternative (fail open) is somebody boarding a flight they are not manifested on.
- **The QR payload does not change.** No re-signing, no re-fetch, no new key material. This is the whole reason for the decision.

Check-in is self-service in the traveller app and staff-assisted in the console. It is not a payment step and it collects nothing new: everything it needs was collected at booking by §3.1. That is the point of collecting it at booking.

**Seat assignment stays at booking.** Carriers commonly assign seats at check-in. We sell the seat with the ticket, we always have, and it is the thing travellers in this market say they want. Air does not change it.

### 3.3 `BaggagePolicy` — what is included, what it costs, and what we do not sell

**NEW** `packages/bel_domain/lib/src/catalog/baggage_policy.dart`

```dart
final class BaggageAllowance {
  const BaggageAllowance({
    required this.checkedPieces,
    required this.kgPerPiece,
    required this.cabinKg,
  });
  final int checkedPieces;
  final int kgPerPiece;
  final int cabinKg;

  int get totalCheckedKg => checkedPieces * kgPerPiece;
  bool get isNothing => checkedPieces == 0 && cabinKg == 0;
}

final class BaggagePolicy {
  const BaggagePolicy({
    required this.included,
    this.bySection = const {},
    this.excessPerKg,
    this.maxExcessKg = 0,
  });

  /// The default allowance for the departure.
  final BaggageAllowance included;

  /// Section code to allowance, for cabins where first class carries more.
  /// Keys are `CabinSection.code`, so this composes with the layout model
  /// that already exists rather than inventing a second notion of class.
  final Map<String, BaggageAllowance> bySection;

  /// Null when excess is not sold at all — which is v2's answer, see below.
  final Money? excessPerKg;
  final int maxExcessKg;

  BaggageAllowance forSection(String code) => bySection[code] ?? included;

  /// A coach in this market carries what fits, and charges cash at the door
  /// if it does not. Modelling that would be inventing a rule nobody
  /// follows. ADR-0017 said this seam is a no-op for bus in v1 and it is.
  static const busNone = BaggagePolicy(
    included: BaggageAllowance(checkedPieces: 0, kgPerPiece: 0, cabinKg: 0),
  );

  static const airDomestic = BaggagePolicy(
    included: BaggageAllowance(checkedPieces: 1, kgPerPiece: 23, cabinKg: 7),
    bySection: {
      'F': BaggageAllowance(checkedPieces: 2, kgPerPiece: 32, cabinKg: 10),
    },
  );

  static BaggagePolicy forMode(TransportMode mode) => switch (mode) {
        TransportMode.bus => busNone,
        TransportMode.air => airDomestic,
      };
}
```

**Excess baggage is quoted, never sold — in v2.** The allowance is displayed at search, on the seat map, on the review screen and on the ticket. Excess is settled with the carrier at the counter. Reasons, in order of weight:

1. Selling it means an ancillary product line: a second sellable thing on a booking, with its own price, its own ledger postings, its own refund behaviour when the flight is cancelled, and its own row in the payout statement. That is a larger slice than air itself and it would be built on a guess about what a carrier charges.
2. Excess is weighed at the desk. A traveller who prepaid 12 kg and turns up with 19 is at a counter transaction anyway.
3. `excessPerKg` and `maxExcessKg` exist in the type from day one so that the display can say *"au-delà: 2 500 XAF/kg, réglés au comptoir"* — honest, useful, and no money moves.

`BaggagePolicy` is on the departure via the operator's air profile (§A10), overridable per departure later. It is **not** on the layout: two carriers flying the same aircraft type have different allowances, and the layout is a drawing of an aeroplane.

**Weight and balance is out of scope, and the mitigation already exists.** ADR-0017 lists trim-restricted seat assignment as a real difference. `SeatLayout.blocked` is a `Set<String>` of seat labels and is already respected end to end. A dispatcher who needs row 1 empty for trim blocks row 1. That is not a workaround; for a 50-seat turboprop on a fixed domestic sector it is what the process actually is.

### 3.4 The fourth-seam check

ADR-0017: *"If a fourth seam appears, that is a signal to re-examine this ADR."* Writing this specification produced two candidates. Both are reported here rather than quietly absorbed.

**Check-in — not a fourth seam.** It looks like one: it is a distinct step, with its own screen, its own state and its own API surface. But as *policy* it is entirely cut-offs and a requirement flag, and it sits inside `BoardingPolicy` without stretching it. The screens it needs are presentation. Verdict: not a seam. ADR-0017 stands.

**Fare families — a genuine fourth. Deferred here; built by stays.** *Économique non modifiable* versus *Flexible* is how air is actually priced, and it is not a price modifier on a cabin section: it is a bundle of a fare, a change rule, a refund rule and a baggage allowance sold as one thing. Our refund and change machinery is per-booking policy (`refund_policies`, migrations `0014`, `0025`, `0026`), not per-fare-product.

This is a real seam and it is **explicitly out of scope for air v2**. Air v2 sells one fare per cabin section under the operator's existing refund policy. Do not smuggle it in as a `PriceModifier`.

The same shape shows up next door: [ADR-0029](adr/0029-stays.md) builds rate plans for stays, because a hotel that cannot offer *non-remboursable −15%* against *tarif flexible* will not list — that is not a discount, it is how the category prices. When a carrier eventually asks for fare families, **borrow the design, not the code**: `RatePlan` lives in `bel_stay` and `bel_domain` may not import it ([ADR-0027](adr/0027-verticals-are-separate.md) §1, §7). Air's version would be its own type in `bel_domain`, and writing it is the trigger for a new ADR.

---

## 4. The traveller app — the gap the user actually reported

> *"there is no choice at the start of the app for client, like fligth, bus, we only see bus"*

Correct, and worse than it sounds: `TripDto` carries `mode` from Postgres to the handset and **no widget in `apps/traveller/lib` ever looks at it.** There is nothing to choose *between* either — `demo_travel_gateway.dart:75` and `:196` both hardcode `mode: 'bus'`, and `demo_world.dart` has no aircraft.

### 4.1 Where the chooser's data comes from

Not from a compiled-in list, and not from a probe query. From `MarketDto`, served by `routes/public/v1/market.dart`, fetched at startup, cached against an ETag, and sourced from `config/markets.yaml`.

`config/markets.yaml`, per market:

```yaml
    # Which products this market actually sells. Data, for the same reason
    # the rails are data (ADR-0006): the day a carrier signs, air becomes
    # visible with a config push instead of an app release — in a market
    # where many users never update.
    #
    # One flat vocabulary over four products (ADR-0027 §4): bus, air,
    # rental, stay. Configuration and presentation only — see the ADR.
    offerings: [bus]
```

`MarketDto.offerings` — `List<String>`, defaulting to `const ['bus']` so an older server is understood.

The rule the app follows: **the chooser renders only when `market.offerings.length > 1`.** A segmented control with one segment is a control that always has the same answer, and it makes the search screen worse for every traveller in a bus-only market. This is what lets the whole feature ship dark.

### 4.2 The chooser itself

`apps/traveller/lib/src/presentation/screens/search_screen.dart`

A `KModePicker` (**NEW**, `packages/bel_design/lib/src/components/k_mode_picker.dart`) sits above the from/to row — above, because it changes what the fields below mean, and a control that reframes the form beneath it belongs at the top.

- Segments: *Tous* · *Car* · *Avion*, with icons `Icons.directions_bus` and `Icons.flight`. The component takes its segments from the shell's registered features filtered by `market.offerings` ([ADR-0027](adr/0027-verticals-are-separate.md) §5), never from a literal list — ADR-0028 and ADR-0029 add *Location* and *Hébergement* to the same control by registering a package, and a picker that hardcodes two products is a picker that gets rewritten twice.
- Labels from `travel.search.modes.all` / `.bus` / `.air` — do not reuse `console.fleet.builder.modes.*`; the console says "Car" meaning a vehicle an operator owns, and the traveller screen says "Car" meaning a journey. They are the same word today and will not stay the same word.
- Default: *Tous*. Not *Car*. A default that filters is a default that hides inventory, and a traveller who does not care should see the 06:00 coach and the 07:15 flight in one list ordered by departure time.
- The choice is held in `_SearchScreenState`, flows into `SearchDeparturesQuery.mode` (`null` for *Tous*), and is **remembered across launches** in `theme_preference.dart`'s store — somebody who flies always flies.

### 4.3 Everywhere the mode must now be visible

- **`KTripCard`** — a leading silhouette per mode. Today the card has no vehicle icon at all. This is the single highest-value pixel in the feature: in a mixed result list, mode is the first thing a traveller reads and there is currently nothing to read.
- **`results_screen.dart`** — when `query.mode == null` and results contain both, that is fine and needs no divider. When the traveller filtered and the list is empty, the empty state must say *which* filter emptied it and offer to clear it, not say "no departures".
- **`seat_map_screen.dart`** — title from the mode; on air, the `cockpit` feature is drawn at the front (§A11) and the front marker says *avant de l'appareil* rather than *avant du car*.
- **`passengers_screen.dart`** — rebuilt to render from `PassengerRequirements` rather than from a fixed field list. **This is the file where the ADR-0017 trap gets sprung or avoided.** After this slice, the widget must have no literal knowledge of `idNumber` or `dateOfBirth` at all; it maps `PassengerField` to an input. A `hidden` field is not built, not rendered, not sent.
- **`ticket_screen.dart`** — on an air ticket: the baggage allowance, the check-in state, the gate cut-off as a countdown (`KCountdown` exists), and the check-in button when the window is open.
- **`hold_screen.dart`** — the hold countdown is unchanged, but an air hold shows the sales cut-off when it is nearer than the hold expiry.

---

## 5. Schema changes, migration by migration

Numbering continues from `0045_ticket_link_accent.sql`. Each is one migration, in this order, each independently applyable.

### `0046_passenger_identity.sql`

```sql
BEGIN;

ALTER TABLE booking_seats
  ADD COLUMN passenger_id_type     TEXT,
  ADD COLUMN passenger_id_expiry   DATE,
  ADD COLUMN passenger_dob         DATE,
  ADD COLUMN passenger_nationality CHAR(2);

ALTER TABLE booking_seats
  ADD CONSTRAINT booking_seats_id_type_known
  CHECK (passenger_id_type IS NULL OR passenger_id_type IN
    ('national_id','passport','residence_permit','driver_licence'));

-- An id number with no type is a number nobody can check at a gate.
ALTER TABLE booking_seats
  ADD CONSTRAINT booking_seats_id_type_with_number
  CHECK (passenger_id_type IS NULL OR passenger_id_number IS NOT NULL);

COMMENT ON COLUMN booking_seats.passenger_dob IS
  'Captured only where the departure''s mode requires it (PassengerRequirements). '
  'NULL on every bus booking, and a non-null value on a bus booking is a defect: '
  'see the test named for it in reserve_booking_test.dart.';

COMMIT;
```

Grants: these columns are on a table the sales roles already hold privileges on, so `0004_rls_grants.sql` needs nothing new. **Verify this** with `infra/migrations/check.sh` rather than believing it — column-level grants exist in this schema and a new column can land outside one.

### `0047_check_in.sql`

```sql
BEGIN;

ALTER TABLE tickets ADD COLUMN checked_in_at TIMESTAMPTZ;

-- Partial: the only question ever asked is "who on this departure has not
-- checked in", and the answer on a coach is everybody.
CREATE INDEX tickets_checkin_idx ON tickets (departure_id)
  WHERE checked_in_at IS NULL;

COMMENT ON COLUMN tickets.checked_in_at IS
  'Set once, at check-in. The QR payload is NOT re-signed: the ticket is the '
  'boarding pass and this is a state on it (11-air.md §3.2).';

COMMIT;
```

### `0048_operator_air_profile.sql`

```sql
BEGIN;

-- Which products this operator may sell. The capability flag ADR-0017 asked
-- for, and it did not exist until now. One FLAT vocabulary over four
-- products (ADR-0027 §4). No domain package defines it, and nothing in
-- bel_platform, bel_domain, bel_rental or bel_stay switches on it: this
-- column is a configuration edge, not a model.
--
-- `rental` and `stay` are in the CHECK from day one so that ADR-0028 and
-- ADR-0029 do not need a second ALTER on a table this hot.
ALTER TABLE operators
  ADD COLUMN offerings TEXT[] NOT NULL DEFAULT '{bus}';

ALTER TABLE operators
  ADD CONSTRAINT operators_offerings_known
  CHECK (offerings <@ ARRAY['bus','air','rental','stay']::TEXT[]
         AND cardinality(offerings) > 0);

-- Policy overrides, as data. NULL means "the domain default for the mode",
-- which is the honest state until a carrier tells us otherwise — a row of
-- invented minutes reads as a decision somebody made.
CREATE TABLE operator_mode_policies (
  operator_id        UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,
  mode               TEXT NOT NULL,

  sales_cutoff_min   INTEGER,
  check_in_opens_min INTEGER,
  check_in_closes_min INTEGER,
  boarding_closes_min INTEGER,
  id_match           TEXT,

  baggage_pieces     INTEGER,
  baggage_kg_piece   INTEGER,
  baggage_cabin_kg   INTEGER,
  baggage_by_section JSONB NOT NULL DEFAULT '{}',
  excess_per_kg_minor BIGINT,
  excess_max_kg      INTEGER,

  passenger_fields   JSONB NOT NULL DEFAULT '{}',

  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (operator_id, mode),
  CONSTRAINT omp_mode_known CHECK (mode IN ('bus','air')),
  CONSTRAINT omp_id_match_known
    CHECK (id_match IS NULL OR id_match IN ('none','loose','strict'))
);

COMMIT;
```

Grants, in the same migration: `bel_app` gets `SELECT` on `operator_mode_policies`; `bel_admin` gets `SELECT, INSERT, UPDATE`; **`bel_public` gets nothing** — the public read path takes its policy off the departure (next migration), never by joining to an operator's configuration table. That is the same reasoning `0006_departure_presentation.sql` used and it is not optional.

### `0049_departure_policy_snapshot.sql`

```sql
BEGIN;

-- Captured at materialisation, exactly like mode and amenities in 0006.
-- Editing an operator's policy tomorrow must not rewrite a departure that
-- already has bookings, and the public read must not join to operators.
ALTER TABLE departures
  ADD COLUMN boarding_policy JSONB,
  ADD COLUMN baggage_policy  JSONB,
  ADD COLUMN passenger_fields JSONB;

COMMENT ON COLUMN departures.boarding_policy IS
  'Snapshot of BoardingPolicy at materialisation. NULL means "the domain '
  'default for this departure''s mode" — every row that predates air.';

COMMIT;
```

**NULL is a first-class value in all three columns and every reader must handle it**, because ~100% of existing rows will have it and backfilling them with today's bus defaults would freeze a policy that is currently free to change in code.

---

## 6. Contract changes

`packages/bel_contracts/lib/src/`

- `booking/booking_dto.dart`
  - `PassengerDto` + `idType`, `idExpiry`, `dateOfBirth`, `nationality` — all nullable, all `Wire.compact`-elided
  - **NEW** `PassengerRequirementsDto`
  - `TicketDto` + `checkedInAt` (`DateTime?`), `baggage` (`BaggageAllowanceDto?`), `gateClosesAt` (`DateTime?`)
  - **NEW** `CheckInRequest({required this.bookingRef, required this.seatLabels})` and `CheckInResult({required this.tickets, required this.failures})`
- `booking/hold_dto.dart` (or wherever `HoldDto` lives) — `passengerRequirements` (`PassengerRequirementsDto?`), `boardingPolicy` (`BoardingPolicyDto?`)
- `catalog/trip_dto.dart`
  - `TripDto` + `baggage` (`BaggageAllowanceDto?`) — so the results list can say *"1 × 23 kg inclus"*, which is a real comparison shopper's question
  - `SearchDeparturesQuery.mode` — unchanged, already there
- `catalog/seat_map_dto.dart` — `SeatMapDto` already carries `mode`, `sections` and `features`. Add nothing.
- `config/market_dto.dart` — `offerings` (`List<String>`, default `const ['bus']`) — ADR-0027 §4
- **NEW** `catalog/policy_dto.dart` — `BoardingPolicyDto`, `BaggagePolicyDto`, `BaggageAllowanceDto`

Every new field is nullable or defaulted. **A client built before this change must parse a post-change response without error, and a server after this change must accept a pre-change request body.** `packages/bel_contracts/test/wire_format_test.dart` is where that is proven, and it is the largest test file in the repo for exactly this reason.

---

## 7. API surface

| Route | Change |
|---|---|
| `public/v1/market.dart` | `offerings` in the body. The ETag changes, which is the mechanism working. |
| `public/v1/trips.dart` | `mode=` already filters. Add `baggage` to each row. |
| `public/v1/holds.dart` | Response gains `passengerRequirements` and `boardingPolicy`. |
| `public/v1/bookings.dart` | Accepts the four new passenger fields; validates per §3.1; **drops hidden fields silently**. |
| **NEW** `public/v1/bookings/[ref]/check-in.dart` | `POST` → checks in the named seats. Idempotent by booking ref + seat: a second call returns the same result, never an error. `409` outside the window, with `checkInOpensAt` and `checkInClosesAt` in the body so the app renders a countdown rather than "erreur". |
| `public/v1/departures/[id]/seatmap.dart` | No change. It already sends sections and features. |
| `console/v1/departures/[id]/manifest.dart` | Adds `checkedIn` per ticket, and the four identity fields — which is what makes a manifest an aviation manifest. |
| `console/v1/departures/[id]/boarding.dart` | The offline bundle gains the same `checkedIn` flag. |
| **NEW** `console/v1/departures/[id]/check-in.dart` | Staff-assisted check-in at a desk, under an existing capability. |
| **NEW** `console/v1/policies/modes.dart` | `GET`/`PUT` the operator's per-mode policy overrides. |
| `admin/v1/operators/[id]/index.dart` | `offerings` becomes settable by platform staff. **Only** by platform staff — an operator granting itself the right to sell flights is the definition of a capability flag that does not work. |

---

## 8. Console

- **Fleet → Layouts.** The bus/air picker exists. Add: when `air` is selected and the operator's `modes` does not contain `air`, the picker is disabled with a line explaining who enables it. Silently allowing an air layout that can never carry a sellable departure is a dead end an operator will spend an afternoon in.
- **Fleet → Vehicles.** `registration` is a number plate for a coach and a tail number for an aircraft. Different label, different hint, same column. `console.fleet.vehicles.registration.bus` / `.air`.
- **NEW Settings → Policies → per mode.** Cut-offs, ID strictness, baggage allowance, which passenger fields are required. Every field shows the domain default as its placeholder and saving nothing keeps NULL — an operator who has not thought about check-in cut-offs gets ours, and the screen says so.
- **Departure detail.** Check-in progress — *"38 / 74 enregistrés"* — and a desk check-in button per passenger.
- **Manifest.** For air, the printed manifest gains ID type, ID number, DOB and nationality columns. `console/v1/departures/[id]/manifest.dart` and its PDF path.

---

## 9. Scanner

`apps/scanner` changes as little as possible, and that is a design goal rather than an accident.

- The offline bundle gains `checkedIn` per ticket and `requiresCheckIn` per departure
- A scan of a valid, unvoided, not-checked-in ticket on a `requiresCheckIn` departure shows a **distinct third outcome** — not the red "refusé" of a void ticket. Amber, with the words *"non enregistré — au comptoir"*. A gate agent who sees the same red for a refunded ticket and for a passenger who simply has not checked in will treat both the same way, and one of those two people has done nothing wrong.
- The existing manual path is the fallback for a stale bundle. It already exists. Do not build a second one.

---

## 10. Worker

`services/worker/lib/src/timetable_horizon.dart` materialises departures. It gains one responsibility: when creating a departure, snapshot the policies.

```
mode           ← vehicle.mode                       (already, via 0006)
amenities      ← vehicle.amenities                  (already, via 0006)
boarding_policy ← operator override ?? BoardingPolicy.forMode(mode)   NEW
baggage_policy  ← operator override ?? BaggagePolicy.forMode(mode)    NEW
passenger_fields ← operator override ?? PassengerRequirements.forMode(mode) NEW
sales_close_at  ← operator's own value ?? boardingPolicy.salesCloseAt(departsAt)  NEW
```

That last line changes existing bus behaviour: `departures.sales_close_at` is nullable today and is often null. Filling it with `departs_at - 30 min` for buses is a **behaviour change on the live product** and must be its own slice with its own test, not a rider on the air work. It is listed separately as A5b for that reason.

---

## 11. Localization

`./tool/sync_i18n.sh` after every catalog edit. Both languages, every key, or the build fails — which is the check working.

New keys, `fr` shown:

```
travel.search.modes.all           "Tous"
travel.search.modes.bus           "Car"
travel.search.modes.air           "Avion"
travel.search.noneForMode         "Aucun {mode} sur ce trajet ce jour-là."
travel.search.clearModeFilter     "Voir tous les transports"

travel.passenger.fields.fullName      "Nom complet"
travel.passenger.fields.phone         "Téléphone"
travel.passenger.fields.dateOfBirth   "Date de naissance"
travel.passenger.fields.nationality   "Nationalité"
travel.passenger.fields.idType        "Type de pièce"
travel.passenger.fields.idNumber      "Numéro de pièce"
travel.passenger.fields.idExpiry      "Expire le"
travel.passenger.idHelp.air           "Le nom doit correspondre à la pièce présentée à l'embarquement."
travel.passenger.idExpiringSoon       "Cette pièce expire dans {days} jours."

travel.baggage.included               "{pieces} × {kg} kg inclus"
travel.baggage.cabin                  "{kg} kg en cabine"
travel.baggage.excess                 "Au-delà : {price}/kg, réglés au comptoir"
travel.baggage.none                   "Bagages selon la place disponible"

travel.checkin.title                  "Enregistrement"
travel.checkin.opensAt                "Ouvre le {date} à {time}"
travel.checkin.closesIn               "Ferme dans {duration}"
travel.checkin.closed                 "L'enregistrement est fermé. Présentez-vous au comptoir."
travel.checkin.done                   "Enregistré"
travel.checkin.gateClosesAt           "Embarquement jusqu'à {time}"

enums.idDocumentType.national_id      "Carte nationale d'identité"
enums.idDocumentType.passport         "Passeport"
enums.idDocumentType.residence_permit "Titre de séjour"
enums.idDocumentType.driver_licence   "Permis de conduire"

errors.travel.dobImplausible          "Cette date de naissance n'est pas plausible."
errors.travel.idExpired               "Cette pièce expire avant le voyage."
errors.travel.fieldRequired           "{field} est obligatoire pour ce vol."
errors.travel.checkInNotOpen          "L'enregistrement n'est pas encore ouvert."
errors.travel.checkInClosed           "L'enregistrement est fermé."

boarding.result.notCheckedIn          "Non enregistré — au comptoir"

console.policies.title                "Règles d'exploitation"
console.policies.mode                 "Mode"
console.policies.salesCutoff          "Fin des ventes"
console.policies.checkIn              "Enregistrement"
console.policies.idMatch              "Contrôle d'identité"
console.policies.baggage              "Bagages"
console.policies.usingDefault         "Valeur par défaut : {value}"
console.departure.checkedInCount      "{done} / {total} enregistrés"
console.fleet.vehicles.registration.bus "Immatriculation"
console.fleet.vehicles.registration.air "Immatriculation (indicatif)"
console.fleet.layouts.airNotEnabled   "Votre compte n'est pas activé pour l'aérien."
```

`seat.class.first` / `.standard` / `.economy` / `.vip` already exist in `enums/domain.yaml` — reuse them for section labels rather than adding cabin names.

---

## 12. Demo inventory — the thing that makes all of this visible

`services/worker/lib/src/demo_world.dart` has no aircraft. Nothing above can be seen working until it does. This is slice **A1** and it comes first for exactly that reason.

- Operator: **Congo Airways Démo**, code `CAD`, `modes = {bus, air}`, accent `indigo`, its own vitrine
- Layout: `SeatLayout.airTwoClass()` under the name *"Q400 — 2 classes"*, mode `air`, features `cockpit` at the front and `galley`/`wc` at the rear, so A11 has something to draw
- Vehicle: registration `TN-AFA`, model *"Dash 8 Q400"*, amenities `[]` — an aircraft with wifi advertised is a lie a demo should not tell
- Route: Brazzaville → Pointe-Noire, the same 512 km corridor the coaches run. **The same city pair as the bus route, deliberately** — the mixed result list is the whole point of the chooser and it cannot be seen on disjoint routes.
- Departures: two a day, 07:15 and 16:40, fare 95 000 XAF economy (the multiplier gives first class its own price via the layout, not a second fare)
- Policy: no override rows — the demo carrier runs on the domain defaults, which is also how a real first carrier will start

`apps/traveller/lib/src/infrastructure/demo_travel_gateway.dart:75` and `:196` hardcode `mode: 'bus'`. Both become real values, and the demo gateway gains one air trip on the same pair, so the offline demo build shows the chooser working with no server at all.

`infra/dev/seed/` gains nothing: it holds roles, and the demo world is the worker's job (`dart run services/worker/bin/seed_demo.dart`, purgeable with `--purge`).

---

## 13. The roadmap — slices, in dependency order

House rules that apply to every slice: one commit, pushed; `dart run tool/check_layers.dart` clean; `dart format` before the anchor-sensitive edits, never after; `./tool/sync_i18n.sh` after catalog edits; `rm -rf services/api/build` before any smoke run; pipe `dart test` output through `tr '\r' '\n'`; update `docs/10-build-status.md` on completion.

### A1 — An aircraft exists

**Why first:** every later slice is invisible without it, and it is the only slice with no dependencies.

Files: `services/worker/lib/src/demo_world.dart`, `apps/traveller/lib/src/infrastructure/demo_travel_gateway.dart`.

Tests: `services/worker/test/demo_world_pg_test.dart` — the seeded world contains exactly one air layout, one air vehicle, and its departures have `mode = 'air'`; `--purge` removes them.

Done when: `dart run services/worker/bin/seed_demo.dart` then `GET /public/v1/trips?from=BZV&to=PNR&date=…&mode=air` returns two rows.

### A2 — `PassengerRequirements` in the domain

Files: **NEW** `packages/bel_domain/lib/src/catalog/passenger_requirements.dart`; export from `bel_domain.dart`.

Tests: `packages/bel_domain/test/catalog_test.dart` — `bus.isVisible(dateOfBirth)` is false; a field absent from the map is `hidden`; `visible` is in form order; `forMode` is total over `TransportMode`.

Done when: pure-domain tests pass. Nothing else changes.

### A3 — The booking form asks the right questions, and only those

**The slice the whole feature is judged on.**

Files: `0046_passenger_identity.sql`; `PassengerDto`; `PassengerRequirementsDto`; `HoldDto`; `services/api/lib/src/application/reserve_booking.dart`; `postgres_*` write path; `routes/public/v1/bookings.dart`; `routes/public/v1/holds.dart`; `apps/traveller/lib/src/presentation/screens/passengers_screen.dart`.

Tests, and all five must exist:

1. An air booking with no `idNumber` fails with `PassengerFieldMissing(idNumber)`
2. An air booking with an `idExpiry` before `departs_at` fails with `PassengerFieldRejected(idExpiry, 'errors.travel.idExpired')`
3. **A bus booking sending `dateOfBirth`, `nationality`, `idType` and `idExpiry` succeeds, and all four columns are `NULL` in `booking_seats`** — against real Postgres, reading the row back
4. A bus booking body identical to today's serialises to byte-identical JSON
5. `passengers_screen` widget test: with bus requirements, the widget tree contains no date-of-birth field by any finder

Done when: 1–5 green and `check_layers.dart` clean.

### A4 — `BoardingPolicy` in the domain

Files: **NEW** `packages/bel_domain/lib/src/catalog/boarding_policy.dart`; export.

Tests: `checkInIsOpen` is false for bus at every instant; the air window opens at T−24h and closes at T−60m inclusive/exclusive as written; `gateClosesAt` is after `checkInClosesAt` for air.

### A5 — Check-in, end to end

Files: `0047_check_in.sql`; `TicketDto`; **NEW** `routes/public/v1/bookings/[ref]/check-in.dart`; **NEW** `routes/console/v1/departures/[id]/check-in.dart`; `apps/traveller/.../ticket_screen.dart`; console departure detail.

Tests: check-in before the window → 409 carrying both instants; inside → sets `checked_in_at`; a second call returns the same result and does not move the timestamp; check-in on a bus departure → 409 `checkInNotRequired`; a checked-in ticket's `qrPayload` is **byte-identical** to before (the no-re-signing guarantee, and the test that stops a future refactor from breaking it).

### A5b — A departure knows when its sales close

**Separated deliberately: this changes live bus behaviour.**

Files: `services/worker/lib/src/timetable_horizon.dart`.

Tests: a bus departure materialised with no operator value gets `sales_close_at = departs_at - 30 min`; an operator's explicit value is never overwritten; an existing row with a null is left alone by the backfill (there is no backfill — that is the test).

### A6 — `BaggagePolicy`, quoted everywhere and sold nowhere

Files: **NEW** `packages/bel_domain/lib/src/catalog/baggage_policy.dart`; `BaggageAllowanceDto`; `TripDto.baggage`; `TicketDto.baggage`; results row, seat-map header, review screen, ticket screen; catalog keys.

Tests: `forSection('F')` returns the first-class allowance and `forSection('Y')` the default; `busNone.included.isNothing` is true; the results row renders nothing at all for bus (a "0 kg" badge on a coach is worse than silence).

### A7 — The market says which products it sells

Files: `config/markets.yaml`; `Market` in `bel_domain`; `MarketDto.offerings`; `routes/public/v1/market.dart`.

Tests: a `markets.yaml` with no `offerings:` key yields `['bus']`; the ETag changes when `offerings` changes; a client parsing a body without `offerings` gets `['bus']`.

**Shared with rental and stays.** This slice is a prerequisite of ADR-0028 and ADR-0029 as well; whichever vertical reaches it first builds it, and the other two get it free.

### A8 — The chooser

Files: **NEW** `packages/bel_design/lib/src/components/k_mode_picker.dart`; `search_screen.dart`; `results_screen.dart`; `KTripCard`; `theme_preference.dart` for the remembered choice; catalog keys.

Tests: golden for `KModePicker` in both themes; `search_screen` renders no picker when `market.modes.length == 1`; choosing *Avion* puts `mode=air` on the query; the empty state after a filtered search offers to clear the filter.

Done when: the demo build shows a bus and a flight on Brazzaville → Pointe-Noire and the chooser separates them.

### A9 — The card shows what it is

Files: `KTripCard` silhouette; `seat_map_screen.dart` mode-aware title and front marker.

Tests: goldens for both modes.

### A10 — The capability flag ADR-0017 asked for

Files: `0048_operator_air_profile.sql`; `routes/console/v1/policies/modes.dart`; `routes/admin/v1/operators/[id]/index.dart`; console policies screen; layout builder gating.

Tests: an operator without `air` in `offerings` publishing an air departure is refused **at the API**, not merely hidden in the UI; a console user cannot set their own `offerings` — the field is ignored on the console path and honoured only on the admin path; a policy row with all-NULL columns resolves to the domain defaults.

### A11 — The cabin is drawn

Files: `KSeatMap` renders `LayoutFeatureDto` — `cockpit`, `galley`, `wc`, `exit`, `door`, `stairs`, `luggage`, `driver`. Exit rows get a visible marker because that is a regulated seat a traveller should recognise before they choose it.

Tests: goldens for `airTwoClass()` with features, and for a bus layout with `door`/`wc`/`driver`, proving the same component draws both.

### A12 — The policy is snapshotted onto the departure

Files: `0049_departure_policy_snapshot.sql`; `timetable_horizon.dart`; `postgres_departure_catalogue.dart` reading the three JSONB columns with NULL → domain default.

Tests: changing an operator's policy does not alter a departure that already has bookings; a departure row with three NULLs resolves to the mode defaults; `bel_public` **cannot** select from `operator_mode_policies` (add it to `infra/migrations/verify_public.sql`).

### A13 — The scanner's third outcome

Files: boarding bundle; `apps/scanner` result rendering; catalog key.

Tests: a valid unchecked-in ticket on an air departure yields the amber outcome, not the red one; the same ticket on a bus departure boards normally.

### A14 — The manifest becomes an aviation manifest

Files: `console/v1/departures/[id]/manifest.dart` and its PDF; console manifest screen.

Tests: an air manifest carries the four identity columns; a bus manifest carries none of them and is unchanged byte-for-byte from today.

---

## 14. Deliberately not in v2

Each of these is reasonable and each would turn a shippable feature into a programme.

- **Fare families** — the genuine fourth seam (§3.4). Trigger for ADR-0028.
- **Selling excess baggage** — quoted, not sold (§3.3).
- **Weight and balance** — mitigated by `SeatLayout.blocked` (§3.3).
- **Infants on lap, unaccompanied minors, medical SSRs** — DOB is captured, so the data exists when the policy does. Each needs a carrier's actual written rule, and inventing one is worse than not offering it.
- **Interline, codeshare, multi-leg itineraries** — `09-roadmap.md` already lists multi-leg under "deliberately not building". Air does not change that.
- **DCS integration** — ADR-0017 flags that a carrier may already run one we must not fight. Until a partner exists, our manifest is the manifest.
- **Exit-row eligibility questioning** — the row is drawn and marked (A11); the regulated questions are asked at the desk. Asking them in-app implies we validate the answers.
- **International sectors** — passport validity windows, APIS, visa rules. Domestic Congo only.

---

## 15. Open questions for the first carrier

These cannot be answered from this side of the table. Each has a defensible default in the code, and the default is written down so the conversation starts from something concrete rather than from a blank form.

1. Check-in window — default T−24h to T−60m. Some domestic carriers use T−48h and T−45m.
2. Gate close — default T−20m.
3. Sales cut-off — default T−2h. This is the one most likely to be wrong; a carrier selling to the gate would want T−90m.
4. ID strictness — default `strict` with `nameChangeIsReissue`. If the carrier will accept a name correction, that is a materially better product and worth asking for.
5. Baggage — default 1 × 23 kg + 7 kg cabin, first class 2 × 32 kg + 10 kg.
6. Excess rate — no default; the field stays null and the app says nothing until a number exists.
7. Who owns the manifest of record, us or their existing system.
8. Whether they want desk check-in in the console on day one, or only self-service.

---

## 16. Reading order for whoever implements this

`docs/adr/0017-multimodal-transport.md` · this document §2 and §3 · `packages/bel_domain/lib/src/catalog/seat_layout.dart` · `infra/migrations/0006_departure_presentation.sql` (the comment, not the DDL) · `services/api/lib/src/application/reserve_booking.dart` · `apps/traveller/lib/src/presentation/screens/passengers_screen.dart`.

Then start at A1. It takes an hour and everything after it is visible.
