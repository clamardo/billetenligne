# BilletEnLigne — End-to-End Architecture

**Status:** Draft v1 · **Date:** 2026-08-09
**Decisions this document implements:** ADR-0001 (Onion) · ADR-0003 (offline-first) · ADR-0004 (Dart end-to-end) · ADR-0011 (tenancy) · ADR-0012 (inventory)

---

## 1. System map

```
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │  Traveller   │  │  Conductor   │  │  Operator    │  │   Admin      │
   │  iOS/Android │  │  (same bin)  │  │  console     │  │  back office │
   │   Flutter    │  │   Flutter    │  │ Flutter Web  │  │ Flutter Web  │
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
          │                 │                 │                 │
          └────────┬────────┴────────┬────────┴────────┬────────┘
                   │                 │                 │
              /public/v1        /console/v1        /admin/v1
                   │                 │                 │
          ┌────────┴─────────────────┴─────────────────┴────────┐
          │              API Gateway  (Dart Frog)               │
          │  authn · authz · tenant scoping · rate limit · idem │
          └────────┬─────────────────────────────────┬──────────┘
                   │                                 │
     ┌─────────────┴──────────────┐    ┌─────────────┴──────────────┐
     │      Application layer     │    │        Workers             │
     │  use cases (shared domain) │    │  payment poller            │
     └─────────────┬──────────────┘    │  reconciliation            │
                   │                   │  outbox drain / notifier   │
                   │                   │  hold sweeper              │
                   │                   │  payout run                │
                   │                   └─────────────┬──────────────┘
                   │                                 │
     ┌─────────────┴─────────────────────────────────┴──────────────┐
     │   PostgreSQL (RLS)   │   Redis   │   Object store   │  KMS    │
     │   inventory, ledger  │  cache,   │  KYB docs, PDFs  │ ticket  │
     │   bookings, audit    │  queues   │                  │ keys    │
     └──────────────────────┴───────────┴──────────────────┴─────────┘
                   │
     ┌─────────────┴────────────────────────────────────────────────┐
     │  Airtel Money │ MTN MoMo │ Orange Money │ Card PSP │ SMS │ Push│
     └──────────────────────────────────────────────────────────────┘
```

---

## 2. Repository layout

Monorepo, Melos.

```
billetenligne/
├─ packages/
│  ├─ bel_domain/          pure Dart. Zero deps. Shared client+server. THE CORE.
│  ├─ bel_contracts/       wire DTOs, validators, error codes. Shared.
│  ├─ bel_design/          "Kilo" design system. Flutter. Shared by all 3 UI apps.
│  ├─ bel_client/          typed HTTP client over bel_contracts.
│  ├─ bel_localization/    YAML i18n catalog + loader. Shared by apps AND server.
│  └─ bel_testing/         fakes, builders, golden harness.
├─ apps/
│  ├─ traveller/           Flutter mobile (+ conductor mode)
│  ├─ console/             Flutter Web — operator
│  └─ admin/               Flutter Web — BilletEnLigne
├─ services/
│  ├─ api/                 Dart Frog
│  └─ worker/              Dart, cron + queue consumers
├─ infra/                  IaC, migrations, CI
└─ docs/
```

`bel_domain` is the asset. It is the only package with no dependencies at all, it runs its full test suite in about two seconds, and both the app and the server compile it in.

---

## 3. The onion, layer by layer

### 3.1 Domain (`bel_domain`) — no dependencies, not even Flutter

Contains what would still be true if we deleted every screen and every database.

