# ADR-0012 — Seat inventory, holds and overselling

**Status:** Accepted · **Date:** 2026-08-09

## Context

Two travellers tap the same window seat at the same second while a station agent sells that same seat for cash. Meanwhile a mobile money payment takes four minutes to confirm. Whatever we do, the bus has exactly 60 seats and turning someone away at the roadside is the worst possible outcome for the brand.

## Decision

**Pessimistic holds against an authoritative server-side inventory. No overselling, ever.**

1. **The server is the only source of truth for availability.** The client's cached availability (60 s TTL, ADR-0003) is a *hint for rendering*. Every hold re-validates server-side inside a transaction.
2. **`SELECT ... FOR UPDATE` on the seat row**, scoped to `(departure_id, seat_label)`. Simple, correct, and Postgres handles this volume without breaking a sweat. No distributed locking, no Redis — the day we need it we will know.
3. **Hold TTL 15 minutes**, always strictly greater than the payment window (10 min, ADR-0005). Expiry is enforced by a `held_until` timestamp checked on read *and* swept by a worker — never by the sweeper alone, because a stalled worker must not be able to leak inventory.
4. **Cash sales take the same holds through the same code path.** The console is a client of the same API. There is no back door, which is what makes agent and digital sales reconcile.
5. **Unnumbered inventory is a first-class mode.** Operators without a seat map sell `N` of `capacity`, enforced by a counter with the same locking. Seat selection is an operator capability flag, not an assumption baked into the domain (see product brief, risk table).
6. **Departure capacity can shrink.** A coach breaks down and is swapped for a 45-seater. The domain models this as a capacity change that produces a list of **displaced bookings** requiring explicit resolution (rebook / refund / upgrade) — it never silently drops tickets.
7. **Idempotent hold creation.** A retried hold request with the same idempotency key returns the *existing* hold, never a second one. A user on a flaky connection must not accumulate holds.

### Why not optimistic concurrency

Optimistic (version-check on commit) fails at the wrong moment: the traveller has already entered their mobile money PIN. Sending "sorry, that seat went" *after* a debit is the single worst experience this product can produce. We pay for correctness with a lock held for milliseconds.

## Consequences

Hold expiry is a visible product concern: the payment screen shows a live countdown and warns at 2 minutes. When a hold expires mid-payment the recovery is defined — if the payment then succeeds, the server re-attempts the hold and, if the seat is genuinely gone, auto-refunds and tells the user immediately in-app *and by SMS*. That path is rare, and it must be tested, because it is the one that generates the loudest complaints.
