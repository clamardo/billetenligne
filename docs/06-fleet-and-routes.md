# BilletEnLigne — Fleet, Seat Maps, Routes & Schedules

**Status:** Draft v1 · **Date:** 2026-08-09
**Implements:** ADR-0012 (inventory) · ADR-0017 (transport modes) · **Related:** `03-operator-lifecycle.md` (activation), `08-disruption.md` (equipment swap)

> The operator configures everything about a vehicle — coach or aircraft — its seat layout, its routes and its schedule. The system turns that into live availability in the traveller app. This document is the configuration surface that makes the marketplace real.

---

## 1. The configuration model

```
Operator
 ├─ Stations           physical agencies / boarding points
 ├─ Layout templates   reusable seat layouts, built from CABIN SECTIONS
 ├─ Vehicles           a physical coach or aircraft, referencing one layout
 ├─ Routes             origin → destination, with intermediate stops
 ├─ Schedule patterns  recurring rules producing Departures
 └─ Departures         one vehicle, one route, one date/time. THE SELLABLE UNIT.
```

Three ideas do the heavy lifting:

**Vehicles, not coaches.** Every vehicle carries a `TransportMode` (ADR-0017). v1 exposes `bus` only; the model supports `air` so the same console later configures an aircraft without a schema migration or a second product.

**Templates, not per-vehicle layouts.** An operator with fourteen coaches has two or three layouts. Draw each once, apply to many. A fleet of 14 becomes a 20-minute setup, not a two-hour one.

**Patterns, not individual departures.** "Every day at 06:00 and 14:00, except Sundays" generates departures automatically for a rolling horizon (default 90 days). Nobody creates 180 departures by hand.

---

## 2. Adding a vehicle

Five steps, completable on a tablet in the yard while looking at the actual vehicle.

```
┌──────────────────────────────────────────────────────┐
│  Ajouter un véhicule                   Étape 1 sur 5 │
├──────────────────────────────────────────────────────┤
│  Type            ◉ Car / bus      ○ Avion            │
│  Immatriculation [ BZ-4471-CG            ]           │
│  Nom / surnom    [ Le Rapide             ]  ⓘ        │
│  Marque / modèle [ Yutong ZK6122         ]           │
│  Année           [ 2019 ]                            │
│  Photo (facult.) [ 📷 Prendre une photo  ]           │
│                                                      │
│  ⓘ Le surnom aide vos équipes. Les voyageurs voient  │
│    le modèle et le schéma des sièges.                │
└──────────────────────────────────────────────────────┘
```

| Step | Contents |
|---|---|
| **1 · Identité** | Mode, registration/plate (unique per operator), nickname, make/model, year, optional photo |
| **2 · Disposition** | Pick a layout template, or open the section builder (§3) |
| **3 · Confort** | Amenities as toggles with icons: climatisation · USB · Wi-Fi · TV · toilettes · sièges inclinables · porte-bagages · prise 220 V. These drive traveller filters and must be honest — a false AC claim generates refund requests. |
| **4 · Classes & tarifs** | Price modifier per cabin section (§3.4) |
| **5 · Conformité** | Technical inspection + insurance (bus) or airworthiness + operating certificate (air), **with expiry dates**. Expiry blocks the vehicle from new departures (`03-operator-lifecycle.md` §3.3). |

Status per vehicle: `active` · `maintenance` · `out_of_service` · `blocked_compliance`. Changing to anything but `active` immediately surfaces **affected future departures** with a resolution flow — reassign a vehicle, or declare a disruption (`08-disruption.md`). It never silently drops bookings.

---

## 3. The seat layout designer

The most-demoed screen in the console. It has to feel effortless, because it is the moment an operator decides whether this system understands their business.

### 3.1 A layout is an ordered list of cabin sections

This is the core model (ADR-0017 §3), and it is what lets one designer serve a 2+2 coach, a VIP-front coach and a two-class aircraft without special cases:

```
Section 1 · Première      3 rangées × 2+3   =  15 places   × 2,5
Section 2 · Économique   10 rangées × 2+3   =  50 places   × 1,0
                                     Total     65 places
```

Each section carries: a code and label, a row count, an abreast configuration (`1+1`, `2+2`, `2+3`, `3+3`), a numbering rule, an optional price modifier and an optional seat pitch. Everything else — doors, lavatories, galleys, exits, luggage bays, the driver or cockpit position — is a **layout feature** placed on the grid.

The pay-off: a coach with a VIP front cabin is two sections, and the 5-across rear bench that every generic tool forgets is simply a one-row section. **The special cases disappear.**

### 3.2 Start from a template, never a blank canvas

```
┌────────────────────────────────────────────────────────┐
│  Disposition des sièges                                │
│                                                        │
│  Partir d'un modèle courant :                          │
│                                                        │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐       │
│  │ ▪▪ ▪▪  │  │ ▪▪ ▪▪▪ │  │ ⭐▪▪ ▪▪ │  │  vide  │       │
│  │ 2+2    │  │ 2+3    │  │ VIP +  │  │ créer  │       │
│  │ 49 pl. │  │ 65 pl. │  │ std 45 │  │        │       │
│  └────────┘  └────────┘  └────────┘  └────────┘       │
└────────────────────────────────────────────────────────┘
```

