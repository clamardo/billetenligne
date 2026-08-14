# BilletEnLigne — Stays: hotels, guesthouses and résidences, end to end

**Status:** Specification and implementation roadmap · **Date:** 2026-08-14 · **Implements:** [ADR-0029](adr/0029-stays.md) · **Governed by:** [ADR-0027](adr/0027-verticals-are-separate.md) · **Reads with:** [ADR-0030](adr/0030-reviews.md), [`14-reviews.md`](14-reviews.md)

## 0. What this document is

ADR-0029 decided what stays are, why the incumbent channel is beatable here, and which industry standards we adopt. This says how to build it: package, schema, columns, DTOs, routes, screens, tests, in dependency order.

Five things to hold onto before starting, each of which is a mistake that has been made by everybody who has built this before:

1. **A stay from the 3rd to the 6th is three nights, and the 6th is not sold.** §3.1 makes it unrepresentable. Every phantom-availability bug in this category is this off-by-one.
2. **A hotel sells a room *type*, not a room.** Which physical room the guest gets is the front desk's decision at check-in. Modelling units would mean allocating room numbers, which no hotel will accept and which breaks the moment they upgrade somebody.
3. **A three-night booking touches three availability rows in one transaction, `ORDER BY night`.** Any other order is a deadlock under concurrency, and it will not show up in a single-threaded test.
4. **Pay-at-property is not a lesser option; it is how we get supply.** §3.6. On it, the property pays no commission and the guest pays a flat booking fee.
5. **`packages/bel_stay` may not import `bel_domain` or `bel_rental`.** `tool/check_layers.dart` fails the build if it does.

---

## 1. Current state, and what is reused

There is no stay anything in the repository.

Reused unchanged: operators, KYB and the self-serve application wizard, staff and capabilities, email sign-in and TOTP, `Money` and currency handling, the double-entry ledger, all five payment rails, refunds and disbursement, the notification outbox, the localization catalog, the Kilo design system, the vitrine, the public-token artefact pattern, and `infra/`.

The user's request — *"user can add their org, and hotel and manage room and payment"* — is largely already built. A hotelier signs up through the **same operator application wizard** a coach company uses (`03-operator-lifecycle.md` §2.2, migration `0015`), lands in the same review queue, and gets the same audit trail and the same six decisions. The application gains one field, `intended_offerings`, and platform staff set `offerings` on approval. Nothing else in onboarding changes, and that is the point of ADR-0027.

---

## 2. Prerequisite

**[`15-platform-split.md`](15-platform-split.md), slices P1–P5.** Blocking, and shared with rental — whichever vertical starts first builds it.

Stays additionally needs P4's per-schema migration sequence for `infra/migrations/stay/`, the `stay` schema, and `bel_stay_app` as a new member of the existing role family. Note that the runner's baseline probe — *"`schema_migrations` is absent but `operators` exists"* — is the root sequence's alone; a `stay` sequence with no rows on a live database is the normal state of a vertical that has not shipped, not an unknown baseline.

---

## 3. The domain — `packages/bel_stay`

### 3.1 Nights

The type whose entire job is the off-by-one.

```dart
/// A stay. Half-open over nights: [checkIn, checkOut). The checkout date is
/// NOT a sold night, and every phantom-availability bug in this category is
/// that one sentence being wrong somewhere.
final class StayPeriod {
  StayPeriod({required this.checkIn, required this.checkOut})
      : assert(checkOut.isAfter(checkIn), 'checkOut must be after checkIn');

  /// Local calendar dates in the market's timezone, never instants. "Nights
  /// of the 3rd" is a local-day question, and a UTC timestamp puts a
  /// Brazzaville night on the wrong date for part of the year in markets
  /// that observe daylight saving.
  final DateTime checkIn;
  final DateTime checkOut;

  int get nights => checkOut.difference(checkIn).inDays;

  /// The nights actually sold. Never includes checkOut. Every availability
  /// read and write goes through this; nothing anywhere iterates dates by
  /// hand.
  List<DateTime> get nightsCovered => [
        for (var i = 0; i < nights; i++) checkIn.add(Duration(days: i)),
      ];

  bool coversNight(DateTime d) => !d.isBefore(checkIn) && d.isBefore(checkOut);
}
```

### 3.2 Property and room type

