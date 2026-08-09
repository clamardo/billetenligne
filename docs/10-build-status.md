# BilletEnLigne — Build Status

**Updated:** 2026-08-09 · after commit *Phase 1: the traveller app*

Updated on every push. Each row is either **done** — built, tested and green in
CI — or **in progress**, with what is actually missing named rather than
implied. Nothing is marked done because it compiles.

Legend: ✅ done · 🔨 in progress · ⬜ not started

---

## Phase 0 — Foundations

| Feature | State | Notes |
|---|---|---|
| Monorepo, Melos, pub workspace | ✅ done | 8 packages + 2 apps, one `dart pub get` |
| Layer-boundary check in CI | ✅ done | `tool/check_layers.dart`, 5 rules, 108 files |
| `bel_domain` — money, market, policies, state machines | ✅ done | Zero dependencies; DRC stood up entirely in test code |
| `bel_localization` — YAML catalogs, fr + en | ✅ done | Missing-key, orphan, placeholder and SMS-length guards |
| `bel_contracts` — wire format | ✅ done | Money is always `{minor, currency}` |
| `bel_crypto` — Ed25519, HMAC | ✅ done | Verified against the RFC 4231 vector |
| `bel_design` — Kilo tokens, three themes, components | ✅ done | 9 components, 58 tests; **gallery app still not built** |
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
| **Traveller app — browse and hold** | ✅ done | Onboardingless search → results → seat map → hold → release. 28 tests |
| `bel_client` — typed API client | ✅ done | Retries, idempotency keys, offline taxonomy. 17 tests |
| Traveller app — payment, tickets, history | ⬜ not started | Needs Phase 2 rails and the ticket issuing endpoint |
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
4. **Auth is a fake.** `FakeAuthGateway` resolves `fake:<id>` tokens, and the
   traveller app sends `fake:traveller` in debug builds only. The Firebase
   adapter behind the same port is not written. There is no sign-in screen, so
   every hold today belongs to the same demo user.
5. **The traveller app's city list is hardcoded** in `main.dart`. Congo's
   intercity network is genuinely this small, so it is harmless today and
   wrong to leave: a cities endpoint is the next small slice.
6. **The catalog is copied, not shared, into the apps.** `bel_localization` is
   pure Dart — the API imports it — so it cannot declare Flutter assets, and
   Flutter refuses `..` in asset paths. `tool/sync_i18n.sh` copies it and
   `i18n_freshness_test` fails the build if a copy drifts.
7. **Nothing writes to the ledger yet.** The tables, the balance trigger and
   the append-only grants are all in place and tested; no code posts an entry.

---

## How to verify any of this yourself

```bash
dart test packages services/api          # 272 unit tests
cd packages/bel_design && flutter test   # 58 component and contrast tests
cd apps/traveller && flutter test        # 28 app tests
cd apps/scanner && flutter test          # 20 scanner tests
dart run tool/check_layers.dart          # the onion rule, 108 files
./infra/migrations/check.sh              # 23 schema guarantees
./tool/integration.sh                    # 28 tests on real Postgres
./tool/smoke_api.sh                      # 44 checks, incl. the Dart client
```

**381 tests in total**, plus 44 smoke checks and 23 executed schema
guarantees. The smoke run now includes the *typed client* against the running
server — curl proves the HTTP surface, but only the client proves that the URL
it builds is the route dart_frog mounted and that the JSON parses into the DTOs
the screens render. Both halves of that seam have broken here before.

---

## What the last push changed, and what it cost

The traveller app went in, and with it the shared API client and the Kilo
component library. A person can now open the app, search Brazzaville →
Pointe-Noire, see real departures, pick a seat off a diagram and hold it, with
a countdown running. Payment is the next phase; the button says so rather than
opening a screen that apologises.

Three things the build found, each caught by a check rather than by review:

**The layer rule refused `ChangeNotifier`.** It lives in
`package:flutter/foundation`, and the application layer may not import Flutter.
The rule was right: a use case that needs the Flutter SDK cannot be tested with
`dart test`, cannot be reused by the console's web build without dragging the
framework in, and has inverted the dependency direction. `BookingFlow` is a
plain broadcast stream instead, and its 18 tests run in milliseconds.

**The recovery button on the error screen did nothing.** `backToSeatMap()`
derived the departure from the current step — and after a failure the step is
`StepFailed`, which carries no departure. So a traveller whose seat was taken
landed on an error screen whose only way forward was inert. The retry test
caught it; the flow now remembers the active departure independently of the
step.

**The countdown could not be tested at the moment that matters.** It read
`DateTime.now()` directly, and `tester.pump()` advances Flutter's timers but
not the wall clock — so in a test it counted down forever and the expiry
callback, the one that releases a seat, was never exercised. The clock is now
injectable. While fixing it, the formatter turned out to truncate rather than
round up, which meant a fifteen-minute hold opened at 14:59 and looked like it
was already leaking.

---

## What the previous push changed, and what it cost

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
