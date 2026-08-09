# BilletEnLigne — Payments, Billing & Refunds

**Status:** Draft v1 · **Date:** 2026-08-09
**Implements:** ADR-0005 (orchestration) · ADR-0006 (rail sequencing) · ADR-0012 (holds) · ADR-0015 (policy as data)

This is the subsystem that decides whether the business works. It gets more rigour than anything else.

---

## 1. Principles

1. **Money is never a `double`.** `Money` = integer minor units + `Currency`. XAF is zero-decimal. Cross-currency arithmetic does not compile.
2. **The ledger is the truth.** Every balance is derived from immutable double-entry rows. No mutable `balance` column exists anywhere in the schema.
3. **Nothing is issued optimistically.** Ticket on `captured`, never on `pending`.
4. **Every mutation is idempotent.** A retry is free; a double charge is unforgivable.
5. **Callbacks are hints, not facts.** Always re-query the PSP for authoritative status.
6. **Every failure has its own name and its own sentence.** No "Payment failed."
7. **`indeterminate` is a real state** with a real queue and a real human process behind it.
8. **The quote the user sees is computed by the code that charges them** — shared domain (ADR-0004).

---

## 2. The money model

```dart
final class Money {
  final int minor;            // 9000 XAF = 9000 (zero-decimal); 90.00 EUR = 9000
  final Currency currency;    // XAF(exponent:0), CDF(0), USD(2), EUR(2)
}
```

Allocation uses the **largest-remainder** method so splits always sum exactly to the original — a 9 300 XAF booking split across operator payable, platform commission and platform fee must reconcile to the cent, every time, with no rounding dust left in a suspense account.

### Chart of accounts

| Account | Nature | Meaning |
|---|---|---|
| `psp:<rail>:clearing` | Asset | Money the PSP holds for us, not yet settled |
| `cash:<station>:till` | Asset | Physical cash in a vendor's drawer |
| `bank:operating` | Asset | Our bank account |
| `payable:operator:<id>` | Liability | What we owe an operator |
| `payable:refund:<id>` | Liability | Refund owed, not yet paid |
| `revenue:commission` | Income | Our commission on ticket face value |
| `revenue:service_fee` | Income | Traveller-facing booking fee |
| `revenue:reschedule_fee` | Income | Our share of change fees |
| `expense:psp_fees` | Expense | What the rail costs us |
| `suspense:unreconciled` | Asset | Money we cannot yet attribute. **Watched daily.** |

### Worked example — a 9 000 XAF ticket, paid by Airtel Money, 5% commission, 300 XAF service fee

**On capture:**

```
DR  psp:airtel:clearing            9 300
    CR  payable:operator:ODN                8 550     (9 000 − 450 commission)
    CR  revenue:commission                    450
    CR  revenue:service_fee                   300
```

**On PSP settlement (T+1 to T+3):**

```
DR  bank:operating                 9 240
DR  expense:psp_fees                  60     (PSP's cut)
    CR  psp:airtel:clearing                 9 300
```

**On payout run to the operator:**

```
DR  payable:operator:ODN           8 550
    CR  bank:operating                      8 550
```

Every row is immutable. `payable:operator:ODN` at any instant *is* what we owe Océan du Nord — nobody computes it, nobody can drift it.

---

## 3. Payment intent state machine

```
                    created
                       │ initiate()
                       ▼
   ┌──────────────── pending ────────────────┐
   │                   │                      │
   │  callback ───────┤├──────── poll        │
   │                   ▼                      │
   │              authorized                  │
   │                   │ capture (auto)       │
   │                   ▼                      │
   │               CAPTURED  ──────────────▶ ticket issued, ledger written, SMS sent
   │
   ├──▶ FAILED         declined / insufficient / wrong PIN / wrong operator
   ├──▶ EXPIRED        user never responded within the 10-min window
   ├──▶ CANCELLED      user backed out
   └──▶ INDETERMINATE  no terminal answer within 15 min → reconciliation queue
                          │
                          ├─ resolved_captured   (money moved; issue ticket, or refund if seat lost)
                          └─ resolved_failed     (no money moved; release hold, notify)
```

All transitions are guarded by `SELECT … FOR UPDATE` on the intent row and are idempotent. Callback and poll race constantly in production; whoever wins, the result is identical.

### Timing contract (get this wrong and you sell a seat twice)

```
t=0     hold created ─────────────────────────────────── 15:00 TTL
t=0     payment window opens ───────────────── 10:00
t=10m   payment window closes → EXPIRED
t=15m   hold expires

INVARIANT: hold TTL > payment window. Always. Asserted in a unit test.
```