```dart
enum PropertyKind { hotel, auberge, residence, appartement, lodge, motel }

final class Property {
  const Property({
    required this.id,
    required this.operatorId,
    required this.name,
    required this.kind,
    required this.cityCode,
    required this.address,
    required this.lat,
    required this.lng,
    required this.amenities,
    required this.photos,
    this.neighbourhood,
    this.starRating,          // official classification; usually null
    this.backupPowerHours,    // see §3.7
    this.descriptionFr,
    this.descriptionEn,
    this.phone,
    this.checkInFrom,
    this.checkOutBy,
  });
}

final class RoomType {
  const RoomType({
    required this.id,
    required this.propertyId,
    required this.name,
    required this.maxOccupancy,
    required this.beds,
    required this.sizeM2,
    required this.amenities,
    required this.photos,
    this.extraBedAvailable = false,
    this.extraBedPrice,
  });
}
```

**A property is not an operator.** A three-hotel chain is one operator row, one contract, one payout account and three properties. Modelling a property as an operator would give it three contracts and three payout runs (ADR-0029).

### 3.3 Rate plans — the fourth seam

```dart
final class RatePlan {
  const RatePlan({
    required this.id,
    required this.roomTypeId,
    required this.name,             // catalog key or operator's own words
    required this.cancellation,
    required this.inclusions,
    required this.paymentTiming,
    this.minStay,
    this.maxStay,
    this.closedToArrival = false,
    this.closedToDeparture = false,
  });
}
```

A rate plan bundles four things sold as one: a price series, a cancellation rule, an inclusion set, and a payment timing. It is **not** a `PriceModifier` and must not be smuggled in as one (ADR-0029).

The canonical two a property offers:

- *Tarif flexible* — free cancellation until 18:00 the day before, breakfast optional, `firstNight` or `prepaid`
- *Non remboursable* — 10–20% cheaper, no refund, `prepaid`

Prices live per plan **per night**, not as a base with modifiers, because that is the ARI shape every channel manager pushes (§17) and because a revenue manager thinks in a calendar of numbers, not in a formula.

### 3.4 Cancellation, counted in nights

```dart
sealed class CancellationRule {
  const CancellationRule();
}

/// Free until an absolute local instant derived from check-in.
final class FreeUntil extends CancellationRule {
  const FreeUntil({required this.hoursBeforeCheckIn, required this.localHour});
  final int hoursBeforeCheckIn;
  /// Wall-clock hour at the property. "18:00 la veille" is how this is
  /// actually expressed here, and "24 hours before" is not the same thing
  /// when check-in is 14:00.
  final int localHour;
}

/// After the free window, forfeit N nights.
final class ForfeitNights extends CancellationRule {
  const ForfeitNights(this.nights);
  final int nights;
}

final class NonRefundable extends CancellationRule {
  const NonRefundable();
}
```

The deadline is always resolved to and displayed as **an absolute local date and time**. Never "24h avant". A relative deadline gets computed wrong by tired people, and this is the number a nervous first-time prepayer reads twice.

### 3.5 Inclusions — stays' own type

```dart
final class StayInclusions {
  const StayInclusions({
    this.breakfast = false,
    this.dinner = false,
    this.airportShuttle = false,
    this.parking = false,
    this.laundryPerWeek = 0,
  });
}
```

No supertype with air's baggage or rental's fuel and mileage (ADR-0027 §7).

### 3.6 Payment timing

```dart
enum PaymentTiming {
  /// In full at booking, on our rails. Commission netted at source, the
  /// property paid on the normal payout cycle.
  prepaid,

  /// The guest pays the property at check-in. The property pays NO
  /// commission. The guest pays a small flat booking fee on our rails, which
  /// makes the channel free for the property, is collectible without chasing
  /// anybody, and gives the booking a cost — which is what stops no-shows.
  payAtProperty,

  /// First night now to hold the room, the balance at the property.
  firstNight,
}
```

`payAtProperty` is the supply unlock and it must be first-class everywhere: filterable at search, prominent on the row, plain on the voucher, and stated in the SMS.

### 3.7 Amenities — the vocabulary that is the product

A closed set, in this order, because free text cannot be filtered and every property would spell the same thing differently:

`groupe_electrogene` · `eau_chaude` · `climatisation` · `wifi` · `parking_garde` · `petit_dejeuner` · `restaurant` · `piscine` · `blanchisserie` · `navette_aeroport` · `securite_24h` · `ascenseur` · `chambre_familiale` · `acces_pmr` · `paiement_mobile_sur_place`

The first two are the differentiators no incumbent offers, and the first deserves more than a checkbox:

```dart
/// How many hours of backup power the property actually provides. NULL when
/// unstated. "We have a generator" and "the generator runs all night" are
/// different products, and every traveller here knows it.
final int? backupPowerHours;   // 0..24
```

Displayed as *"Groupe électrogène — {hours} h/jour"*, and as an unqualified *"Groupe électrogène"* when null. A property that claims 24 and does not deliver acquires a public record of it through `electricite_wifi`, the market-specific review sub-score (ADR-0030 §2). The claim and the check are designed as a pair.

### 3.8 Guests, and the rule applied for the fourth time

```dart
enum GuestField { fullName, phone, email, idNumber, nationality, arrivalTime }

final class GuestRequirements {
  const GuestRequirements(this.fields);
  final Map<GuestField, FieldRequirement> fields;
  FieldRequirement of(GuestField f) => fields[f] ?? FieldRequirement.hidden;

  static const domestic = GuestRequirements({
    GuestField.fullName: FieldRequirement.required,
    GuestField.phone: FieldRequirement.required,
    GuestField.email: FieldRequirement.optional,
    GuestField.arrivalTime: FieldRequirement.optional,
    GuestField.idNumber: FieldRequirement.optional,
  });
}
```

Every field not named is `hidden`. **A hotel guest is never asked for a driving licence number because `bel_rental` has one, and never for a passport number because `bel_domain` has one** — and the packages cannot even see each other's types. This is ADR-0017's rule implemented for the fourth time, independently, which ADR-0027 §7 argues is better than one type with four disjoint regions.

Only the **lead guest** is required. Names for the other occupants are optional and asked for once, on the review screen, because most properties here do not need them and a form that demands four names loses bookings.

### 3.9 The window

```dart
final class StayWindowPolicy {
  const StayWindowPolicy({
    required this.checkInFrom,     // local time of day, default 14:00
    required this.checkOutBy,      // default 11:00
    required this.lateArrivalUntil,// default 22:00; beyond it, call ahead
    required this.noShowAt,        // local time on the check-in date
    required this.releasePeriodDays,
  });
}
```

`releasePeriodDays` is the staleness guard: allotment that has not been updated within this many days of a night **closes itself** rather than being sold. A property that stops maintaining its calendar stops selling; it does not oversell. That is the mitigation for the biggest risk in the vertical (§16).

---

## 4. Availability

### 4.1 The table and the guarantee

```sql
CREATE TABLE stay.availability (
  room_type_id UUID NOT NULL REFERENCES stay.room_types(id) ON DELETE CASCADE,
  night        DATE NOT NULL,
  allotment    INTEGER NOT NULL,
  sold         INTEGER NOT NULL DEFAULT 0,
  held         INTEGER NOT NULL DEFAULT 0,
  closed       BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (room_type_id, night),
  CONSTRAINT availability_not_oversold CHECK (sold + held <= allotment),
  CONSTRAINT availability_sane
    CHECK (allotment >= 0 AND sold >= 0 AND held >= 0)
);
```

`CHECK (sold + held <= allotment)` is the structural guarantee, the same class of thing as the ledger's balance constraint and rental's exclusion constraint: the database refuses, whatever the application believes. Holds count against it, so a room being paid for is not sold twice while the payment is in flight.

### 4.2 The transaction, and the `ORDER BY` that is not decoration

```sql
-- Inside ONE transaction, for a StayPeriod's nightsCovered:
UPDATE stay.availability
   SET held = held + $rooms, updated_at = now()
 WHERE room_type_id = $rt
   AND night = ANY($nights)
   AND closed = FALSE
   AND sold + held + $rooms <= allotment;
-- affected rows must equal nights.length, or ROLLBACK.
```

Postgres locks the rows in the order it finds them, so the statement is written to touch them in **date order** and every path that locks availability rows does the same. Two concurrent three-night bookings that lock in opposite orders deadlock, and the failure is intermittent, load-dependent and invisible in a single-threaded test. **Write the concurrency test in R-slice S4 before writing the booking path.**