Presets cover what actually runs in Congo: 2+2 49/51-seat intercity, 2+3 65-seat, VIP-front two-section, 14/18-seat minibus — and, when air is enabled, common regional turboprop and narrow-body layouts. **Most operators never open the editor**: pick a preset, adjust the row count, done in 90 seconds.

### 3.3 The section builder

```
┌──────────────────────────────────────────────────────────┐
│  ← Disposition · 65 places       [Aperçu] [Enregistrer]  │
├─────────────────────────────────────┬────────────────────┤
│        ┌───────────────────┐        │  SECTIONS          │
│        │  🚪         ✈/🚌  │  avant │                    │
│        ├───────────────────┤        │  ① Première        │
│   ⭐   │ 1A 1B  │ 1C 1D 1E │        │    Rangées  [  3 ] │
│   ⭐   │ 2A 2B  │ 2C 2D 2E │        │    Config  [2 + 3] │
│   ⭐   │ 3A 3B  │ 3C 3D 3E │        │    Tarif   [× 2,5] │
│        ├───────────────────┤        │    Pas     [ 90cm] │
│        │ 4A 4B  │ 4C 4D 4E │        │            [ ⌫ ]   │
│        │  …     │    …     │        │                    │
│        │13A 13B │13C 13D13E│        │  ② Économique      │
│        ├───────────────────┤        │    Rangées  [ 10 ] │
│        │      🚻   🧳      │ arrière│    Config  [2 + 3] │
│        └───────────────────┘        │    Tarif   [× 1,0] │
│                                     │                    │
│  65 places · 15 première · 1 bloqué │  [ + Ajouter une   │
│                                     │      section ]     │
└─────────────────────────────────────┴────────────────────┘
```

Rules that make it usable:

- **Sections are added, reordered and deleted from the right rail.** Changing a row count or an abreast config regenerates that section's grid non-destructively — blocked seats and features on surviving cells are preserved.
- **Tap to cycle** a cell through seat → empty/aisle → blocked. Drag to paint a range. Long-press for the full type menu (exit row, lavatory, galley, door, luggage).
- **Numbering follows the physical labels on the vehicle.** Row+letter (`12A`) or sequential (`47`), per section, with a start offset — because the conductor or cabin crew reads the sticker on the seat, not our database.
- **Live capacity count per section and in total**, always visible. It is the number the operator actually cares about.
- **Aperçu voyageur** renders the exact widget the traveller sees, at phone width. Same code, so no surprises (ADR-0004).
- **Undo/redo.** Templates are versioned: editing a template used by vehicles with sold departures creates a **new version**, and existing departures keep the layout they were sold with — same principle as refund policies (ADR-0015).

### 3.4 What the traveller sees — a diagram, never a photo

The seat map is a **generated vector diagram** built from the layout: a coach or fuselage silhouette selected by mode and rough capacity, sections visually separated and labelled, doors, exits, lavatory and driver/cockpit marked. ~2 KB, renders instantly, identical in the app, the console preview and the PDF manifest.

No photograph of the vehicle is required anywhere. That was already true for buses under ADR-0009's asset budget; for aircraft it is simply obviously correct.

### 3.5 Storage

```json
{ "version": 3, "mode": "bus", "capacity": 65,
  "sections": [
    { "code": "VIP", "labelKey": "seat.class.vip", "rows": 3,  "abreast": "2+3",
      "numbering": {"style":"rowLetter","startRow":1}, "modifier": {"kind":"multiplier","value":2.5},
      "pitchCm": 90 },
    { "code": "STD", "labelKey": "seat.class.standard", "rows": 10, "abreast": "2+3",
      "numbering": {"style":"rowLetter","startRow":4}, "modifier": {"kind":"multiplier","value":1.0} }
  ],
  "features": [ {"type":"wc","row":13,"col":2}, {"type":"door","row":1,"col":0},
                {"type":"exit","row":7,"col":0} ],
  "blocked":  ["7C"] }
```

JSONB, versioned, immutable once a departure references it.

### 3.6 Price modifiers

A section carries a multiplier or a flat supplement, plus a label the traveller sees (*"Siège VIP — plus d'espace"*). Filtering and sorting in the app respect it. Deliberately simple: no yield management, no dynamic pricing in v1. Operators here price by route and by class, not by demand curve, and pretending otherwise would be building for a market that does not exist yet.

---

## 4. Routes

