# BilletEnLigne — Disruption Management (IRROPS)

**Status:** Draft v1 · **Date:** 2026-08-09
**Implements:** ADR-0016 · **Related:** ADR-0012 (inventory), ADR-0015 (policy floor), ADR-0014 (tracking)

> Design premise: on Congo's road network, disruption is **normal traffic, not an error path**. This subsystem is built for the Tuesday-morning breakdown, not for the once-a-year incident. It is entirely operator-self-service (ADR-0016).

---

## 1. Event taxonomy

The dispatcher declares one of six things. Everything downstream is derived.

| Event | Trigger | Typical cause here |
|---|---|---|
| **DELAY** | Departure will leave / arrive late | Checkpoint, loading, late inbound coach |
| **CANCELLATION** | Departure will not operate | No coach, no driver, road closed |
| **BREAKDOWN_EN_ROUTE** | Coach failed mid-route, passengers on board | Mechanical — the most common and the hardest |
| **EQUIPMENT_SWAP** | Different coach assigned | 60-seater → 45-seater, may displace passengers |
| **DIVERSION** | Route changed mid-trip | Washed-out section, bridge closed, flooding |
| **ROUTE_SUSPENSION** | A whole route is unserviceable for a period | Rainy season, security |

Each event carries: cause code, location (auto-filled from the last known position, ADR-0014), estimated resolution, and a free-text note that goes to passengers in their own language via templated translation.

---

## 2. The dispatcher flow — three taps to a plan

Designed for a phone, one-handed, at the roadside, on 2G, possibly in the rain. This is the constraint that shapes every screen below.

### 2.1 Declare

The console home shows today's departures. Long-press or swipe any departure → **Signaler un incident**.

```
┌────────────────────────────────────────┐
│  ← BZV → PNR · 06:00 · Coach BZ-4471   │
│     42 passagers à bord                │
├────────────────────────────────────────┤
│  Que s'est-il passé ?                  │
│                                        │
│  ┌──────────────┐  ┌──────────────┐   │
│  │      ⏱       │  │      ⚠       │   │
│  │   RETARD     │  │   PANNE      │   │
│  │              │  │  EN ROUTE    │   │
│  └──────────────┘  └──────────────┘   │
│  ┌──────────────┐  ┌──────────────┐   │
│  │      ✕       │  │      ⇄       │   │
│  │  ANNULATION  │  │ CHANGEMENT   │   │
│  │              │  │  DE CAR      │   │
│  └──────────────┘  └──────────────┘   │
│                                        │
│  ⓘ Position détectée : km 180, RN1     │
│    près de Dolisie · il y a 4 min      │
└────────────────────────────────────────┘
```

Four large targets. No form. The position is pre-filled from tracking and editable.

### 2.2 The system generates options

Within seconds the dispatcher sees a **ranked re-accommodation plan**, computed server-side:

```
┌────────────────────────────────────────┐
│  PANNE · BZV→PNR 06:00 · 42 passagers  │
│  Position : km 180 (Dolisie)           │
├────────────────────────────────────────┤
│  OPTIONS DE RÉACHEMINEMENT             │
│                                        │
│  ① Car de secours BZ-2210     ★ conseil│
│     Départ Dolisie 11:30 · 55 places   │
│     Retard estimé : +2 h 40            │
│     Couvre 42 / 42 passagers           │
│     Coût : 0 FCFA                      │
│     [ Appliquer ]                      │
│                                        │
│  ② Vos départs suivants                │
│     14:00 BZV→PNR · 18 places libres   │
│     Couvre 18 / 42 · retard +8 h       │
│                                        │
│  ③ Protection — Trans Bony 12:00       │
│     31 places · accord actif           │
│     Coût : 9 000 FCFA × 31 = 279 000   │
│     [ Demander ]                       │
│                                        │
│  ④ Annuler et rembourser (42)          │
│     Coût : 378 000 FCFA                │
│                                        │
│  ⑤ Laisser les passagers choisir       │
│     Proposer ①②③ dans l'application    │
│     [ Envoyer aux passagers ]          │
└────────────────────────────────────────┘
```

The ranking function is deliberately simple and explainable — a dispatcher must be able to predict it:

```
score = w₁·(passengers covered)
      − w₂·(added delay minutes)
      − w₃·(cost to operator)
      − w₄·(passengers requiring a second move)
```

Weights are operator-configurable (a premium operator weights delay; a budget operator weights cost). **The recommendation is never applied automatically** — a human presses Appliquer. Automation that moves 42 people without a human deciding is how you strand someone at 02:00.