`sold + held + $rooms <= allotment` in the `WHERE` means a losing race updates zero rows and rolls back cleanly, rather than raising a constraint violation. The `CHECK` remains as the backstop that catches any path that forgets.

### 4.3 Restrictions

Per rate plan per night, in `stay.restrictions`, spelled the way the whole industry spells them (§17): `min_stay`, `max_stay`, `closed_to_arrival`, `closed_to_departure`, `stop_sell`.

Evaluation order, and it matters: `stop_sell` first (nothing sells), then `closed_to_arrival` against the check-in night only, `closed_to_departure` against the checkout night only, then `min_stay`/`max_stay` against `nights`. A search that filters in a different order produces results a property did not intend to sell.

---

## 5. Schema

`infra/migrations/stay/`, its own sequence.

- **`0001_schema.sql`** — schema `stay`, role `bel_stay_app`, grants
- **`0002_properties.sql`** — `properties`, `property_amenities`, `photos`
- **`0003_room_types.sql`** — `room_types`, `room_type_amenities`
- **`0004_rates.sql`** — `rate_plans`, `rate_prices`, `restrictions`
- **`0005_availability.sql`** — `availability` (§4.1)
- **`0006_reservations.sql`** — `reservations`, `guests`
- **`0007_policies.sql`** — `window_policies`, `cancellation_rules`

Details worth stating:

`stay.properties` — `operator_id → public.operators`, `city_code → public.cities`, `name`, `kind`, `address`, `neighbourhood`, `lat`, `lng`, `phone`, `star_rating` (nullable, **never computed**), `backup_power_hours` (nullable, `CHECK BETWEEN 0 AND 24`), `description_fr`, `description_en`, `status`, `published_at`.

`stay.rate_prices` — `(rate_plan_id, night)` primary key, `price_minor`, `currency`. One row per plan per night. A year of one plan is 365 rows; a property with four room types and two plans is ~2 900 rows a year, which is nothing, and the flat shape is what makes a channel-manager adapter a mapping rather than a translation (§17).

`stay.reservations` — `id`, `ref`, `operator_id`, `property_id`, `room_type_id`, `rate_plan_id`, `check_in DATE`, `check_out DATE`, `rooms`, `adults`, `children`, `state`, `payment_timing`, `total_minor`, `prepaid_minor`, `due_at_property_minor`, `booking_fee_minor`, `currency`, `cancellation_deadline TIMESTAMPTZ`, `payable_id → public.payables`, `created_at`, `confirmed_at`, `cancelled_at`, `checked_in_at`, `no_show_at`.

```sql
CONSTRAINT reservations_nights_positive CHECK (check_out > check_in),
CONSTRAINT reservations_money_splits
  CHECK (total_minor = prepaid_minor + due_at_property_minor)
```

The second constraint is the one that keeps `payAtProperty` honest: on it, `prepaid_minor` is zero, `due_at_property_minor` is the whole stay, and `booking_fee_minor` — the guest's fee, which is what we actually collect — is deliberately outside the equation because it is not part of the stay's price.

---

## 6. Contracts

`packages/bel_stay_contracts`, mirroring `bel_contracts`' conventions exactly.

`StaySearchQuery` — `cityCode`, `checkIn`, `checkOut`, `rooms`, `adults`, `children`, `amenities` (`List<String>`), `paymentTiming`, `priceMax`, `cursor`, `limit`.

`StayOfferDto` — the search row: property id, name, kind, neighbourhood, first photo, star rating, guest rating and count (ADR-0030), distance from the city centre, the cheapest available rate plan's total for the whole stay **and** its per-night figure, the payment timing, the free-cancellation deadline as an absolute instant, `backupPowerHours`, and the three top amenities.

Then `PropertyDto`, `RoomTypeDto`, `RatePlanDto`, `AvailabilityDto`, `StayQuoteDto`, `GuestRequirementsDto`, `GuestDto`, `CreateStayHoldRequest`, `CreateReservationRequest`, `ReservationDto`, `VoucherDto`.

**The row shows the total for the stay, not the nightly rate alone.** A per-night price next to a three-night search is the oldest dishonesty in the category. Both are shown; the total is the larger type.

