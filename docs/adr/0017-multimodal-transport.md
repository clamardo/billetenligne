# ADR-0017 — One platform, multiple transport modes (bus first, air second)

**Status:** Accepted · **Date:** 2026-08-09 · **Amends:** ADR-0012, `06-fleet-and-routes.md`

## Context

Congolese domestic aviation has the same problem as the coach industry: local carriers (Trans Air Congo, Canadian Airways Congo and others on the Brazzaville–Pointe-Noire–Ouesso routes) sell largely manually — agency counters, phone calls, paper. The same 512 km corridor that the coaches run is also the busiest domestic air route in the country.

The question raised: is this one product with a transport-mode switch, or two products?

## Analysis — what actually differs

I looked at this as three separate questions, because the answer is different for each.

**The domain is ~85% identical.** Search a route on a date, choose a departure, choose a seat, hold it, pay, get a signed ticket, board with a scan, reschedule, refund, handle disruption. Rename `Coach` to `Vehicle` and `Departure` stops caring what shape it is. Money, policy, ledger, payment rails, tenancy, notifications, offline tickets, IRROPS — all mode-agnostic already. Aviation IRROPS is in fact where the model in ADR-0016 came *from*.

**The seat map is the same problem, and our current model is too weak for both.** `06-fleet-and-routes.md` §3 modelled a layout as one row-count plus one abreast configuration. That cannot express *"3 rows of 5 in first class, then 10 rows of 5 in economy"* — and it also cannot express the VIP-front/standard-rear coaches that already exist in Congo, or the 5-across rear bench I had to special-case. **Generalising to cabin sections fixes air and improves bus.** That is the tell that this is the right abstraction, not a stretch.

**The compliance and operations surface is where air is genuinely different**, and this is the part that must not be hand-waved:

| Concern | Bus | Air | Cost |
|---|---|---|---|
| Passenger name must match a government ID | Loose | **Strict** — name change = re-issue, not an edit | Real |
| Identity captured at booking | Name + phone | **ID/passport number, DOB, nationality** | Moderate |
| Baggage | Informal, cash at the door | **Allowance, excess fees, tags** | Real |
| Weight & balance | Not applicable | **Seat assignment can be restricted by trim** | Real |
| Departure control (DCS) | Our manifest is enough | Carrier may already run a DCS we must not fight | Variable |
| Check-in / boarding-pass | Scan the ticket | Distinct check-in step, cut-off ~45–60 min | Moderate |
| Exit-row eligibility rules | — | Regulated: age, capability, language | Small but mandatory |
| Infants on lap, unaccompanied minors, medical | Informal | Regulated special service requests | Moderate |
| Cancellation on carrier fault | Our platform floor | Local civil-aviation rules may exceed our floor | Legal review |
| Airline agreements | Commercial | Commercial **+ aviation regulator posture** | Slow |

None of that is architecturally hard. All of it is *work*, and the last two rows run on a regulator's clock, not ours.

## Decision

**One platform, one codebase, a first-class `TransportMode` in the domain. Bus ships first; air ships as a second mode behind a per-operator capability flag.**

### 1. `TransportMode` in the domain

```dart
enum TransportMode { bus, air }   // rail, ferry stay open — the Congo river is a real corridor
```

It is a property of the **operator's vehicle and route**, not a separate product. Search returns both when a route supports both, sorted honestly (a 45-minute flight and a 7-hour coach on the same corridor is a *genuinely useful comparison* — and it is a comparison no one in Congo can make today). That is a real product advantage, not a side effect.

### 2. Vehicle replaces Coach

`Coach` → `Vehicle { mode, identifier, model, layout, amenities, compliance[] }`. `identifier` is a plate for a bus, a registration for an aircraft. `model` drives the diagram, not a photo.

### 3. Seat layout becomes section-based — the core change