```
bel_domain/lib/src/
├─ money/            Money, Currency, Amount arithmetic (integer minor units)
├─ identity/         PhoneNumber, MSISDN + operator detection, PassengerName
├─ catalog/          City, Station, Route, Operator, Coach, SeatMap, SeatLabel
├─ scheduling/       Departure, DeparturePattern, Capacity
├─ booking/          Booking, Hold, Passenger, BookingRef, BookingState
├─ pricing/          Fare, FeeSchedule, PriceQuote, PricingPolicy
├─ policy/           CancellationPolicy, ReschedulePolicy, RefundQuote
├─ payment/          PaymentIntent, PaymentState, PaymentRail, IdempotencyKey
├─ ticketing/        Ticket, TicketPayload, RedemptionRecord, VerificationResult
├─ tenancy/          TenantId, TenantScope, Capability, Role
├─ lifecycle/        OperatorApplication, OperatorStatus, KybDocument
└─ shared/           Result<T,F>, DomainFailure, Clock, IdGenerator
```

Three properties make this layer worth having:

**Entities carry behaviour.** The rule lives with the data.

```dart
sealed class RescheduleFailure implements DomainFailure { ... }

final class Booking {
  Result<RescheduleQuote, RescheduleFailure> quoteReschedule({
    required Departure target,
    required DateTime now,
    required ReschedulePolicy policy,
  }) {
    if (state != BookingState.confirmed)  return Err(NotReschedulable(state));
    if (target.id == departureId)         return Err(SameDeparture());
    final lead = departsAt.difference(now);
    if (lead < policy.hardCutoff)         return Err(TooCloseToDeparture(policy.hardCutoff));
    final fee  = policy.feeFor(lead, faresPaid.total);
    final diff = target.fare.subtract(faresPaid.total);
    return Ok(RescheduleQuote(fee: fee, fareDifference: diff, payable: fee.add(diff.orZero())));
  }
}
```

The traveller app calls this to render the quote. The API calls the same method to charge. **They cannot disagree** — this is the entire argument for ADR-0004, expressed in fifteen lines.

**Money is never a `double`.** XAF is zero-decimal; `Money` holds integer minor units plus a `Currency`, and arithmetic across currencies does not compile.

**Failures are sealed, exhaustive and typed.** No exceptions crossing layers, no stringly-typed errors. `switch` on a failure is checked by the compiler, which is how every failure in §6.5 of the feature spec ends up with its own copy instead of "something went wrong".

### 3.2 Application — use cases and ports

One class, one use case, one public `call`. Ports are abstract interfaces *declared here* and implemented outward.

```dart
// application/ports/
abstract interface class DepartureRepository {
  Future<Result<List<Departure>, RepoFailure>> search(SearchCriteria c, TenantScope s);
  Stream<Departure> watch(DepartureId id);
}
abstract interface class PaymentGateway {          // implemented per rail — ADR-0005
  Future<Result<PaymentIntent, PaymentFailure>> initiate(InitiatePayment cmd);
  Future<Result<PaymentIntent, PaymentFailure>> status(PaymentIntentId id);
  Future<Result<Refund, PaymentFailure>> refund(RefundCommand cmd);
}
abstract interface class TicketSigner { ... }
abstract interface class Clock { DateTime now(); }

// application/usecases/
final class HoldSeats {
  const HoldSeats(this._departures, this._holds, this._clock);
  Future<Result<Hold, HoldFailure>> call(HoldSeatsCommand cmd) async { ... }
}
```

The same `HoldSeats` use case runs **inside the API** (authoritative, against Postgres) and its client-side sibling orchestrates the call. Ports differ; the domain rules do not.

### 3.3 Infrastructure — adapters, and the only layer allowed to know about the world

- **Client:** Drift DAOs, Dio HTTP client, secure storage, camera, printing, PSP-agnostic.
- **Server:** Postgres repositories with explicit SQL and explicit transactions, PSP adapters (`AirtelMoneyGateway`, `MtnMomoGateway`, `CardGateway`, `CashGateway` — all implementing the same `PaymentGateway` port), SMS adapter, KMS signer, object store.

DTO ↔ entity mapping lives here and nowhere else. An entity never carries a `fromJson`.

### 3.4 Presentation — thin by rule

Riverpod `AsyncNotifier`s that call exactly one use case per method and map `Result` to UI state. If a controller contains an `if` about business rules, that `if` belongs in the domain. This is the single most common review comment we should expect to write.

---

## 4. Data model (core tables)