```
┌──────────────────────────────────────────────────────┐
│  Nouvelle ligne                                      │
│                                                      │
│  Départ      [ Brazzaville      ▾ ] [Gare Dougou  ▾] │
│  Arrivée     [ Pointe-Noire     ▾ ] [Gare Centrale▾] │
│                                                      │
│  Arrêts intermédiaires            [ + Ajouter ]      │
│   1. Kinkala        ~1 h 10   ☑ montée ☑ descente    │
│   2. Madingou       ~3 h 00   ☑ montée ☑ descente    │
│   3. Dolisie        ~5 h 15   ☑ montée ☑ descente    │
│   4. Nkayi          ~6 h 00   ☐ montée ☑ descente    │
│                                                      │
│  Distance   512 km      Durée type   7 h 30          │
│  ⓘ Distance et tracé calculés automatiquement.       │
└──────────────────────────────────────────────────────┘
```

- Cities and stations come from a shared catalogue we curate; an operator can request a new station (goes to the admin queue) or add a private boarding point.
- **Intermediate stops with separate boarding/alighting flags.** A stop that is drop-off only must not be sellable as an origin — a detail every naive model gets wrong and every operator notices immediately.
- **Segment selling is v1.1**, not v1: selling Brazzaville→Dolisie and Dolisie→Pointe-Noire on the same physical seat is real inventory value, and it is also a genuinely harder inventory problem. The data model supports it from day one (`departure_stops` with per-segment availability); the selling UI comes second.
- The route polyline is computed once and cached server-side, feeding the trip-tracking map (ADR-0014) without a per-viewer Directions call.

---

## 5. Schedules

### 5.1 Patterns

```
┌──────────────────────────────────────────────────────┐
│  Programmer des départs                              │
│                                                      │
│  Ligne        Brazzaville → Pointe-Noire             │
│  Heures       [06:00] [14:00]        [ + ]           │
│  Jours        L  M  M  J  V  S  D                    │
│               ●  ●  ●  ●  ●  ●  ○                    │
│  Véhicule déf.[ BZ-4471 ▾ ]  puis [ BZ-2210 ▾ ]      │
│  Tarif        [ 9 000 ] FCFA                         │
│  Valable du   [09/08/2026] au [ sans fin ]           │
│                                                      │
│  Aperçu : 12 départs cette semaine · 156 sur 90 j    │
│           [ Créer les départs ]                      │
└──────────────────────────────────────────────────────┘
```

Stored as an RRULE, materialised into concrete `departures` on a rolling 90-day horizon by a nightly worker. Materialised departures are independently editable — changing the pattern never rewrites a departure that already has bookings.

### 5.2 Exceptions

First-class, because they are frequent here:

- **Jours fériés** — pre-loaded Congolese public holidays, one toggle to skip or to add extra departures.
- **Saison des pluies** — suspend or extend duration on a route for a date range. Unpaved sections genuinely become impassable, and a schedule that pretends otherwise generates disruptions every week.
- **Renfort** — extra departures for a date range (rentrée scolaire, fêtes). One tap duplicates a pattern with a different coach.
- **Suppression ponctuelle** — cancel a single date. If it already has bookings, this routes into the disruption flow (`08-disruption.md`), never a silent delete.

### 5.3 Pricing

Base fare on the pattern, overridable per departure and per date range. Supported modifiers, all explicit and operator-set:

| Modifier | Example |
|---|---|
| Day of week | Friday +1 000 FCFA |
| Season | December +15% |
| Seat class | VIP ×1.5 (§3.4) |
| Child / student | −30%, ID checked at boarding |
| Group ≥ 10 | −10% |

No dynamic pricing, no surge, no personalised prices. Two travellers on the same departure see the same fare — a trust property worth more here than the incremental revenue.

---

## 6. From configuration to availability

```
Pattern ──nightly worker──▶ Departure ──▶ seats rows created from the
                                          layout template version
                                              │
                        traveller search ◀────┘
                        (Postgres → API → Drift cache → UI)
```

When a departure is created, one row per seat is written to the `seats` table (`02-architecture.md` §4) with state `available`. That table is the authoritative inventory that holds lock against (ADR-0012). Everything the traveller sees — the seat map, the "12 places" count, the sold-out badge — is derived from it.

**Publication rules:**

- A departure is sellable only when its vehicle is `active`, its compliance documents are valid, and the operator is `active`.
- Sales open 90 days ahead by default (operator-configurable) and close at a configurable cutoff before departure (default 30 min; online-only cutoffs can differ from agency cutoffs, because the agent is standing next to the bus).
- Changing the vehicle on a departure with bookings triggers **seat remapping** with explicit handling of displaced passengers (`08-disruption.md` §2.3).

---

## 7. Acceptance criteria

- An operator can add a vehicle with a seat layout and go live on a new route in **under 10 minutes**, on a tablet, unaided.
- A preset layout takes **under 90 seconds** to apply.
- The console seat-map preview is pixel-identical to the traveller app's seat map.
- A schedule pattern of 2 departures/day generates 90 days of departures in under 5 seconds.
- No configuration change can silently invalidate a sold ticket. Every such change routes into an explicit resolution flow.
- Layout templates and schedule patterns are versioned; sold departures keep the version they were sold with.
