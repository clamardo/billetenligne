# ADR-0003 — Offline-first with SQLite (Drift) as the source of truth for the UI

**Status:** Accepted · **Date:** 2026-08-09

## Context

Congo network reality: intermittent 3G, dead zones on the RN1 between Brazzaville and Pointe-Noire, prepaid data users who run out mid-session. A conductor at a roadside stop may have **no** connectivity at boarding time. Data costs money and users notice.

Losing a ticket because the app couldn't reach the server is an unacceptable failure.

## Decision

**The UI never reads from the network directly.** It reads from a local Drift (SQLite) database. The network's job is to *populate* that database.

```
UI  ──watch──▶  Drift (single source of truth)
                  ▲
                  │ upsert
             Repository ──▶ API (when online)
                  │
                  └──▶ Outbox (when offline / on failure)
```

Rules:

1. **Read path:** repositories return `Stream<T>` from Drift. Network refresh is a side effect that writes into Drift; the stream re-emits. Screens have no "loading vs cached" branching — they render whatever is local and show a subtle staleness indicator.
2. **Write path:** an **outbox table**. Mutations are persisted as intents with an idempotency key, then drained by a background worker with exponential backoff. Applies to: booking cancellation, profile edits, boarding scan records, analytics.
3. **Payments are NOT in the outbox.** A payment must never be replayed by a background worker. Payment initiation requires connectivity and returns a server-issued `payment_intent_id`; recovery is a *status poll*, never a re-send. See `04-payments.md` §5.
4. **Tickets are cached in full, forever** (until departure + 30 days), including the signed QR payload and the issuer public key. A ticket must render in airplane mode.
5. **Boarding validation is fully offline.** The conductor's device holds the manifest for its departures plus the issuer public key; verification is a signature check + local redemption log, synced later. See ADR-0007.
6. **TTL policy per entity**, explicit, in one file: routes 7 d, trips/schedules 15 min, seat availability 60 s (and never trusted for confirmation — the server re-validates at hold time), tickets ∞.

### Data frugality

- ETag / `If-None-Match` on every GET; a 304 costs ~200 bytes.
- Delta sync for schedules (`?since=`), never full dumps.
- Gzip/br required; JSON field names shortened on the highest-volume endpoints only.
- Optional **Mode économiseur de données**: suppresses operator logos and prefetch.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Hive / Isar** | Fast, but weak relational queries; seat maps and manifests are relational. Isar's maintenance story is uncertain. Rejected. |
| **Network-first with a memory cache** | Simplest, and wrong for this market. Rejected. |
| **PowerSync / Firestore offline** | Real offline sync out of the box, but vendor lock-in on the *inventory* — the one thing we must control — plus cost at scale in a low-ARPU market. Rejected. |

## Consequences

Every feature pays a mapping tax (API DTO → Drift row → entity). In exchange the app is usable on a dead network, which is a headline feature in this market, not an edge case. Schema migrations become a first-class concern: Drift migrations are versioned and tested with `drift_dev`'s schema verification from day one.