```sql
-- Tenancy ------------------------------------------------------------
operators(id, code, legal_name, status, country, settlement_account_id,
          commission_bps, created_at, approved_at, suspended_at, ...)

-- Catalogue ----------------------------------------------------------
cities(id, code, name_fr, name_en, lat, lng)
stations(id, city_id, operator_id NULL, name, lat, lng, boarding_notes)
routes(id, operator_id, origin_city_id, dest_city_id, code, distance_km, duration_min)
coaches(id, operator_id, plate, seat_map_id, amenities jsonb, status)
seat_maps(id, operator_id, layout jsonb, capacity)

-- Scheduling ---------------------------------------------------------
departure_patterns(id, route_id, rrule, default_coach_id, default_fare_minor, active)
departures(id, operator_id, route_id, coach_id, departs_at, arrives_at,
           capacity, fare_minor, currency, status, seat_selection_enabled)

-- Inventory (the hot path) -------------------------------------------
seats(departure_id, seat_label, state, booking_id NULL, held_until NULL,
      hold_token NULL, PRIMARY KEY (departure_id, seat_label))
-- state ∈ available | held | sold | blocked
-- held_until is checked on read AND swept by a worker (ADR-0012)

-- Booking ------------------------------------------------------------
bookings(id, ref, operator_id, departure_id, purchaser_user_id, state,
         total_minor, currency, channel, created_at, idempotency_key)
booking_seats(booking_id, seat_label, passenger_name, passenger_phone, ticket_id)

-- Payments -----------------------------------------------------------
payment_intents(id, booking_id, rail, msisdn, amount_minor, currency, state,
                psp_ref, idempotency_key UNIQUE, created_at, terminal_at,
                last_polled_at, poll_attempts, failure_code)
payment_events(id, intent_id, source, raw jsonb, received_at)   -- append-only
ledger_entries(id, txn_id, account, direction, amount_minor, currency,
               booking_id, created_at)                          -- double-entry, immutable

-- Ticketing ----------------------------------------------------------
tickets(id, booking_id, seat_label, payload_cbor, signature, key_id,
        rotating_secret, issued_at, voided_at)
redemptions(ticket_id, departure_id, scanned_at, device_id, mode, PRIMARY KEY(ticket_id))

-- Governance ---------------------------------------------------------
operator_applications(id, operator_id, state, submitted_at, reviewed_by, ...)
kyb_documents(id, operator_id, type, storage_key, expires_at, verified_by, ...)
audit_log(id, actor_id, actor_type, action, subject, reason, before, after, at)
outbox(id, aggregate, payload jsonb, attempts, next_attempt_at, created_at)
```

**Row-Level Security is on every table carrying `operator_id`.** The console connection sets `app.tenant_id`; policies enforce it. Application filters are the second line, not the first (ADR-0011).

**`ledger_entries` and `payment_events` are append-only** — enforced by revoking UPDATE/DELETE at the role level, not by convention.

---

## 5. Key flows

### 5.1 Search → ticket (happy path)

```
App                    API                  DB                 PSP
 │  GET /trips?…        │                    │                   │
 ├─────────────────────▶│  read (cached)     │                   │
 │◀─────────────────────┤◀───────────────────┤                   │
 │  render from Drift   │                    │                   │
 │                      │                    │                   │
 │  POST /holds  +Idem  │                    │                   │
 ├─────────────────────▶│  BEGIN             │                   │
 │                      ├─ SELECT…FOR UPDATE ▶│                  │
 │                      ├─ seats → held, TTL 15m                 │
 │                      │  COMMIT            │                   │
 │◀── hold + countdown ─┤                    │                   │
 │                      │                    │                   │
 │  POST /payments +Idem│                    │                   │
 ├─────────────────────▶│  intent=pending    │                   │
 │                      ├───── collect ─────────────────────────▶│
 │                      │                    │      USSD/STK push to handset
 │◀── intent pending ───┤                    │                   │
 │  "check your phone"  │                    │                   │
 │                      │◀──── callback ─────────────────────────┤
 │                      │  verify sig, RE-QUERY authoritative    │
 │                      ├───── status ──────────────────────────▶│
 │                      │◀────── captured ───────────────────────┤
 │                      │  BEGIN                                  │
 │                      ├─ seats held→sold, booking confirmed     │
 │                      ├─ ledger: 2 entries                      │
 │                      ├─ tickets signed (KMS)                   │
 │                      │  COMMIT                                 │
 │                      ├─ enqueue SMS + push                     │
 │◀── push / poll ──────┤                                         │
 │  ticket + QR         │                                         │
```

