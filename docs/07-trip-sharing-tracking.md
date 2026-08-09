# BilletEnLigne — Trip Sharing & Live Tracking

**Status:** Draft v1 · **Date:** 2026-08-09 · **Implements:** ADR-0014

> The use case is specific and emotional: someone travels 512 km on the RN1, and a relative at the other end wants to know when to leave for the station. Today that costs phone credit and repeated calls. It should cost one WhatsApp message.

---

## 1. Position sources — never promise more than we have

Three tiers (ADR-0014). **The UI always states which tier is in play.** A confident dot on a map drawn from a timetable guess is worse than an honest progress bar.

| Tier | Source | Shown as |
|---|---|---|
| **1 · GPS** | Conductor device reports every 90 s while moving | Live marker + *"Position il y a 3 min"* |
| **2 · Checkpoint** | Conductor or dispatcher taps passage at a waypoint | *"Passé Dolisie à 10:42"* + interpolated progress |
| **3 · Schedule** | Nothing reported | Progress bar only, labelled **Estimation**, no map marker |

Tier 1 is opt-in per operator and per conductor. It is a **coach-level** signal, never passenger-level — we track a bus, not a person. That line is both an ethical commitment and the reason conductors accept it.

Data cost: ~40 KB for a 7-hour trip, batched, suppressed while stationary, queued through the outbox when coverage drops (ADR-0003). A dead zone produces a **gap**, then a backfill — never a fabricated position.

An operator that already runs telematics can feed tier 1 through a webhook instead of the conductor's phone. Supported, never required.

---

## 2. Sharing

`Partager mon trajet` on any ticket produces `https://blt.cg/t/<opaque-token>`, shared through WhatsApp — the default channel here — or SMS, or copied.

### What the follower sees

A **plain HTML/JS page, ~50 KB**, deliberately *not* Flutter Web (ADR-0004 §alternatives). The follower is on an unknown phone, on an unknown network, and is probably not a user. This is the one surface where a heavy client is indefensible.

```
┌────────────────────────────────────────┐
│  Aline voyage avec Océan du Nord       │
│                                        │
│  Brazzaville ──────●──────── Pointe-N. │
│  06:00          Dolisie         13:30  │
│                                        │
│  ●  En route · passé Dolisie à 10:42   │
│     Arrivée estimée 13:45  (+15 min)   │
│                                        │
│  ┌──────────────────────────────────┐ │
│  │         [ carte ]                │ │
│  └──────────────────────────────────┘ │
│                                        │
│  Prochaine mise à jour dans 1 min      │
└────────────────────────────────────────┘
```

**Never shown:** seat number, phone number, price paid, booking reference, or any other passenger on the coach.

**Token rules:** opaque, single-purpose, revocable from the ticket at any time, auto-expiring at arrival + 6 h. The traveller sees how many people have opened it — a small thing that makes sharing feel controlled rather than leaky.

Polling: 60 s while the trip is active, static before and after. No websockets — not worth the battery or the complexity.

---

## 3. Maps

| Surface | Treatment | Why |
|---|---|---|
| Traveller app — boarding point | **Static map image**, cached, ≤ 20 KB, + "Ouvrir dans Maps" handoff | A live map SDK costs several MB of binary and real memory on a 2 GB device (ADR-0009), for a feature used once per booking |
| Traveller app — my trip in progress | Progress bar + stop list, **no embedded map** | Same reason. The information is the *progress*, not the cartography |
| Follower web page | Google Maps JS, lazy-loaded, only at tier 1 or 2 | Desktop-or-mobile web, one-off view |
| Console — dispatcher fleet view | Full embedded live map | Desktop, wifi, operationally worth it |

Route polylines are computed **once per route** and cached server-side. A thousand followers of one departure cost one Directions call, not a thousand. Map keys are referrer/package-restricted with hard usage caps and billing alerts — an unbounded Maps bill is a classic and avoidable way to lose a month of margin.

---

## 4. During disruption

The shared link is the operator's cheapest communication channel. When a disruption is declared (`08-disruption.md`), the follower page switches to a status strip carrying the same information the passenger receives:

```
  ⚠ Panne signalée près de Dolisie · 09:12
     Un car de secours part à 11:30.
     Prochaine mise à jour à 10:00.
```

This is worth more to an operator than the tracking itself: it removes a large volume of anxious phone calls to the agency at exactly the moment the agency is busiest. **Commit to an update cadence and keep it** — a kept promise about *when* beats an accurate guess about *what*.

---

## 5. Explicitly out of scope for v1

No ETA machine learning, no traffic-adjusted predictions, no geofenced arrival notifications, no historical trip playback. A trustworthy *"passed Dolisie at 10:42"* beats a clever ETA that is wrong, and every one of these features degrades badly on tier-3 data.

---

## 6. Acceptance criteria

- Follower page first paint **under 2 s on 3G**, total weight ≤ 50 KB before the map lazy-loads.
- Tier is always stated; no position marker is ever rendered from tier-3 data.
- Revoking a link takes effect within 60 s.
- No shared page exposes seat, phone, price or booking reference — asserted by test.
- A 7-hour tracked trip costs the conductor's device ≤ 50 KB and ≤ 3% battery.
- Coverage gaps render as gaps, never as interpolated positions.