Poll schedule for a `pending` intent: 5 s, 10 s, 20 s, 40 s, 60 s, then every 60 s to 15 min, then `INDETERMINATE`.

---

## 4. Rail adapters

Every rail implements one port (ADR-0005). Adapter responsibilities: auth, request shaping, response and error-code mapping to our taxonomy, signature verification, and its own fake.

### 4.1 Airtel Money

- OAuth2 client-credentials, token cached and refreshed ahead of expiry.
- Collection: `POST /merchant/v1/payments/` with `X-Country: CG`, `X-Currency: XAF`, our reference, and the subscriber MSISDN. Triggers a USSD/PIN prompt on the handset.
- Status: `GET /standard/v1/payments/{ref}`.
- Refund/disbursement is a **separate API and a separate float** — the disbursement wallet must be funded, and running it dry silently breaks refunds. Monitored with an alert (§8).
- Callbacks: verify signature, allowlist source IPs, then re-query. Never trust the body.

### 4.2 MTN MoMo

- API-user/API-key provisioning → OAuth2 bearer token per product.
- **Collections** product: `POST /collection/v1_0/requesttopay` with `X-Reference-Id` (our UUID — this *is* the idempotency key), `X-Target-Environment`, subscriber MSISDN.
- Status: `GET /collection/v1_0/requesttopay/{X-Reference-Id}`.
- **Disbursements** product for refunds: `POST /disbursement/v1_0/transfer`. Separate credentials, separate float.
- Sandbox and production differ meaningfully. Nothing ships without a production smoke test against a real handset, on a real Congolese SIM, on both networks.

### 4.3 Card

PSP-hosted 3-D Secure page in a `flutter_custom_tabs` / `SFSafariViewController`. We never see a PAN, we never store one, we are never in PCI scope beyond SAQ-A. Return via deep link; **status is confirmed server-side**, never from the redirect URL.

### 4.4 Cash

Not a PSP — but it implements the same port, because that is what keeps agency sales and digital sales in one reconciliation.

- **Reserve-then-pay:** traveller reserves in-app, gets a payment code + 4-hour deadline, pays at any agency of that operator. Vendor enters the code, ticket issues.
- **Counter sale:** vendor sells directly at the till.

Both debit `cash:<station>:till`. Till sessions are opened and closed per vendor per shift; a close produces a **variance report** the station manager signs off. Cash sales carry **zero commission** by design (product brief D-04) — that is what gets the console installed, and the console is what gives us the data.

---

## 5. Failure taxonomy

Every code below maps to a distinct message and a distinct recovery (feature spec §6.5). This table is the contract between the adapters, the domain and the copy deck.

| Code | Retryable | Hold kept | Recovery |
|---|---|---|---|
| `payment.insufficient_funds` | ✅ | ✅ | Another number, another rail, or top up |
| `payment.wrong_pin` | ✅ | ✅ | Retry on the same intent |
| `payment.user_declined` | ✅ | ✅ | Back to method selection |
| `payment.timeout_no_response` | ✅ | ✅ | Resend prompt |
| `payment.wrong_operator_for_msisdn` | ✅ | ✅ | Auto-switch to the detected operator |
| `payment.subscriber_not_found` | ✅ | ✅ | Correct the number |
| `payment.subscriber_barred` | ❌ | ✅ | Another rail |
| `payment.limit_exceeded` | ✅ | ✅ | Split, or another rail |
| `payment.psp_unavailable` | ✅ | ✅ | Another rail; circuit breaker demotes this one |
| `payment.duplicate_reference` | — | ✅ | Return the original intent (idempotency working) |
| `payment.indeterminate` | — | **extended** | Reconciliation queue + SMS |
| `hold.expired_during_payment` | ❌ | ❌ | Re-attempt hold; if gone, auto-refund + apologise in-app **and** by SMS |

`hold.expired_during_payment` is rare, ugly, and must be tested. It is the path that produces the loudest complaints.

---

## 6. Billing

Two distinct billing relationships, and conflating them is a common and expensive mistake.

### 6.1 Traveller-facing

The traveller pays **one amount, once**, with the breakdown visible before commitment:

```
Tarif (1 × Brazzaville → Pointe-Noire)      9 000 FCFA
Frais de service                              300 FCFA
────────────────────────────────────────────────────
Total                                       9 300 FCFA
```

Rules: the service fee is disclosed on the **first screen that shows a total**, never introduced at checkout. It is a **flat amount per seat**, not a percentage — percentages feel like a tax and are harder to trust. There are no other charges, ever. A receipt (PDF + SMS) is issued on capture.

### 6.2 Operator-facing

We do not invoice operators for tickets — we **net commission at source** and pay out the difference. Far simpler, and it means we never chase an operator for money.