The worker polls in parallel the whole time. Callback and poll race; the transition is idempotent and row-locked, so whichever wins, the outcome is identical (ADR-0005).

### 5.2 Offline boarding

```
Conductor device                          Server
 │ opens departure                          │
 ├─ GET /manifest/:departure ──────────────▶│
 │◀─ manifest + issuer public keys ─────────┤
 │ [ network dies — irrelevant from here ]  │
 │                                          │
 │ scan → base45 decode → CBOR              │
 │      → Ed25519 verify (local)            │
 │      → rotating code check (local TOTP)  │
 │      → redemption log check (local)      │
 │      → verdict in <2s                    │
 │ write redemption → outbox                │
 │                                          │
 │ [ network returns ]                      │
 ├─ POST /redemptions (batch, idempotent) ─▶│
```

Zero network dependency in the critical path. This is the flow that decides whether operators keep using us.

---

## 6. API design

- **REST + JSON**, versioned by path, three surfaces (`/public/v1`, `/console/v1`, `/admin/v1`) with genuinely different handlers (ADR-0011).
- **`Idempotency-Key` required** on every POST that moves money or inventory. Stored 24 h; a replay returns the original response with `Idempotency-Replayed: true`.
- **`If-None-Match` / ETag on every GET.** A 304 is ~200 bytes; on a metered prepaid bundle this is a feature, not a micro-optimisation.
- **Cursor pagination**, never offset.
- **Errors are typed and machine-readable**, sourced from `bel_contracts` so client and server share the enum:

```json
{ "error": { "code": "payment.insufficient_funds",
             "message_key": "err.payment.insufficient_funds",
             "retryable": true,
             "trace_id": "01J…" } }
```

The client renders from `message_key` through the shared YAML catalog (ADR-0008) — the server never sends user-facing prose, so we never ship an English error string to a French user.
- **OpenAPI generated from `bel_contracts`**, which keeps the escape hatch in ADR-0004 real.

---

## 7. Non-functional

| Concern | Approach |
|---|---|
| **Hosting** | Start in a single region with low latency to Congo (EU-West / Paris — best routes to Central Africa). Dart Frog compiles to a static binary in a distroless container. |
| **Scale** | Everything stateless behind a load balancer; state in Postgres and Redis. Vertical Postgres for a long time — this workload is small. Read replica when reporting starts hurting. |
| **Availability target** | 99.5% overall, but **99.9% for the ticket-read and boarding-verify paths**, which is easy because they are offline-first and barely depend on us. |
| **Observability** | Structured logs with `trace_id` propagated from the client. RED metrics per endpoint. Dedicated dashboard: **payment success rate by rail, by hour** — the number that predicts revenue. Alert on `indeterminate` queue depth. |
| **Secrets** | KMS/HSM for ticket signing keys and PSP credentials. Never in env files, never in the repo. |
| **Backups** | PITR on Postgres, tested restore quarterly. An untested backup is not a backup. |
| **CI** | Melos: analyze → layer-boundary lint → domain tests → widget/golden tests → integration on the reference emulator profile → size and cold-start budget check. |
| **Release** | Trunk-based, feature flags server-driven (ADR-0006), staged Play rollout 5→20→50→100%. |
| **Data protection** | Minimal PII. Phone + name only. Encrypted at rest, TLS in transit, PII redacted in logs, retention policy per table, right-to-export in the admin console. |
