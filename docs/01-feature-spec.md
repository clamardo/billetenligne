# BilletEnLigne — Feature Specification (v1)

**Status:** Draft v1 · **Date:** 2026-08-09
**Companion docs:** `00-product-brief.md` (why) · `02-architecture.md` (how) · `04-payments.md` · `05-design-system.md`

Notation: **[P0]** must ship for launch · **[P1]** ships within 90 days · **[P2]** later.

---

## 1. Surfaces

| # | Surface | Platform | Primary user |
|---|---|---|---|
| S1 | Traveller app | Flutter, iOS + Android | Aline |
| S2 | Boarding scanner | **Standalone app** (ADR-0022), operator-owned device | Pascal |
| S3 | Operator console | Flutter Web | Jean-Marc + staff |
| S4 | Admin back office | Flutter Web | BilletEnLigne staff |
| S5 | Notifications | SMS + push | everyone |

---

## 2. Onboarding (S1) **[P0]**

Design intent: **the user must see value before we ask for anything.** No account wall, no permission wall, no carousel the user swipes past resentfully.

### 2.1 First launch

1. **Language gate** — a single full-screen choice, `Français` / `English`, big targets, flags plus the word. Persisted immediately. Reachable later in settings. This is screen zero because everything after it is unreadable if we guess wrong.
2. **Three value cards, swipeable, skippable** — each one sentence and one vector illustration:
   - *"Réservez votre place en 2 minutes"* — book from your phone
   - *"Payez avec Airtel Money ou MTN MoMo"* — the payment reassurance, shown early and deliberately
   - *"Votre billet fonctionne sans réseau"* — the offline promise
   A persistent **Passer / Skip** in the top-right. No forced sequence.
3. **Straight into search.** Not into sign-up.

### 2.2 Progressive account creation

Auth is requested at the **hold seat** step, never before (ADR-0013). By then the user has picked a route, a departure and a seat — they have sunk enough intent to give a phone number.

Flow: phone number (country code prefilled `+242`, operator auto-detected and shown as a small chip: *"Airtel détecté"*) → OTP auto-filled via SMS Retriever → done. Name is collected **after** payment, on the ticket screen, because it is needed for the manifest, not for the transaction.

### 2.3 Onboarding QR **[P0]**

The brief asks for a QR in onboarding. Two distinct uses, both real:

**(a) Install/referral QR** — printed on agency counters, coach windows, posters. Encodes a deep link `https://blt.cg/i/<campaign>` that opens the store or, if installed, the app on a pre-filled route. Carries the campaign and the referring operator/agency so we can attribute installs and pay agency staff a small referral bonus for the ones they install. Generated per agency from the console.

**(b) Ticket claim QR** — when a station agent sells for cash, the console shows a QR. The customer scans it with the app and the ticket lands in their wallet. This is the bridge that converts cash customers into app users, and it is the single highest-leverage growth mechanic we have. Also handles the diaspora case: Marie buys, her mother scans.

Both flows degrade to a short human-readable code (`BLT-7QK4M2`) typed into "J'ai un code" for people whose camera is broken or who are reading it over the phone.

### 2.4 Acceptance criteria

- Language choice persists across reinstall via platform preferences where available.
- Skipping onboarding never blocks any feature.
- Time from cold install to first search ≤ 20 s on the reference device.
- No permission is requested during onboarding. Camera is requested at the moment of the first scan, with an inline explanation.

---

## 3. Search & discovery (S1) **[P0]**

### 3.1 Home

Above the fold, nothing else competes:

- **From / To** — two large fields. From is pre-filled with the last used or nearest known city (no GPS permission; inferred from previous bookings, defaulting to Brazzaville).
- **A swap button** between them, because the return trip is the most common next search.
- **Date** — a horizontal strip of the next 14 days plus a calendar affordance. Today and tomorrow are the overwhelming majority of searches; make them one tap.
- **Passengers** — defaults to 1.
- **Rechercher** — full width, unmissable.

Below: **Mes billets** (upcoming ticket card, if any) and **recent searches** as one-tap chips. A returning user should be able to rebook in two taps.

