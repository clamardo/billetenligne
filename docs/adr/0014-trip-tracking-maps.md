# ADR-0014 — Live trip tracking and shareable trip links

**Status:** Accepted · **Date:** 2026-08-09

## Context

Two related asks: a traveller should be able to **share their trip** with someone, and that person should be able to **follow the progress on a map**. In this market the use case is emotionally specific and very common: *a family member travelling 512 km on the RN1 between Brazzaville and Pointe-Noire, and a relative at the destination who wants to know when to leave for the station.* Today that is solved with phone credit and repeated calls.

The hard constraints: the coach's position must come from somewhere; the follower may not have our app; the RN1 has long stretches with no coverage; and neither the traveller nor the follower should pay much data for this.

## Decision

### Position source — degrade gracefully, never promise more than we have

Three tiers, and the UI always states which one is in play. Never draw a confident dot on a map from a guess.

| Tier | Source | Accuracy shown as |
|---|---|---|
| **1 — GPS** | Conductor's device in boarding mode reports position on a low-frequency schedule while the trip is active. | Live position, timestamped: *"Position il y a 3 min"* |
| **2 — Checkpoint** | Conductor (or dispatcher) confirms passage at defined waypoints — Dolisie, Nkayi, Madingou. One tap. | *"Passé Dolisie à 10:42"* + interpolated progress |
| **3 — Schedule** | Nothing reported. Progress is inferred from the timetable. | Explicitly labelled *"Estimation"*, in a muted style, with no position marker |

Tier 1 is opt-in per operator and per conductor, and it is a **coach-level** signal, never a passenger-level one. We do not track people; we track a bus that a person is on. That distinction is both an ethical line and the thing that makes it acceptable to conductors.

Reporting cadence: every **90 seconds** while moving, suppressed when stationary, batched and compressed. Roughly 40 KB for a 7-hour trip. Queued through the outbox (ADR-0003) when coverage drops, so a dead zone produces a gap and then a backfill, not a lie.

### Sharing — a web link, not an app install

`Partager mon trajet` produces `https://blt.cg/t/<opaque-token>`, shareable through WhatsApp (the default sharing channel here).

- Opens a **lightweight static web page** — plain HTML/JS, ~50 KB, **not Flutter Web**. The follower is on a random phone on a random network and may not be a user. This is the one surface where Flutter Web is the wrong tool (ADR-0004) and we say so explicitly.
- The page shows: route, operator, scheduled and estimated arrival, current progress, and the tier-appropriate map or progress bar. It **never** shows the passenger's seat, phone number, price paid, or the booking reference.
- The token is **opaque, revocable, and expires at arrival + 6 h**. The traveller can revoke it at any time from the ticket, and sees how many people have opened it.
- Polls at 60 s while the trip is active; static before and after. No websockets — not worth the battery or the complexity for this.

### Maps

**Google Maps** for the web follower page and for the static boarding-point thumbnails, as asked. But:

- In the **mobile app**, boarding points are a **static map image** (cached, ≤ 20 KB) with a "Ouvrir dans Maps" button that hands off to whatever map app the user has. We do not embed a live map SDK in the traveller app. `google_maps_flutter` costs several MB of binary and meaningful memory on a 2 GB device (ADR-0009), for a feature used once per booking. Handing off is better UX *and* cheaper.
- The **dispatcher's live fleet view** in the console does embed a real map — desktop, wifi, worth it.
- Map API keys are restricted by referrer/package and usage-capped with billing alerts. Maps billing is a classic way to wake up to a large invoice.
- The route polyline is computed **once per route** and cached server-side, not requested per viewer. A thousand followers of the same departure cost one Directions call, not a thousand.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Dedicated GPS trackers on coaches** | Most reliable, and where mature operators end up. Hardware cost, installation, SIM per coach. **Support it as a tier-1 source via a webhook** so an operator who already has telematics can plug it in — but do not require it. |
| **Passenger-device crowdsourced position** | Free and accurate. Rejected: tracking passengers is a privacy line we will not cross, and battery cost falls on the poorest users. |
| **Live map embedded in the traveller app** | Rejected on size and memory (ADR-0009). |
| **Mapbox / OpenStreetMap** | Cheaper at scale, weaker Central Africa road data. Google's coverage of the RN1 corridor is better. Revisit if maps billing becomes material. |

## Consequences

Tracking quality varies by operator, and that is visible to users — an operator with conductor GPS enabled shows "Suivi en direct" in search results, which becomes a competitive differentiator and therefore a reason to enable it. Good.

We must resist scope creep here: no ETA machine learning, no traffic prediction, no geofenced arrival notifications in v1. A trustworthy "passed Dolisie at 10:42" beats a clever ETA that is wrong.
