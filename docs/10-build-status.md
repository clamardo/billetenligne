# BilletEnLigne — Build Status

**Updated:** 2026-08-09 · after commit *Phase 1: the browse path*

Updated on every push. Each row is either **done** — built, tested and green in
CI — or **in progress**, with what is actually missing named rather than
implied. Nothing is marked done because it compiles.

Legend: ✅ done · 🔨 in progress · ⬜ not started

---

## Phase 0 — Foundations

| Feature | State | Notes |
|---|---|---|
| Monorepo, Melos, pub workspace | ✅ done | 7 packages, one `dart pub get` |
| Layer-boundary check in CI | ✅ done | `tool/check_layers.dart`, 5 rules, 81 files |
| `bel_domain` — money, market, policies, state machines | ✅ done | Zero dependencies; DRC stood up entirely in test code |
| `bel_localization` — YAML catalogs, fr + en | ✅ done | Missing-key, orphan, placeholder and SMS-length guards |
| `bel_contracts` — wire format | ✅ done | Money is always `{minor, currency}` |
| `bel_crypto` — Ed25519, HMAC | ✅ done | Verified against the RFC 4231 vector |
| `bel_design` — Kilo tokens, three themes | 🔨 in progress | Tokens and contrast gates done; **component library and gallery app not built** |
| Postgres schema, RLS, ledger | ✅ done | 6 migrations, 23 executed guarantees |
| Public sales boundary (`bel_public`) | ✅ done | 0005 — a traveller cannot mark a seat sold, proven in `verify_public.sql` |
| Dart Frog skeleton, auth + idempotency middleware | ✅ done | 43 smoke checks over a real socket |
| `infra/dev` — Postgres, Firebase emulator, Azurite, Mailpit | ✅ done | `docker compose up` |
| Brand — mark, wordmark, four app icons | 🔨 in progress | SVGs done; **not yet installed into the Android/iOS icon sets** |

## Phase 1 — Cash-only pilot

| Feature | State | Notes |
|---|---|---|
| **Hold seats, end to end** | ✅ done | Route → use case → Postgres. 50-way race proven; 30 tests |
| Idempotency against the database | ✅ done | `ON CONFLICT DO NOTHING`; a refusal is never stored as the answer |
| **Release a hold** — `DELETE /public/v1/holds/{id}` | ✅ done | Scoped to the owner; releasing twice is a no-op |
| Expiry sweeper | 🔨 in progress | `claim()` already treats a lapsed hold as available, so nothing is stranded; **`services/worker` does not exist** |
| **Search** — `GET /public/v1/trips` | ✅ done | Open to anonymous; local-day correct; 14 unit + 14 integration tests |
| **Seat map** — `GET /public/v1/departures/{id}/seatmap` | ✅ done | Layout + live availability in one response, never cached |
| Booking + cash payment | ⬜ not started | |
| Ticket issue + QR delivery | 🔨 in progress | Payload, signing, verification and rotating code all done and tested; **no issuing endpoint** |
| Boarding scanner (standalone app) | ✅ done | Camera, five verdicts, offline, debug simulator |
| Traveller app | ⬜ not started | **Next.** Every endpoint it needs to browse and hold now exists |
| Operator console | ⬜ not started | |
| Admin back office | ⬜ not started | |
| Operator onboarding + approval queue | ⬜ not started | Designed in `03-operator-lifecycle.md` |
| Refund policy wizard + execution | ⬜ not started | Domain policy engine is built and tested |
| SMS / push on ACS + Firebase | ⬜ not started | |

## Phase 2 and beyond

Not started. See `09-roadmap.md`.

---

## Known gaps worth naming

These are true today and each one is a decision, not an oversight.

1. **`config/markets.yaml` is loaded by nothing.** The API still reads the
   compiled-in `Market.congoBrazzaville`. Until the loader exists, enabling
   Orange Money needs a release rather than a config push — which is exactly
   what ADR-0006 says it should not need.
2. **`sweepExpired` throws `UnimplementedError` in the Postgres adapter.**
   Deliberate: it belongs to `services/worker`, which does not exist yet, and
   the claim path already treats a lapsed hold as available — so no inventory
   is stranded by its absence. It is a missing optimisation, not a missing
   guarantee.
3. **Search has no pagination and a hard `LIMIT 100`.** One route on one day
   will not approach it. It becomes a real gap the moment the console can
   create a hundred departures, and it is a silent truncation until then —
   which is exactly the kind of cap worth writing down rather than discovering.
4. **Auth is a fake.** `FakeAuthGateway` resolves `fake:<id>` tokens. The
   Firebase adapter behind the same port is not written. The demo token exists
   only when `DATABASE_URL` is unset, so it cannot reach a real database.
5. **Nothing writes to the ledger yet.** The tables, the balance trigger and
   the append-only grants are all in place and tested; no code posts an entry.

---

## How to verify any of this yourself

```bash
dart test packages services/api      # 255 unit tests
dart run tool/check_layers.dart      # the onion rule, 81 files
./infra/migrations/check.sh          # 23 schema guarantees
./tool/integration.sh                # 28 tests on real Postgres
./tool/smoke_api.sh                  # 43 checks over a real socket
```

---

## What the last push changed, and what it cost

The browse path went in: search, seat map, and releasing a hold. Two things
are worth recording because they were not planned.

**The grant list refused a query, and it was right to.** The search join
reached `vehicles` for the transport mode and the amenity list. Postgres said
`permission denied`, because migration 0005 deliberately gives the traveller
no access to a table that also carries registration plates and
`status = 'blocked_compliance'`. Granting the whole table to reach two columns
would have been the wrong trade, so 0006 captures both onto the departure —
the same pattern `seat_layout_id` already follows, and one fewer join on the
hottest read in the product. The boundary paid for itself the first week it
existed.

**The timezone is a parameter, not a literal.** "Departures on the 15th" is a
local-day question; a UTC comparison puts the 06:00 coach on the wrong day.
The integration tests ask *Postgres* what the local date is rather than
deriving it in Dart, because a test that derives it agrees with the query by
sharing its bug.