---

## 7. API surface

Under `services/api/routes/stay/`, extractable by moving the directory.

- `GET  /stay/v1/properties?city=&checkIn=&checkOut=&…` — search, keyset paginated
- `GET  /stay/v1/properties/[id]?checkIn=&checkOut=&…` — detail with available room types and plans
- `GET  /stay/v1/properties/[id]/availability?from=&to=` — the calendar strip for the date picker
- `POST /stay/v1/holds` — `Idempotency-Key` header; 15 minutes
- `POST /stay/v1/reservations`
- `GET  /stay/v1/reservations/[ref]`
- `POST /stay/v1/reservations/[ref]/cancellation`
- `GET  /stay/v1/reservations/[ref]/voucher`
- Payment reuses `/public/v1/payments` through the payable. No second funnel.

Console, under `console/v1/stay/`: `properties`, `properties/[id]/photos`, `room-types`, `rate-plans`, `calendar` (bulk ARI edit), `restrictions`, `reservations`, `reservations/[ref]/check-in`, `reservations/[ref]/no-show`, `policies`.

The voucher is reachable at the existing `t/[token]` pattern (ADR-0026), so a guest with a feature phone opens it from an SMS.

---

## 8. Console — the screen a receptionist uses on a phone

This is the make-or-break surface. Coach operators configure a timetable once a season; a hotel updates a calendar every day, often on a phone, often by somebody who did not choose this software.

- **Calendar / ARI grid.** Room types down, dates across; per cell the allotment, the count sold and the price. **Bulk edit is the primary action, not an advanced one**: select a date range and a set of weekdays, then set price, allotment, min-stay or stop-sell in one gesture. A property setting 90 nights one cell at a time will stop after four days and the inventory goes stale, which is the failure this vertical dies of.
- **Freshness.** The dashboard's first line is *"calendrier à jour jusqu'au {date}"*, with the release-period warning when it is running out.
- **Today.** Arrivals, departures and in-house, in that order. It is the receptionist's actual day.
- **Reservations.** With check-in and no-show actions.
- **Property.** Name, address, map pin, amenities, backup power hours, descriptions, photos.
- **Room types.** Beds, occupancy, size, amenities, photos.
- **Rate plans.** Cancellation, inclusions, payment timing, restrictions.
- **Photos.** Drag to reorder, first is the hero, upload date shown on every one.

---

## 9. Traveller feature package

`packages/bel_feature_stay`, registered in the shell (ADR-0027 §5), rendered only when `market.offerings` contains `stay`.

Search · results · property detail · room and plan choice · guest details · review · payment · confirmation · my stays · voucher.

Details that decide whether it feels honest:

- **The search bar is city, dates, guests.** Not origin and destination. A different vertical, a different question.
- **The date picker counts nights and says so** — *"3 nuits"* under the range — because that is where the guest's mental model and the system's have to meet.
- **The row shows the stay total.** Per-night beside it, smaller.
- **`payAtProperty` is a badge, not fine print**: *"Payez à l'hôtel — {fee} de réservation"*.
- **The cancellation deadline is an absolute local date and time**, on the row, not only at checkout.
- **`groupe_electrogene` and `eau_chaude` are the first amenities shown** when present. They are the differentiators; burying them under *piscine* wastes the whole vocabulary decision.
- **Photos carry their upload date.** A 2019 photograph of a room is a claim about today.
- **No map view in v1.** A neighbourhood name and a distance from the centre, with a link out to the device's map app. Tiles are a cost and a dependency, and the marginal booking they win here is small.

---

## 10. Photos

Genuinely new infrastructure. Today there is `operators.logo_asset`, `cover_asset`, `vehicles.photo_asset` and a single-asset route.

- Upload through the console; stored under the existing object-storage abstraction with a `storage_key`, the same as KYB documents
- Server-side derivatives at upload: `thumb` 320w, `card` 800w, `full` 1600w, all WebP with JPEG fallback. **A 4 MB hero image on a 2G connection is a lost booking**, and this is the one place in the product where image weight is a conversion metric.
- Ordered by `position`; the first is the hero
- `uploaded_at` displayed on the gallery
- Maximum 30 per property, 10 per room type
- **No stock photography.** A property uploads photographs of itself or it does not list. Enforced by review at approval, not by an algorithm — but stated in the operator terms so the removal is not a surprise.

