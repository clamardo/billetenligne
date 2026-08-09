# ADR-0005 — Payment orchestration behind a port, mobile money first

**Status:** Accepted · **Date:** 2026-08-09

## Context

Three payment families with fundamentally different shapes:

- **Mobile money (Airtel Money, MTN MoMo)** — asynchronous, push-to-phone (USSD/STK prompt), user enters PIN out-of-band, result arrives by callback *or* must be polled. Latency: 5 s to several minutes. Sometimes the callback never comes and the money moved anyway.
- **Cards** — synchronous-ish, 3-D Secure redirect, well-understood.
- **Cash at agency** — no PSP at all, but must produce the same booking and the same ledger entry.

If mobile money's asynchrony leaks into the booking domain, every screen and every table grows a special case.

## Decision

One **`PaymentGateway` port** in the application layer. Every rail is an adapter. The domain knows only a `PaymentIntent` and its state machine:

```
        created
           │ initiate()
           ▼
      ┌─ pending ─────────────────┐   user is entering PIN on their handset
      │    │                      │
      │    │ callback / poll      │
      │    ▼                      │
      │  authorized ──▶ captured ─┴──▶ SETTLED   ticket issued here, and only here
      │    │
      │    ├──▶ failed        (declined, insufficient funds, wrong PIN)
      │    ├──▶ expired       (user never responded — hold released)
      │    └──▶ cancelled     (user backed out)
      │
      └──▶ indeterminate ──▶ manual reconciliation queue
```

`indeterminate` is the state most systems forget and it is the one that generates angry customers. It is first-class here.

### Non-negotiable rules

1. **The ticket is issued on `captured`, never on `pending`.** No optimistic issuance, ever.
2. **Idempotency everywhere.** Client generates a UUID v4 `Idempotency-Key` per payment attempt and reuses it across retries. Server stores `(key → intent_id)` for 24 h. A duplicate tap can never create a second charge.
3. **Callback and poll are both implemented, always.** Callbacks get lost. A worker polls every `pending` intent on a backoff schedule (5 s, 10 s, 20 s, 40 s, then every 60 s to a 15 min ceiling) until terminal. Whichever arrives first wins; the transition is idempotent and guarded by `SELECT ... FOR UPDATE`.
4. **Callbacks are untrusted input.** Verify signature/IP allowlist, then *re-query the PSP for authoritative status*. Never mutate state from callback body alone.
5. **The seat hold TTL (15 min) is longer than the payment window (10 min).** Hold expires *after* payment expires, never before. Off-by-one here means selling a seat out from under someone who is paying for it.
6. **Double-entry ledger.** Every money movement is two rows. Traveller-facing balance, operator payable and BilletEnLigne revenue are all derived from the ledger, never stored as mutable columns.
7. **Refunds are new intents**, not reversals of old ones. Mobile money disbursement is a different API from collection and often a different wallet float.

### Operator selection from phone prefix

The payment screen preselects the user's mobile money operator by MSISDN prefix (Congo-Brazzaville: `05`/`06` → Airtel, `04`/`06` ranges → MTN — exact ranges live in configuration, not code, because operators renumber). The user can always override. Getting this right removes a full screen of friction for the majority case.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Aggregator only** (e.g. a pan-African PSP) | Faster to launch, one integration, but 1–3% extra on a thin margin and no control when settlement breaks. |
| **Direct only** (Airtel + MTN APIs) | Best economics, best control, slowest to launch, and we own KYC/merchant onboarding with two telcos. |
| **Both — direct primary, aggregator fallback** | **Chosen.** The port makes this nearly free. Launch on whichever is ready first; route by operator + health at runtime. A circuit breaker demotes a failing rail automatically. |

## Consequences

Payments are the most complex subsystem and the most heavily tested. Required test surface: a fake PSP adapter that can simulate every terminal state plus lost-callback, duplicate-callback, out-of-order-callback, and callback-after-timeout. A rail is not production-ready until it passes that suite.

Ops requirement: a **reconciliation console** in the admin back office (ADR-0011) showing every `indeterminate` intent with a one-click re-query and a manual resolve that writes a ledger entry with an operator's name attached. Build this before launch, not after the first incident.