### 3.2 Results

A vertical list of departures. Each row carries, in one glance:

`06:00 → 13:30` · `7 h 30` · **Océan du Nord** · `9 000 FCFA` · `12 places` · ★ 4.2

- Sort: departure time (default) / price / duration.
- Filter: operator, time-of-day band, amenities (AC, USB, wifi), price ceiling.
- **Low-availability urgency is honest** — "3 places restantes" appears only when it is true. No fake scarcity, ever. In a market where trust is the barrier, a single caught lie costs more than the conversions it buys.
- **Sold-out departures stay visible**, greyed, with an "Alertez-moi" option **[P1]**. Hiding them makes the list look thin and makes users think we have no supply.
- Empty state offers the adjacent dates that *do* have seats, rather than a shrug.

### 3.3 Offline behaviour

Cached results render instantly with a subtle staleness chip (*"Mis à jour il y a 12 min"*). Prices and seat counts are re-validated at hold time, and the UI says so in small print rather than pretending the cache is authoritative.

---

## 4. Departure detail & seat selection (S1) **[P0]**

### 4.1 Detail

Operator identity, coach type and photo (bundled/cached, ≤ 20 KB), amenities, boarding point with a static map thumbnail, cancellation and reschedule policy in **plain French**, not legalese, and the full price breakdown *before* the user commits:

```
Tarif                    9 000 FCFA
Frais de service           300 FCFA
─────────────────────────────────
Total                    9 300 FCFA
```

No surprises later in the funnel. The service fee is disclosed at the first screen that shows a total, not at checkout.

### 4.2 Seat map

- Realistic coach layout: 2+2 or 2+3, aisle, driver position, doors, and row numbers matching the physical labels on the coach.
- Seat states: available · occupied · selected · held-by-another (live) · unavailable (broken/reserved).
- Legend always visible. Colour is never the only signal — occupied seats carry a pattern and a shape difference, for colour-blind users and for cheap screens with poor colour reproduction.
- Pinch-zoom, and a minimum 44 dp effective target even at default zoom.
- **Selecting is optimistic in the UI, authoritative on the server.** Tapping marks it locally and fires the hold request; a rejection animates the seat back to occupied with a brief explanation.
- **Unnumbered mode:** operators without a seat map get a quantity stepper instead. The rest of the funnel is identical (ADR-0012).

### 4.3 Passenger details