---

## 11. Worker

- **Hold expiry** — every minute; decrements `held`
- **Availability freshness** — nightly; closes nights beyond the release period on stale room types and notifies the property
- **Calendar-ageing reminder** — weekly to properties whose calendar ends within 30 days
- **Pre-arrival** — SMS to the guest 48 hours and on the morning of check-in, with the property's phone number and the address
- **No-show** — at the property's `noShowAt`, mark and notify; applies the cancellation rule
- **Post-checkout** — writes the `review.eligibilities` row (ADR-0030 §5) the morning after checkout, which is when people actually have an opinion
- **Aggregate refresh** — ratings
- **Overbooking incident** — if a confirmed reservation ever exists against a closed or reduced allotment, raise it to platform staff **before** the guest arrives (§16)

---

## 12. Localization

New: `i18n/{fr,en}/pages/stay.yaml`, `i18n/{fr,en}/enums/stay.yaml`, `i18n/{fr,en}/reference/amenities.yaml`.

```
stay.search.title           "Où dormez-vous ?"
stay.search.city            "Ville"
stay.search.checkIn         "Arrivée"
stay.search.checkOut        "Départ"
stay.search.nights          "{count} nuits"
stay.search.oneNight        "1 nuit"
stay.search.guests          "{adults} adultes, {rooms} chambre(s)"

stay.offer.totalForStay     "{price} pour {nights} nuits"
stay.offer.perNight         "{price} / nuit"
stay.offer.payAtProperty    "Payez à l'hôtel"
stay.offer.bookingFee       "Frais de réservation : {fee}"
stay.offer.freeCancelUntil  "Annulation gratuite jusqu'au {date} à {time}"
stay.offer.nonRefundable    "Non remboursable"
stay.offer.newProperty      "Nouveau"
stay.offer.fromCentre       "à {km} km du centre"

stay.property.backupPower       "Groupe électrogène — {hours} h/jour"
stay.property.backupPowerPlain  "Groupe électrogène"
stay.property.photoTakenOn      "Photo du {date}"
stay.property.officialStars     "{count} étoiles (classement officiel)"

stay.room.maxOccupancy      "Jusqu'à {count} personnes"
stay.room.extraBed          "Lit supplémentaire : {price}/nuit"
stay.room.left              "Plus que {count} à ce prix"

stay.guest.leadGuest        "Personne principale"
stay.guest.arrivalTime      "Heure d'arrivée prévue"
stay.guest.lateArrival      "Après {time}, prévenez l'hôtel au {phone}."

stay.voucher.title          "Votre réservation"
stay.voucher.dueAtProperty  "À régler sur place : {amount}"
stay.voucher.showThis       "Présentez cette référence à la réception."

reference.amenities.groupe_electrogene "Groupe électrogène"
reference.amenities.eau_chaude         "Eau chaude"
reference.amenities.parking_garde      "Parking gardé"
reference.amenities.securite_24h       "Sécurité 24h/24"
reference.amenities.navette_aeroport   "Navette aéroport"
reference.amenities.paiement_mobile_sur_place "Mobile money accepté sur place"

console.stay.calendar.bulkEdit    "Modifier une période"
console.stay.calendar.freshUntil  "Calendrier à jour jusqu'au {date}"
console.stay.calendar.stale       "Votre calendrier se termine dans {days} jours."
console.stay.calendar.stopSell    "Vente arrêtée"

errors.stay.noLongerAvailable "Cette chambre vient d'être réservée."
errors.stay.minStay           "Séjour minimum de {nights} nuits à ces dates."
errors.stay.closedToArrival   "Arrivée impossible à cette date."
errors.stay.checkoutBeforeCheckin "La date de départ doit suivre la date d'arrivée."
```

---

## 13. Demo data

Operator **Résidence Hôtelière Démo**, code `RHD`, `offerings = {stay}`, accent `ocean`. Two properties:

- *Hôtel Le Fleuve*, Brazzaville centre — `hotel`, 3 official stars, `backupPowerHours: 24`, amenities: generator, hot water, air conditioning, wifi, guarded parking, breakfast, restaurant. Three room types: Standard (8 rooms, 45 000/night), Supérieure (5, 62 000), Suite (2, 95 000). Two rate plans on each: flexible, and non-refundable at −15%.
- *Auberge Tchikapika*, Pointe-Noire — `auberge`, unclassified, `backupPowerHours: 8`, amenities: generator, hot water, wifi, mobile money on site. One room type (6 rooms, 28 000/night), one plan, `payAtProperty`.

The pair is deliberate: it makes visible the classified/unclassified distinction, both payment timings, both ends of the backup-power claim, and a property with one room type and one plan — which is what most real supply looks like.

Availability seeded 180 days forward, with one weekend stopped-sold and one date range at a higher price, so restrictions and per-night pricing have something to show.

---

## 14. Slices

House rules as in `12-rental.md` §13.

**P1–P5** — the platform split. Blocking.

**S1 — a schema and a role.** `stay/0001`. *Test:* applies twice idempotently; the `public`-to-`stay` foreign-key direction check fails a scratch migration.

**S2 — nights are nights.** `StayPeriod` in `bel_stay`, alone. *Tests:* the 3rd→6th is 3 nights; `nightsCovered` never contains the checkout date; equal dates assert; a reversed range asserts; a range across a month boundary and across 29 February.

**S3 — properties and room types.** `stay/0002`, `0003`; console CRUD; the amenity vocabulary. *Test:* an operator without `stay` in `offerings` is refused at the API.

**S4 — availability, and the concurrency test first.** `stay/0005`. **Write the test before the path.** *Tests, all against real Postgres:* two concurrent three-night bookings for the last room, exactly one succeeds; two concurrent bookings over overlapping ranges in opposite date order do **not** deadlock; `sold + held` can never exceed `allotment`, asserted by attempting it directly in SQL; a `closed` night is unsellable at any allotment.

**S5 — rate plans and prices.** `stay/0004`. *Tests:* a three-night stay sums the three nights' prices for the chosen plan and not a base × 3; a plan with a gap in its price series is not offered for a range covering the gap.

**S6 — restrictions.** *Tests:* `min_stay` 2 refuses a one-night stay; `closed_to_arrival` on the 5th refuses check-in on the 5th but allows a stay that passes through it; `closed_to_departure` on the 8th refuses checkout on the 8th; `stop_sell` beats everything; the evaluation order in §4.3 is asserted explicitly.

**S7 — search.** `GET /stay/v1/properties`, keyset paginated. *Tests:* a fully sold room type is absent; a property whose only plan is restricted for these dates is absent; amenity filters are conjunctive; the row's total equals the sum of its nights.

**S8 — hold.** Idempotent by header; 15 minutes; `held` decremented on expiry by the worker and treated as free by search before that.

**S9 — guests.** `GuestRequirements`; reservation creation. *Tests:* no lead guest fails; **a request carrying `licenceNumber` or a passport field succeeds and stores nothing** — read the row back and assert null.

**S10 — money, three ways.** `payables`; the three timings. *Tests:* `prepaid` nets commission and balances the ledger; **`payAtProperty` produces a payable of the booking fee only, and the property's commission is zero**; `firstNight` splits `prepaid_minor` and `due_at_property_minor` and the `CHECK` holds; a rail failure releases the held nights.

**S11 — cancellation.** *Tests:* inside the free window refunds in full through the existing refund machinery; outside it forfeits exactly `ForfeitNights.nights` nights' price; `NonRefundable` refunds nothing and says so before the guest confirms, not after; the deadline stored is an absolute instant and matches the local 18:00 rule across a month boundary.

**S12 — the traveller flow.** `bel_feature_stay` registered; search through confirmation. *Tests:* the shell shows no stay entry when `market.offerings` lacks it; goldens for the results row in both themes; the date picker's night count matches `StayPeriod.nights`.

**S13 — photos.** Upload, derivatives, ordering, upload date. *Tests:* a 6 MB upload yields a `thumb` under 40 KB; ordering survives a round trip; the hero is `position = 0`.

**S14 — the ARI calendar.** The console's bulk editor. *Tests:* a bulk edit over 90 nights with a weekday mask writes exactly the intended rows and no others; the freshness line matches the furthest priced night.

**S15 — the voucher.** At `t/[token]`. *Tests:* resolves without a session; shows the amount due at the property; a cancelled reservation's voucher says so rather than 404-ing.