**Payout run** (weekly by default, configurable per operator down to daily for high-volume):

```
Statement — Océan du Nord — 01→07 août 2026

Ventes en ligne            412 billets     3 708 000 FCFA
Ventes guichet (espèces)   188 billets     1 692 000 FCFA   (commission 0)
                                          ─────────────────
Commission (5% en ligne)                    −185 400 FCFA
Remboursements émis         −14 billets      −126 000 FCFA
Frais de modification (part opérateur)        +42 000 FCFA
Ajustements (litiges)                          −9 000 FCFA
                                          ─────────────────
Net à payer                                3 429 600 FCFA
Versement prévu             12/08/2026 · MoMo Business ****4471
```

- Statement is generated as a **PDF invoice/credit note** meeting local commercial-document requirements, in French, downloadable from the console and emailed.
- Payout goes to a verified settlement account: MoMo Business wallet or bank account. **Changing it requires owner + fresh 2FA + a 24 h cooling-off with the old account notified** (ADR-0011). Settlement-account takeover is the highest-value fraud against a platform like this.
- **Cash sales never generate a payout** — the operator already has the money. They appear on the statement for completeness and reconciliation only. This is worth stating on the statement itself, because it is the #1 operator question.
- Payout release requires `super_admin` approval (ADR-0011). Two-person control on money leaving.

### 6.3 Reconciliation — the daily job

Three-way match, automated, run every morning:

```
   our ledger   ⟷   PSP settlement report   ⟷   bank/wallet statement
```

Anything unmatched lands in `suspense:unreconciled` with an age. **Alert if any item is older than 48 h.** The admin console shows the suspense list as a work queue, not a report — an unreconciled item is a task with an owner, not a number on a dashboard.

---

## 7. Refunds

The operator owns the policy (ADR-0015); we own the execution and the guarantees.

### 7.1 The policy wizard (operator console)

Six questions, French, answerable by a bus company owner on a tablet in under ten minutes. Presets first — most operators will pick one and never look again.

> **Configurez votre politique de remboursement**
>
> **1. Trois modèles pour démarrer**
> ◉ **Souple** — 100% jusqu'à 24 h avant, 50% jusqu'à 2 h avant
> ○ **Standard** — 90% jusqu'à 48 h, 50% jusqu'à 24 h, 0% ensuite
> ○ **Strict** — aucun remboursement, mais modification gratuite jusqu'à 24 h
> ○ **Personnalisé**
>
> **2. Vos paliers** *(éditeur visuel — voir ci-dessous)*
>
> **3. Frais fixes de dossier ?**  `[ 500 ] FCFA` par billet · ☐ aucun
>
> **4. Où va l'argent ?**
> ◉ **Sur le moyen de paiement d'origine** — Airtel Money, MTN, carte
> ○ **En espèces, à l'agence** — le client doit se présenter au guichet
> ○ **Avoir** — utilisable sur un prochain voyage, valable 6 mois
> ○ **Le client choisit** parmi les options que vous cochez
>
> **5. Délai de traitement que nous annonçons au client**
> `[ 72 ] heures`
>
> **6. Tarifs non remboursables** ☐ Promo ☐ Groupe ☐ Enfant

The tier editor is a **visual timeline**, not a table — this is the part that makes the wizard usable:

```
   Départ ◀────────────────────────────────────────────── temps
   0h        2h              24h             48h            7j
   ├─────────┼───────────────┼───────────────┼──────────────┤
   │   0%    │      50%      │      90%      │     100%     │
   └─────────┴───────────────┴───────────────┴──────────────┘
        aucun      moitié       −10%          intégral
              ▲ glissez pour ajuster
```

Live preview beside it, in both languages, showing exactly what the traveller will read:

> *« Annulation gratuite jusqu'au 13 août à 06:00. Ensuite, 50% remboursé jusqu'à 2 heures avant le départ. Remboursement sur votre compte Airtel Money sous 72 heures. »*

And the platform floor stated as non-editable, so the operator understands what they are signing:

> ⓘ **Toujours applicable :** si vous annulez un départ ou accusez plus de 3 h de retard, le client est remboursé intégralement, quelle que soit cette politique.

**Saving is versioned.** The console says plainly: *"Cette politique s'appliquera aux réservations effectuées à partir du 9 août 2026, 14:32. Les réservations existantes conservent la politique en vigueur au moment de l'achat."*

### 7.2 Traveller experience

The policy is visible **three times, before money moves**: as a one-line summary on the departure detail, in full before payment, and on the ticket itself. Nobody should discover the refund rule at the moment they need it.

Cancelling:

```
   Annuler ce billet ?

   Brazzaville → Pointe-Noire · sam. 15 août · 06:00
   Départ dans 3 jours 4 heures

   Payé                       9 300 FCFA
   Remboursement (100%)       9 000 FCFA
   Frais de service               −300 FCFA   ⓘ non remboursables
   ─────────────────────────────────────────
   Vous recevrez              9 000 FCFA
   sur Airtel Money +242 06 12 34 56
   sous 72 heures

   [ Garder mon billet ]   [ Annuler et être remboursé ]
```

The quote is produced by `quoteRefund()` from the shared domain — the same function the server executes with (ADR-0004). The number on this screen and the number that arrives are the same number.

**If the destination is `agency_cash`**, the flow changes shape and the app is honest about it up front:

> **Remboursement en agence**
> Océan du Nord rembourse en espèces au guichet. Présentez ce code à l'agence de Brazzaville (Rue Dougou) sous 30 jours.
> **BEL-R-8XQ2M4**  [QR]

The vendor scans it, pays cash, closes the claim against their till. Reconciled like any other till movement.

### 7.3 Refund state machine

```
requested ──▶ approved ──▶ processing ──▶ COMPLETED
     │            │             │
     │            │             └──▶ FAILED ──▶ retry / change destination / manual
     │            └──▶ REJECTED (outside policy — with the reason shown)
     └──▶ CANCELLED (user changed their mind)

  agency_cash variant:
requested ──▶ approved ──▶ claim_issued ──▶ CLAIMED (vendor pays, till debited)
                                │
                                └──▶ EXPIRED (30 days) ──▶ escheat per policy
```

Approval routing:
- **Within policy, at or below the vendor cap** → automatic. No human. Most refunds.
- **Above the vendor cap** → operator `finance` role approves.
- **Outside policy** (goodwill) → operator `org_admin` or BilletEnLigne `operations`, with a mandatory reason.
- **Operator-caused** → automatic, full, immediate, no approval, no cap. Platform floor.

### 7.4 Execution

- Mobile money refunds go out on the **disbursement** API, which is a different product, different credentials and a **separately funded float** from collections. If the float is empty, refunds silently queue — so float level is a **paged alert**, not a dashboard tile.
- Card refunds go to the original PAN through the PSP. Slower (5–10 days) and we say so.
- Partial refunds are supported (one passenger of four cancels).
- **A refund is a new payment intent, never a reversal** of the original (ADR-0005). It has its own idempotency key, its own state machine, its own ledger entries.
- Ledger on completion:

```
DR  payable:refund:<booking>       9 000
    CR  psp:airtel:clearing                 9 000
```

- The ticket is **voided at approval**, not at completion — so a refunded ticket cannot board while the money is in flight. The conductor's next manifest sync carries the void; a signed ticket whose booking is voided fails the manifest check offline (ADR-0007).

### 7.5 Disputes

A traveller who believes they paid and got nothing has one button on the payment screen — **"J'ai un problème"** — which opens a claim pre-filled with the intent id, rail, MSISDN and timestamps. It lands in the admin console's payment queue beside the matching `indeterminate` intent, so the agent sees both sides at once. Target: first response within 4 h, resolution within 48 h. Support agents can refund up to a cap without escalation, because the cost of a 9 000 XAF goodwill refund is far below the cost of an unresolved trust failure in a market this size.

---

## 8. Monitoring — the alerts that actually matter

| Alert | Threshold | Why |
|---|---|---|
| Payment success rate by rail | < 85% over 30 min | The number that predicts revenue |
| `indeterminate` queue depth | > 20 | Money in limbo, customers in the dark |
| Disbursement float (per rail) | < 3 days of refund volume | Silent refund failure |
| Suspense account age | any item > 48 h | Reconciliation breaking down |
| Hold-to-payment conversion | drop > 10 pts day/day | A rail or the funnel is broken |
| Callback latency p95 | > 60 s | PSP degradation before users notice |
| Till variance per station | > 2% of takings | Cash leakage — the operator's core problem |

---

## 9. Test surface — a rail is not production-ready until all of this passes

A `FakePaymentGateway` that can produce, on demand: capture · decline · every failure code · **lost callback** · **duplicate callback** · **out-of-order callback** · **callback after timeout** · **callback for an unknown reference** · **capture arriving after the hold expired**.

Plus property-based tests asserting the invariants that must never break:

- Ledger sums to zero across every account, after any sequence of operations.
- A seat is never sold twice, under concurrent hold attempts.
- Refunds never exceed the amount captured for a booking.
- Replaying any idempotency key produces byte-identical results and no new ledger rows.
- `hold TTL > payment window` for every configuration.