One passenger form per seat. Name (required, goes on the manifest), phone (defaults to the account's, editable — this is the "buy for someone else" hook), optional ID number where the operator requires it.

Previously used passengers are offered as one-tap chips. Families rebook the same people constantly.

---

## 5. The hold **[P0]**

On confirming seats, the server creates a **15-minute hold** (ADR-0012). From here the UI shows a **live countdown** in a persistent bar. At 2:00 remaining it turns amber and, if the app is backgrounded, fires a local notification.

If the hold expires: seats release, the user returns to the seat map with a clear, non-blaming message and their selection pre-attempted. No dead ends.

---

## 6. Payment (S1) **[P0]** — the centrepiece

Detailed rails, state machines and failure taxonomy: `04-payments.md`. This section is the **experience**.

### 6.1 Method selection — mobile money is the default

The screen opens with **Mobile Money already selected and the user's own operator pre-chosen** from their MSISDN prefix. Card and cash are secondary tabs, visually quieter.

```
┌──────────────────────────────────────┐
│  Mobile Money   │   Carte   │  Espèces│   ← MoMo tab active by default
├──────────────────────────────────────┤
│  ◉  Airtel Money     +242 06 12 34 56│   ← preselected, prefilled
│  ○  MTN MoMo                          │
├──────────────────────────────────────┤
│  Total                  9 300 FCFA    │
│  ⏱ Place réservée · 12:47             │
│         [  Payer 9 300 FCFA  ]        │
└──────────────────────────────────────┘
```

The number is prefilled from the account and editable — people pay from a family member's wallet routinely, and blocking that would cost real transactions.

### 6.2 The waiting screen — the most important screen in the app

This is where trust is won or lost. When the user taps Pay, they will be pulled out to a USSD/STK prompt on their handset. Our screen must survive that context switch and tell an unambiguous story.

```
        ┌─────────────────────┐
        │   [ Airtel Money ]  │
        │                     │
        │   Vérifiez votre    │
        │      téléphone      │
        │                     │
        │  Entrez votre code  │
        │   secret Airtel     │
        │   Money pour        │
        │   confirmer         │
        │                     │
        │   ⏱  4:32 restant   │
        │                     │
        │  ○ ─ ○ ─ ○          │
        │  Envoyé · En attente│
        │                     │
        │  Aucune invite ?    │
        │  Composez *128#     │
        │                     │
        │  [ J'ai un problème]│
        └─────────────────────┘
```

Details that matter:

- **A three-step progress indicator**: *Demande envoyée → En attente de votre confirmation → Paiement confirmé*. Users need to know the machine is doing something.
- **The USSD fallback string is shown** (`*128#` etc., per operator, from config). Prompts genuinely fail to arrive; give the user the manual path rather than a spinner.
- **The screen survives backgrounding.** The user *will* leave the app to answer the prompt. On return, state is restored from the server, not from memory.
- **No cancel button for the first 30 seconds** — early cancels create the ambiguous "did it go through?" state that generates support load. After 30 s, cancel is available and explicitly explains that any debited amount will be refunded.
- **Never a bare spinner.** Every second on this screen has a sentence attached.

### 6.3 Success

Immediate, unmistakable. Ticket appears with the QR. **An SMS receipt is sent independently of the app** — in this market SMS is the trust anchor, and the user who is not sure whether the app "really" worked will believe the SMS. Budget for it (ADR-0013).

### 6.4 Pending / indeterminate — the state everyone forgets

If we cannot confirm within the window, we do **not** show a failure and we do **not** show success:

> **Paiement en cours de vérification**
> Nous confirmons votre paiement auprès d'Airtel. Votre place est réservée. Vous recevrez un SMS dès la confirmation — généralement en moins de 5 minutes.
> `Référence : BEL-7QK4M2`

The hold is extended, the intent enters the reconciliation queue (ADR-0005), and resolution arrives by SMS and push whichever way it goes. If it fails, the message says plainly that no money was taken, or that a refund is on its way and by when.

### 6.5 Failure taxonomy — every case gets its own copy

Never "Payment failed. Try again."

| Cause | Message (fr) | Recovery offered |
|---|---|---|
| Insufficient funds | *Solde insuffisant sur votre compte Airtel Money.* | Pay with another number / another method / rechargez |
| Wrong PIN | *Code secret incorrect.* | Retry, same intent |
| Timeout, no response | *Vous n'avez pas répondu à temps.* | Resend prompt |
| User declined | *Paiement annulé.* | Back to method selection |
| Operator/PSP down | *Airtel Money est momentanément indisponible.* | Suggest another rail, keep the hold |
| Wrong operator for number | *Ce numéro n'est pas un compte MTN MoMo.* | Auto-switch to the detected operator |
| Network lost mid-payment | *Connexion perdue. Nous vérifions votre paiement.* | Auto-poll on reconnect — never re-send |

### 6.6 Card **[P0]** and cash **[P0]**

Card: standard PSP-hosted 3-D Secure. Deliberately secondary. We never touch a PAN.

Cash: the user reserves in-app and gets a **payment code + a 4-hour deadline**; they pay at any agency of that operator, the agent enters the code in the console, and the ticket issues. Bridges the unbanked and drives agency footfall — which the operators like.

---

## 7. Ticket & wallet (S1) **[P0]**

### 7.1 Ticket

A visually distinct object — a real *thing*, not a receipt. Ticket-stub silhouette with a perforation notch and a colour band carrying the operator's identity.

Carries: QR (ADR-0007), **the 6-digit rotating code beneath it**, booking reference, passenger, route with departure/arrival times, seat, operator, coach, boarding point and gate, and a plain-language boarding instruction.

Behaviours:
- **Screen brightness auto-maxes** when the ticket is open. Scanning a dim screen in sunlight is a real failure mode.
- Works in airplane mode, always. Explicitly tested that way.
- `Ajouter au calendrier`, `Partager`, `Imprimer`.
- A live countdown to departure, and a boarding-point reminder push 2 hours before **[P0]**.

### 7.2 Printable version **[P0]**

Generated **on-device** so it works offline. Two formats:

- **A4 / Letter PDF** — full ticket, QR at ≥ 3 cm, conditions on the reverse, in the user's language.
- **80 mm thermal** — for agency printers.

Rendered client-side and handed to the OS print/share sheet. No server round trip, no printer drivers. A user with a working PDF in their downloads folder is a user who can travel when their phone dies.

### 7.3 Wallet

Upcoming and past tabs. Upcoming sorted by departure, the next one expanded as a card. Past tickets are the fastest rebooking path — **Réserver à nouveau** on any past trip re-runs the search with the same route.

---

## 8. Modify & cancel (S1) **[P0]**

The brief calls out "modify departure" explicitly, and it is where most ticketing apps are worst.

### 8.1 Reschedule

`Modifier` on a ticket → the same search UI, scoped to the same route and operator, with **the fare difference and any fee shown live on every result row** before selection:

```
06:00  Océan du Nord   9 000 FCFA   Gratuit        ← same price, inside free window
14:00  Océan du Nord  10 500 FCFA   +1 500 FCFA
```

Policy (ADR-0012, D-08): ≥ 24 h free · 24 h–2 h fee (default 10%, operator-configurable) · < 2 h not permitted. The rule is evaluated by the **shared domain package** so the quote the user sees is computed by the same code the server charges with (ADR-0004).

Mechanics: new seat is held before the old one is released. **Never release the old seat first** — a failed reschedule must leave the user exactly where they started. Fare difference is charged on the same rail as the original where possible; a downward difference is refunded to the source wallet.

Seat-only change on the same departure is a separate, cheaper flow with no fee.

### 8.2 Cancel

Refund quote shown before confirmation, with a plain breakdown of what is retained and why. Refund goes to the source of payment — mobile money disbursement is a distinct API and often slower than collection, so the UI commits to a **window** ("sous 72 heures"), not an instant, and we notify on actual arrival.

Cancellation by the *operator* (breakdown, cancelled departure) is a different path entirely: full automatic refund, no fee, proactive SMS + push, and a one-tap offer of the nearest alternative departure — held for the user for 30 minutes at no charge.

---

## 9. Boarding scanner (S2) **[P0]**

A **separate application** on an operator-owned device, unlocked by a dispatcher-issued pairing code (ADR-0013) — not a mode inside the traveller app. The reasoning, and the reversal of the original decision, is ADR-0022. Designed for sunlight, gloves, noise and no network.

- **Departure picker** → downloads the manifest (a few KB) and pins it.
- **Scanner:** camera opens immediately, torch toggle prominent, large capture area. Verdict in **under 2 seconds**, offline.
  - **VALIDE** — full-screen green, passenger name, seat, a short vibration.
  - **DÉJÀ EMBARQUÉ** — full-screen red, first-scan time and device.
  - **MAUVAIS DÉPART** — full-screen amber, shows which departure the ticket is actually for. This is the most common real error and it deserves its own explicit verdict rather than a generic reject.
  - **INVALIDE** — signature failure.
  - **CODE PÉRIMÉ** — signature valid but the rotating code is stale: likely a screenshot. Amber, not red — prompts the conductor to ask the passenger to refresh, rather than accusing them.
- Verdicts are readable at arm's length in direct sun: full-screen colour, one word, large type. The conductor should not have to read a sentence.
- **Manual boarding** by booking reference or passenger name against the offline manifest, for dead phones. Recorded as manual.
- **Live count** — `47 / 60 embarqués` — always on screen, and a pre-departure summary listing no-shows.
- Everything queues to the outbox and syncs when a network appears.

---

## 10. Operator console (S3) **[P0]**

Per-tenant, RLS-enforced (ADR-0011). Full lifecycle in `03-operator-lifecycle.md`.

| Module | Contents |
|---|---|
| **Tableau de bord** | Today's departures, load factor, revenue, alerts (under-filled departure, unassigned coach, stuck payment). |
| **Routes & horaires** | Routes, stops, recurring schedule patterns with exceptions (holidays, rainy-season closures on unpaved routes — a real operational fact here). Bulk edit. |
| **Flotte** | Coaches, seat map templates, amenities, maintenance status. A coach out of service surfaces affected departures with a displaced-passenger resolution flow (ADR-0012). |
| **Tarification** | Base fare per route, per-departure overrides, day-of-week and season rules, reschedule/cancel policy. |
| **Départs** | Per-departure manifest, assign coach/driver/conductor, delay, cancel with automatic passenger notification. |
| **Guichet** | Cash sale — search, seat, passenger, take cash, print, and show the claim QR (§2.3b). Free of commission by design (D-04). |
| **Réservations** | Search, reschedule, cancel, refund within policy, resend ticket. |
| **Personnel** | Invite staff, assign roles, issue conductor pairing codes. |
| **Finances** | Sales, commission, payouts, statements, CSV export. Reconciliation against actual settlement. |

The console must be usable on a tablet — Jean-Marc is often in the yard, not at a desk.

---

## 11. Admin back office (S4) **[P0]**

Cross-tenant, IP-restricted, 2FA-mandatory (ADR-0011).

| Module | Contents |
|---|---|
| **Opérateurs** | Application review queue, KYB documents, approve / reject / suspend / offboard. Full lifecycle in `03-operator-lifecycle.md`. |
| **Conformité** | Document expiry tracking (licence, insurance — these lapse and we must not sell seats on an uninsured coach), sanctions/PEP screening on owners, audit log. |
| **Paiements** | Every intent, filterable by state. **The `indeterminate` queue is the front page** — one-click PSP re-query, manual resolve with mandatory reason, and a full ledger view. |
| **Finance** | Payout runs, per-operator statements, commission reconciliation, refund approvals above threshold, float monitoring per rail. |
| **Support** | Find a booking by phone/ref/name, see the full timeline, resend ticket, reschedule, refund up to cap, **impersonate read-only** (audited, time-boxed) to see exactly what the traveller sees. |
| **Catalogue** | Cities, stations, route codes, PSP config, feature flags, the server-driven payment method list (ADR-0006). |
| **Fraude** | Velocity rules, repeated-failure patterns, duplicate-device signals, screenshot-code rejections by operator. |
| **Analytique** | Funnel, payment success by rail and by hour, load factor by route, cohort retention. |

---

## 12. Notifications (S5) **[P0]**

SMS is the trust channel; push is the convenience channel. Anything involving money goes out on **both**.

| Event | SMS | Push |
|---|---|---|
| OTP | ✅ | — |
| Payment confirmed + ticket | ✅ | ✅ |
| Payment pending > 5 min | ✅ | ✅ |
| Payment failed | ✅ | ✅ |
| Refund issued / arrived | ✅ | ✅ |
| Departure reminder (T-2 h) | — | ✅ |
| Departure delayed / cancelled | ✅ | ✅ |
| Boarding point changed | ✅ | ✅ |
| Ticket claim (agent sale) | ✅ | — |

All templates bilingual, sent in the recipient's chosen language, and SMS kept under 160 characters where possible because a multipart SMS costs multiples. Quiet hours 22:00–06:00 for everything except money and departure-critical events.

---

## 13. Cross-cutting acceptance criteria **[P0]**

- Every screen renders correctly in **fr** and **en**, at text scale 0.85 / 1.0 / 1.3, light and dark, on a 320 dp-wide screen.
- Every screen has a defined empty, loading, error and offline state. A screen without all four is not done.
- No screen requires more than 400 KB to render from cold cache.
- Every destructive action (cancel, refund, offboard) has a confirmation naming exactly what will happen and what it will cost.
- Every money amount displayed anywhere is produced by `Money.format(locale)` from the shared domain package. No exceptions.
- Golden tests cover the ticket, the seat map, the payment waiting screen and all conductor verdicts.
