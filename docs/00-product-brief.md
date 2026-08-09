# BilletEnLigne — Product Brief & Market Decisions

**Status:** Draft v1 · **Owner:** Design & Engineering Lead · **Date:** 2026-08-09

---

## 1. The opportunity

Congo has real intercity bus demand and effectively zero digital ticketing. Today the journey is:

1. Traveller physically goes to the *gare routière* or a company agency, often the day before.
2. Queues, pays cash, receives a hand-written or carbon-copy paper ticket.
3. Seat allocation is informal — overselling and double-selling happen.
4. No refunds, no reschedule, no record. Lost ticket = lost money.
5. Operators reconcile revenue manually; leakage between conductor, agent and owner is the single biggest operational cost.

Meanwhile mobile money is already the dominant non-cash rail. In the CEMAC zone mobile money is ~71% of non-cash transactions with ~52M active accounts. In Congo-Brazzaville the market is a three-player race — Airtel Money (~35%), Orange Money (~45%), MTN MoMo (~20%).

**The wedge is not the traveller. It is the operator's cash leakage.** Travellers get convenience; operators get provable revenue. We sell to operators, we delight travellers.

### Launch market — decided

**Republic of Congo (Congo-Brazzaville) only.** Confirmed 2026-08-09. Other countries come later, and are explicitly out of scope for v1.

- **Currency: XAF** (CFA franc BEAC, pegged 655.957 = 1 EUR). **Zero-decimal — XAF has no minor unit.** A `double` anywhere near money is a bug generator; `Money` holds integer minor units plus an explicit `Currency`.
- **Country code +242**, 9 national digits, leading `0` retained in international form.
- **Mobile money: Airtel Money, MTN MoMo.** Orange Money is the largest single wallet (~45%) and is a fast-follow — see ADR-0006.
- **Language: French primary, English first-class** (ADR-0008).

The brief names Airtel and MTN, which is itself the confirmation: MTN does not operate in the DRC, so this was only ever Brazzaville.

### What "later" means in engineering terms

There is a difference between *keeping country as configuration* and *building multi-country machinery*, and we do only the first.

**Do now** — one `Market` value object in `bel_domain` bundling everything country-specific: currency, dialling code, MSISDN length and operator-prefix table, timezone, default locale, available payment rails. One instance exists: `Market.congoBrazzaville`. Anything country-specific reads from it rather than hardcoding.

**Do not do now** — market switching at runtime, per-market pricing engines, a market picker in onboarding, multi-currency ledgers, or cross-border booking. All of that is speculative until there is a second market, and every piece of it would be built on guesses about which market comes second.

The result: adding the DRC later is a **new `Market` instance plus one or two PSP adapters** (Orange Money and Vodacom M-Pesa; Airtel already exists) plus a currency entry for CDF. It is a data addition and an adapter, not a rewrite — and there is a test asserting nothing outside `Market` hardcodes a currency, dialling code or operator prefix.

---

## 2. Who we are building for

### Persona A — Aline, 29, trader, Brazzaville → Pointe-Noire monthly
Android Go phone, 2 GB RAM, Android 10. Prepaid data, buys 500 MB bundles. Speaks French, some Lingala. Has Airtel Money, uses it daily. Does not have a bank card.
**Job:** "Get me a confirmed seat without losing half a day at the gare."
**Fear:** "I pay and the money disappears and I have no ticket."

### Persona B — Jean-Marc, 45, operator owner, 14 coaches
Has a laptop in the office, a smartphone in the field. Runs three agencies.
**Job:** "Know exactly how many seats sold and how much money actually reached me."
**Fear:** "A tech company that takes my customers and my margin."

### Persona C — Pascal, 34, conductor / boarding agent
Cheap Android, often no data at the roadside. Boards 60 people in 10 minutes.
**Job:** "Verify a ticket in under 2 seconds, offline, in the sun."
**Fear:** "The app is slow and the bus leaves late."

### Persona D — Marie, 38, diaspora in Paris, buys for her mother
Good phone, good network, has a Visa card.
**Job:** "Buy a ticket for someone else and send it to their phone."

Personas A and C are the hard constraints. If it works for them it works for everyone.

---

## 3. Known operators (launch target list)

| Operator | Core routes | Notes |
|---|---|---|
| Océan du Nord | Brazzaville ↔ Pointe-Noire, Dolisie, Nkayi | Largest, green fleet, ~9 000 XAF Bzv–PN |
| Trans Bony Voyages | Pointe-Noire ↔ Brazzaville | Established |
| Local/regional operators | Owando, Ouesso, Gamboma, Madingou | Long tail, 1–5 coaches |

Strategy: sign **one anchor operator** with real volume, prove the revenue-assurance story, then the long tail follows because travellers start asking "are you on BilletEnLigne?".

---

## 4. Product decisions (the ones that matter)

### D-01 — Marketplace, not a single-operator app
Multi-operator from day one. A traveller picks a route and *then* compares operators by price, departure time and rating. A single-operator app is a dead end; the network effect is the moat.
**Trade-off:** harder onboarding (need an operator console), slower first launch. Accepted.