### 2.3 Options in detail

**① Rescue coach (transboarding).** The operator's own spare or a coach pulled from another duty. The dispatcher assigns it; the system rewrites the departure's coach, keeps every booking intact, **remaps seats** (a 2+2 seat 14A does not exist on a 2+3 layout — the remapper preserves relative position and window/aisle preference where possible, and flags any passenger it cannot honour), and notifies everyone with the new pickup point and time. Tickets stay valid; the QR does not change, because the booking did not.

**② Own next departures.** The re-accommodation engine holds seats across the operator's own future departures in one atomic transaction (ADR-0012). Partial coverage is normal and is shown honestly — "18 / 42" — because a dispatcher combining ② and ③ to cover everyone is the realistic outcome.

**③ Protection on another operator.** Requires a standing **inter-operator agreement** (§5). One tap sends a request; the receiving operator's console shows an inbound protection request with an accept/decline and a live seat count. On accept, seats are held immediately, new tickets are issued under the receiving operator, and the settlement runs through our ledger — neither party has to trust the other's arithmetic. This is what already happens informally at Congolese gares, in cash, with arguments. We are formalising an existing practice, not inventing one.

**④ Cancel and refund.** Full refund to source, no fee, platform floor (ADR-0015). Always available, never the default.

**⑤ Let passengers choose.** Discussed in §3. Often the best answer, and the one most systems never offer.

### 2.4 Apply — the rebooking wave

One confirmation, then the system executes atomically:

- Holds every replacement seat before releasing anything. **Never release first.** If the wave cannot be fully applied it rolls back entirely and reports why.
- Reissues tickets (new signature where the departure changed, ADR-0007).
- Marks each affected booking `involuntary_change` — which permanently exempts it from fees and fare differences and is visible on the traveller's ticket history as *"Modifié par l'opérateur"*.
- Fires the notification cascade (§4).
- Writes an immutable disruption record: who declared, what was chosen, when, who was moved where. This is the operator's evidence in any later dispute, and it is why they will trust the tool.

Progress is shown live — *"38 / 42 réacheminés · 4 en attente de choix"* — because a wave over 42 bookings with a flaky connection is not instant.

### 2.5 Offline

Everything above works with **no connectivity**. The event is declared locally, the plan is computed against the last-synced inventory, and the wave queues in the outbox (ADR-0003). On reconnect the server re-validates; any seat lost in the interim surfaces as a small exception list rather than a failed wave. The dispatcher's screen is explicit about which state it is in — *"Hors ligne · 42 passagers seront notifiés à la reconnexion"*.

---

## 3. The traveller experience

### 3.1 Notification

Push **and** SMS, immediately, in the traveller's language. SMS matters here more than anywhere — the passenger may be at the roadside with a dying battery.

> **Océan du Nord — panne signalée**
> Votre départ BZV→PNR de 06:00 est immobilisé près de Dolisie.
> Un car de secours part à 11:30. Votre place est déjà réservée, siège 14A.
> Aucun frais. Voir vos options : blt.cg/d/7QK4M2

The message states **what already happened for them** before offering choices. A passenger whose seat is already secured is a calm passenger.

### 3.2 Self-service choice — the option most systems never build

When the dispatcher picks ⑤, or whenever the auto-assignment is not the passenger's best outcome, the app presents the actual choice:

```
┌────────────────────────────────────────┐
│  ⚠ Votre voyage est perturbé           │
│                                        │
│  BZV → PNR · sam. 15 août · 06:00      │
│  Panne près de Dolisie                 │
│                                        │
│  Choisissez — sans frais :             │
│                                        │
│  ┌──────────────────────────────────┐ │
│  │ ✓ Car de secours       ATTRIBUÉ  │ │
│  │   Aujourd'hui 11:30 · siège 14A  │ │
│  │   Arrivée estimée 18:10 (+2h40)  │ │
│  │              [ Je garde ]        │ │
│  └──────────────────────────────────┘ │
│  ┌──────────────────────────────────┐ │
│  │   Départ de 14:00                │ │
│  │   Arrivée 21:30 · 18 places      │ │
│  │              [ Choisir ]         │ │
│  └──────────────────────────────────┘ │
│  ┌──────────────────────────────────┐ │
│  │   Trans Bony · 12:00             │ │
│  │   Arrivée 19:00 · autre compagnie│ │
│  │              [ Choisir ]         │ │
│  └──────────────────────────────────┘ │
│  ┌──────────────────────────────────┐ │
│  │   Remboursement intégral         │ │
│  │   9 300 FCFA sur Airtel Money    │ │
│  │              [ Choisir ]         │ │
│  └──────────────────────────────────┘ │
│                                        │
│  Sans réponse avant 10:30, nous vous   │
│  gardons sur le car de secours.        │
└────────────────────────────────────────┘
```