**S16 — check-in, no-show, and the incident path.** *Tests:* no-show applies the cancellation rule; a confirmed reservation against a reduced allotment raises an incident to platform staff and does not silently fail.

**S17 — freshness and release.** *Tests:* a room type not updated within the release period has its far nights closed and the property notified once, not nightly.

**S18 — reviews.** Eligibility written the morning after checkout; the rating on the search row. Per `14-reviews.md`.

---

## 15. Out of scope for v1

- **Channel-manager integration.** ADR-0029 §3.3, with the model built ARI-shaped so the adapter is a mapping later (§17).
- **An OTA XML surface of our own.** We are not a channel manager.
- **Map search and tiles.** Neighbourhood and distance, with a link out.
- **Multi-room, multi-rate-plan baskets.** One room type and one plan per reservation; two room types is two reservations. A basket is a different checkout.
- **Dynamic pricing.** `09-roadmap.md` already lists it under deliberately-not-building.
- **Loyalty, genius-style discounts, member rates.** Same list.
- **Reviews with photographs.** The moderation cost is a step change and the corpus does not exist yet.
- **Translation of review text or property descriptions.** Properties write fr and en; neither is machine-translated, because a bad translation of a description is a claim we made.
- **International guest documents.** Domestic Congo. APIS, visa rules and passport-validity windows are a different product.

---

## 16. The risk this vertical dies of, and the four things that stop it

**Inventory staleness.** A property stops updating its calendar; we sell a room that does not exist; a guest arrives at 22:00 to be told there is nothing. That single event costs more trust than fifty good stays earn.

1. **Release period** (§3.9, S17) — stale allotment closes itself rather than overselling. The default failure is "we sold nothing", never "we sold a room that isn't there".
2. **Freshness on the console dashboard** (§8) — the first thing a property sees is how far their calendar reaches.
3. **Bulk edit as the primary action** (§8) — the reason calendars go stale is that maintaining them is tedious, and a 90-night edit in one gesture is the fix.
4. **An incident path with a human** (§11, S16) — when it happens anyway, platform staff find and pay for alternative accommodation before the guest arrives, and the cost of that is a cost of doing business rather than a review.

---

## 17. Appendix — the standards, and where each field lands

ADR-0029 §3 decided what we adopt. This is the mapping, written now so that the eventual channel-manager adapter is a table lookup and nobody has to reverse-engineer our intent.

**ARI → our columns**

- `Availability` / `Inventory` → `stay.availability(room_type_id, night, allotment, sold, held, closed)`
- `Rates` → `stay.rate_prices(rate_plan_id, night, price_minor, currency)`
- `Restrictions` → `stay.restrictions(rate_plan_id, night, min_stay, max_stay, closed_to_arrival, closed_to_departure, stop_sell)`

**OTA message → our surface**

- `OTA_HotelAvailRQ/RS` → `GET /stay/v1/properties` and `/stay/v1/properties/[id]/availability`
- `OTA_HotelResRQ/RS` → `POST /stay/v1/reservations`
- `OTA_CancelRQ/RS` → `POST /stay/v1/reservations/[ref]/cancellation`
- `OTA_HotelRateAmountNotifRQ` → the console's bulk calendar edit, or a future adapter writing `rate_prices`
- `OTA_HotelAvailNotifRQ` → the same, writing `availability`
- `OTA_HotelInvCountNotifRQ` → `availability.allotment`

**Deliberate divergences, and why**

- **1–5 stars, not Booking's 1–10.** Regional legibility; ADR-0030.
- **`backup_power_hours` and the `groupe_electrogene` / `eau_chaude` amenities** have no counterpart in any standard. They are the product. A future adapter maps them into a free-text description field and loses them, which is acceptable in that direction and would not be acceptable in ours.
- **`payAtProperty` with a guest booking fee** is not how OTAs model payment. It is how supply is won here, and it is the one commercial mechanic we would not give up to be standards-compliant.
- **No property-level `RoomStay` allocation.** We never allocate a room number; standards permit this and most implementations exercise it. We do not.

The rule for anybody extending this: **where a standard has a field for something we have, use its name and its shape.** Where we have something the standard does not, keep ours and do not contort. The mapping above is the record of which is which.