```dart
final class SeatLayout {
  final int version;
  final TransportMode mode;
  final List<CabinSection> sections;   // ordered front → back
  final List<LayoutFeature> features;  // door, wc, galley, exit, luggage, driver
}

final class CabinSection {
  final String code;            // "F" | "C" | "Y" | "VIP" | "STD"
  final String labelKey;        // i18n key, never raw prose
  final int rows;               // "3 rows of 5"
  final String abreast;         // "2+3" | "2+2" | "3+3" | "1+1"
  final SeatNumbering numbering; // rowLetter | sequential, with a start offset
  final PriceModifier? modifier; // ×1.5, or +15 000 XAF
  final int? pitchCm;           // legroom, displayed as comfort info
}
```

The operator's setup then reads exactly the way they described it out loud:

```
Section 1 · Première   3 rangées × 2+3   =  15 places   ×2.5
Section 2 · Économique 10 rangées × 2+3  =  50 places   ×1.0
                                    Total  65 places
```

This is strictly better for buses too: a VIP-front coach is two sections, and the 5-across rear bench is a one-row section. **The special cases disappear.**

### 4. Diagram, not photography

The traveller sees a **generated diagram** from the layout — fuselage or coach silhouette, sections separated, doors, exits, lavatory, driver or cockpit. No photo of the aircraft, no photo of the bus required. This was going to be true for buses anyway (ADR-0009 forbids heavy imagery); air just makes it obviously correct. The silhouette is a vector template selected by `mode` + rough capacity, and it costs ~2 KB.

### 5. Mode-specific behaviour lives behind narrow interfaces

Not `if (mode == air)` scattered through the codebase. Three seams, and only three:

- `BoardingPolicy` — cut-off time, check-in requirement, ID matching strictness
- `PassengerRequirements` — which fields are mandatory at booking
- `BaggagePolicy` — allowance and excess pricing (a no-op for bus in v1)

Everything else is shared. If a fourth seam appears, that is a signal to re-examine this ADR, not to add a fifth.

### 6. Sequencing

| Phase | Scope |
|---|---|
| **v1** | Bus only. `TransportMode` and `CabinSection` exist in the domain from day one — the model is built, the mode is not exposed. |
| **v1.5** | Section-based layouts shipped in the console for buses (VIP sections). Validates the abstraction against a real, low-risk case. |
| **v2** | Air behind a capability flag, with one design-partner carrier: ID capture, check-in step, baggage, exit-row rules, air-specific policy floor. |
| **later** | River ferry — Congo river transport is manual, high-volume, and structurally identical to bus. |

## Alternatives considered

| Option | Verdict |
|---|---|
| **Two separate products** | Duplicates inventory, payments, ledger, tenancy, IRROPS and the design system — the 85% — to isolate the 15%. For a small team this is the expensive mistake. Rejected. |
| **Bus only, ever** | Leaves an adjacent, equally under-served market to someone else, and forfeits the multimodal comparison that no one in Congo can make today. Rejected. |
| **Air first** | Higher revenue per booking, far higher regulatory and operational barrier, and a much longer sales cycle. Wrong first market. Rejected. |
| **Generic "transport mode" with no mode-specific logic** | Pretends the compliance deltas do not exist. Would ship an air product that cannot legally board a passenger. Rejected. |

## Consequences

**Good.** One domain, one design system, one payment stack, one operator console. The seat-layout model gets strictly better for buses. Search becomes multimodal, which is a differentiator we could not otherwise buy. An operator running both coaches and aircraft — which exists in this market — manages both in one console.

**Bad, and owned.** `Vehicle`/`Departure` carry a mode that most v1 code will ignore, which is a small ongoing tax. Air demands a genuine compliance work package (ID capture, check-in, baggage, exit rows, regulator review) that must be scoped as its own project, not slipped in as "one more mode".

**The trap to avoid:** letting air requirements leak into the bus experience. A Congolese coach passenger must never be asked for a passport number because the aircraft schema has the field. `PassengerRequirements` is what keeps that honest, and it is why it is one of the three seams rather than a nullable column.