Design rules for this screen:

- **A default is always pre-assigned.** The passenger is never left with nothing while they decide. Choice is an upgrade on a safe state, not a prerequisite for one.
- **Every option shows the arrival time**, because that is what the passenger actually cares about — not the departure time.
- **"Sans frais" is stated once, prominently.** The first question in every passenger's mind is whether this will cost them.
- **A deadline with a stated fallback.** Ambiguity is the enemy at 04:00.
- **Full refund is always present**, last, never hidden behind a support conversation.
- Choosing is one tap and reflows the seat instantly; the released seat returns to the pool for other affected passengers, which is why letting passengers choose often produces better coverage than any dispatcher plan.

### 3.3 During a breakdown, the trip page becomes the information channel

The shared trip link (ADR-0014) and the ticket both switch to a live status strip: what happened, where, what is being done, next update time. A family member following the link sees it too — which removes a large volume of phone calls to the agency, and is a benefit the operator feels immediately.

**Commit to an update cadence and keep it.** *"Prochaine mise à jour à 09:00"* is worth more than an accurate ETA, because it is a promise the operator can keep.

---

## 4. Notification cascade

| Audience | Channel | Timing |
|---|---|---|
| Passengers on the affected departure | SMS + push | Immediately on declaration |
| Passengers, resolution | SMS + push | On wave applied |
| Followers of shared trip links | Web page auto-refresh | Immediately |
| Receiving operator (protection) | Console alert + SMS to dispatcher | Immediately |
| Operator's own agencies | Console banner | Immediately — walk-ins will ask |
| Conductor of the replacement coach | Push, new manifest | On wave applied |
| BilletEnLigne | Dashboard only, **no action required** | Logged |

Quiet hours never apply to disruption. A 03:00 SMS about a cancelled 05:00 departure is exactly what the passenger wants.

---

## 5. Inter-operator protection agreements

Configured once, in the console, between two operators. No BilletEnLigne involvement per event.

```
Accord de protection — Océan du Nord ⇄ Trans Bony
  Routes couvertes    BZV↔PNR, BZV↔Dolisie
  Réciproque          oui
  Tarif de refacturation   tarif public − 15%
  Plafond             40 places / mois
  Acceptation         manuelle (ou automatique si places > 10)
  Règlement           via BilletEnLigne, mensuel
```

Settlement flows through our ledger as an inter-operator payable, netted into the normal payout run (`04-payments.md` §6.2). We take **no commission on protection movements** — it is a cost-recovery transfer between operators, not a sale, and taxing it would kill the behaviour we want to encourage.

For operators with no agreement, the console still offers **open protection**: broadcast a seat request to any operator on the route who has opted in to receive them. First to accept wins. This is the digital version of a dispatcher walking down the gare asking who has room.

---

## 6. Prevention and quality

Disruption data is one of the more valuable by-products of this system, and it feeds back into product.

- **Operator reliability score** — on-time rate, disruption rate, resolution speed, share of disruptions resolved without refund. Surfaced in search results as a simple, honest signal (*"92% à l'heure"*), which turns reliability into a competitive advantage instead of a hidden cost.
- **Coach reliability** — repeated breakdowns on one vehicle appear in the fleet module as a maintenance prompt. Operators find this genuinely useful and it costs us nothing to compute.
- **Route risk** — seasonal disruption patterns per route, so operators can pad schedules in the rainy season instead of failing weekly.
- **Chronic disruption** (> 15% of departures over 30 days) triggers a review with the operator. Commercial conversation, not an automated penalty.

---

## 7. Acceptance criteria

- A dispatcher can declare a breakdown and apply a full re-accommodation plan for 42 passengers in **under 90 seconds**, on a phone, on 2G.
- The same flow completes **fully offline** and syncs without passenger-visible inconsistency.
- No disruption path requires any BilletEnLigne action. Verified by a drill: our whole team unreachable, operator resolves unaided.
- Involuntary changes **never** produce a fee or a fare difference. Property-tested.
- A rebooking wave is atomic: it fully applies or fully rolls back.
- Unresolved disruption at departure + 2 h auto-refunds every affected passenger.
- Every passenger has a valid ticket or a completed refund within 4 h of any disruption. **No passenger is ever left in an undefined state** — this is the invariant the whole subsystem exists to protect.