### D-02 — Mobile money is the default, not an option
The payment screen opens on **Mobile Money with the user's own operator pre-selected**, detected from their phone number prefix. Card is a secondary tab. This inverts the usual e-commerce hierarchy and it is deliberate.

### D-03 — We hold inventory, operators keep control of pricing
BilletEnLigne is the system of record for seats. Operators set price, schedule and cancellation policy through the console. We never silently discount.

### D-04 — Cash-in at agency stays supported
Digital-only would exclude too many travellers. An agent in the console can sell a seat and take cash — it flows through the same inventory and reconciliation. This is what makes operators say yes.

### D-05 — Offline-first is a product feature, not an optimisation
Search results, held bookings and issued tickets survive a dead network. Boarding validation works with **zero connectivity**. See ADR-0003.

### D-06 — The ticket is a signed offline-verifiable object
Not a database lookup. A compact signed payload in a QR code, verifiable by the conductor's phone with no network. See ADR-0007.

### D-07 — French is the primary language, English is first-class
Not "French translated from English". Copy is authored in French, then English. Lingala/Kituba are a post-launch consideration for onboarding only. See ADR-0008.

### D-08 — Free reschedule window, paid after that
Modify departure ≥ 24 h before: free. 24 h–2 h before: fee set by operator (default 10%). < 2 h: no change, no refund. This is a policy default operators can override.

---

## 5. Business model

| Stream | Detail |
|---|---|
| **Booking fee (traveller)** | 200–500 XAF flat per seat, shown transparently. Never a hidden percentage. |
| **Commission (operator)** | 4–6% of ticket face value on digital sales only. Cash-at-agency sales through the console are **free** — that is the trojan horse that gets the console installed. |
| **Reschedule fee share** | Split with operator. |
| **Later** | Parcel/colis booking on the same coaches (high margin, already an informal business), operator SaaS tier, insurance attach. |

Unit economics sanity check at 9 000 XAF Bzv–PN: 5% = 450 XAF operator commission + 300 XAF traveller fee = **750 XAF per seat**. A 60-seat coach at 70% digital penetration = ~31 500 XAF per departure. PSP cost on mobile money collection is the main variable cost — must be negotiated as merchant-rate, not consumer-rate, before launch.

---

## 6. What "good" looks like at launch

| Metric | Target |
|---|---|
| Search → paid ticket completion | ≥ 55% |
| Payment success (MoMo, first attempt) | ≥ 88% |
| Time to first ticket, new user | ≤ 3 min |
| Boarding scan time | ≤ 2 s, offline |
| Cold start on 2 GB Android 10 | ≤ 2.5 s |
| APK download size (per-ABI) | ≤ 15 MB |
| Data per booking session | ≤ 400 KB |
| Crash-free sessions | ≥ 99.5% |

---

## 7. Risks and how we blunt them

| Risk | Mitigation |
|---|---|
| **Mobile money settlement delays** — PSP confirms hours later | Never issue a ticket on an optimistic assumption. Seat is *held* (15 min TTL), ticket issues on confirmed callback. Clear UI for the pending state (see feature spec §6.4). |
| **Trust: "I paid and got nothing"** | SMS receipt on payment confirmation, independent of the app. SMS is the trust anchor in this market. Budget for it. |
| **Operator refuses digital seat map** | Phase 1 supports *unnumbered* inventory (sell N seats, no seat selection). Seat maps are an upsell. |
| **PSP API instability / sandbox ≠ production** | Payment orchestration behind a port with per-PSP adapters + circuit breaker + manual reconciliation console. See `04-payments.md`. |
| **Data cost is a real barrier** | Aggressive caching, no autoplay media, thumbnails ≤ 20 KB, optional "économiseur de données" mode. |
| **Fraud: screenshot/replay of a QR** | Signed ticket + single-use redemption + rotating offline nonce. See ADR-0007. |
| **We build a marketplace nobody lists on** | Anchor operator contract signed *before* engineering commits to seat maps. |

---

## 8. Scope fence for v1

**In:** traveller mobile app (iOS/Android), operator web console, conductor scan mode inside the same Flutter app, Airtel Money + MTN MoMo + card, FR/EN, offline tickets, printable A4/thermal ticket, reschedule/cancel.

**Out (explicitly):** loyalty programme, parcel booking, in-app chat, live bus GPS tracking, multi-leg itineraries, web booking portal for travellers (mobile-first mandate — the responsive web portal comes after the app proves out).

---

Sources: [Petit Futé — Congo bus operators](https://www.petitfute.com/v46963-brazzaville/c1122-voyage-transports/c1145-avion-bateau-bus-train-taxi-parking/c1153-bus-autocar/) · [Marché Paiement Mobile CEMAC 2026](https://simiz.io/blog/marche-paiement-mobile-cemac-2026) · [MTN MoMo vs Airtel Money Congo](https://blog.iambeezy.app/fr/mtn-momo-meilleur-airtel-money-congo-cg-2026/) · [Vox Congo — transport Brazzaville–Pointe-Noire](https://www.vox.cg/transport-bus-entre-brazzaville-pointe-noire-imperturbable/)
