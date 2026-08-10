# BilletEnLigne — Build Status

**Updated:** 2026-08-09 · after commit *The operator console, as an app*

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
| Postgres schema, RLS, ledger | ✅ done | 10 migrations, 26 executed guarantees |
| Public sales boundary (`bel_public`) | ✅ done | 0005 — a traveller cannot mark a seat sold, proven in `verify_public.sql` |
| Dart Frog skeleton, auth + idempotency middleware | ✅ done | 43 smoke checks over a real socket |
| `infra/dev` — Postgres, Firebase emulator, Azurite, Mailpit | ✅ done | `docker compose up`; `.env.example` connected as the wrong role until 0007 |
| Brand — mark, wordmark, four app icons | 🔨 in progress | SVGs done; **not yet installed into the Android/iOS icon sets** |

## Phase 1 — Cash-only pilot

| Feature | State | Notes |
|---|---|---|
| **Hold seats, end to end** | ✅ done | Route → use case → Postgres. 50-way race proven; 30 tests |
| Idempotency against the database | ✅ done | `ON CONFLICT DO NOTHING`; a refusal is never stored as the answer |
| **Release a hold** — `DELETE /public/v1/holds/{id}` | ✅ done | Scoped to the owner; releasing twice is a no-op |
| **`services/worker`** | ✅ done | Outbox drain plus three sweepers. Run-once, not a service |
| **Search** — `GET /public/v1/trips` | ✅ done | Open to anonymous; local-day correct; 14 unit + 14 integration tests |
| **Seat map** — `GET /public/v1/departures/{id}/seatmap` | ✅ done | Layout + live availability in one response, never cached |
| **Booking + cash payment** | ✅ done | Reserve → pay at agency → ledger → ticket, one transaction. 71 integration tests |
| **Double-entry ledger** | ✅ done | Chart of accounts in the domain; balance proven by the `ledger_txn_balances` view |
| **Ticket issue** | ✅ done | Issued inside the capture transaction, Ed25519-signed, under 300 bytes |
| Ticket delivery to the app | 🔨 in progress | Composed and queued by the outbox, drained by `services/worker`; **the traveller app has no ticket screen yet** |
| Boarding scanner (standalone app) | ✅ done | Camera, five verdicts, offline, debug simulator |
| **Traveller app — browse and hold** | ✅ done | Onboardingless search → results → seat map → hold → release. 45 tests |
| **Identity — sign in with an emailed code** | ✅ done | Challenge → Firebase custom token → ID token. Server, client and app. ADR-0024 |
| `bel_client` — typed API client | ✅ done | Retries, idempotency keys, offline taxonomy, Firebase session refresh. 32 tests |
| Traveller app — reserve and pay | ✅ done | Passenger names → payment code → agency. 54 app tests |
| Traveller app — tickets and history | ⬜ not started | The list endpoint exists; the screens do not |
| **Operator console — API** | ✅ done | Fleet, routes, timetables, materialisation, guichet, manifests |
| **Operator console — the app** | ✅ done | Flutter web. Fleet, routes, timetables, the dispatcher's day, the guichet, manifests. 11 tests |
| Admin back office | ⬜ not started | |
| Operator onboarding + approval queue | ⬜ not started | Designed in `03-operator-lifecycle.md` |
| Refund policy wizard + execution | ⬜ not started | Domain policy engine is built and tested |
| Email on ACS | ✅ done | Signed requests, logging fallback; **only the sign-in code routes through it so far** |
| SMS / push on ACS + Firebase | 🔨 in progress | Port, templates, drain and channel plumbing all done; **no provisioned sender number, so the API refuses the phone channel with a 503** |
| Session in platform secure storage | 🔨 in progress | `SessionStore` port is there; the app uses `MemorySessionStore`, so **a session lasts until the app is killed** |

## Phase 2 and beyond

Not started. `09-roadmap.md` has the remaining Phase 1 work in **dependency
order** — the operator console's app is now the top of it, and it is the only
thing between the current build and an operator selling a real seat.

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
4. **The refresh token is not persisted.** `BelSession` takes a `SessionStore`
   and the app hands it `MemorySessionStore`, so a session ends when the app
   is killed. The Keychain and the Android Keystore (ADR-0013) are a
   platform-channel dependency this app does not carry yet. Named in
   `main.dart` rather than hidden behind a default, because "you sign in again
   every launch" should be visible to a reviewer rather than discovered.
5. **Phone sign-in is plumbed and switched off.** The channel is a column, an
   enum and a switch; `sms.otp.body` is already in the catalog and already
   under the 160-character gate. What is missing is a provisioned ACS sender
   number, so `COMMS__SMSFROM` is blank and the API answers 503 for that
   channel rather than accepting it and leaving somebody waiting (ADR-0024).
6. **The console signs in with a one-time code, not a password and TOTP.**
   ADR-0013 specifies email + password + mandatory TOTP for back office. The
   deviation is documented in `apps/console/lib/src/presentation/sign_in.dart`
   and the reasoning is sequencing: today's console configures a fleet and
   sells a ticket, while settlement accounts, payout approval and refunds
   above a cap — the things that ADR protects — do not exist as endpoints at
   all. **TOTP lands before they do.** If refunds ship first, that comment is
   the bug report.

7. **The seat-layout section builder is not built.** Four presets cover what
   actually runs in Congo and picking one takes ninety seconds, which is the
   path most operators take anyway (`06-fleet-and-routes.md` §3.2). An
   operator whose coach matches no preset can adjust the row count and no
   more. Named on the screen rather than hidden behind a control that does
   nothing.
8. **A confirmed booking's ticket never reaches a screen.** It is issued,
   signed, stored and queued for SMS. The traveller app shows a payment code
   and then has nowhere to go: no ticket screen, no booking history. The
   endpoint (`GET /public/v1/bookings`) is there and typed in `bel_client`.

9. **The catalog is copied, not shared, into the apps.** `bel_localization` is
   pure Dart — the API imports it — so it cannot declare Flutter assets, and
   Flutter refuses `..` in asset paths. `tool/sync_i18n.sh` copies it and
   `i18n_freshness_test` fails the build if a copy drifts.
8. **Nothing writes to the ledger yet.** The tables, the balance trigger and
   the append-only grants are all in place and tested; no code posts an entry.

---

## How to verify any of this yourself

```bash
# One package at a time. `dart test packages services/api` in a single
# invocation fails to load about half the suites on this machine, and running
# them separately is also what melos does.
dart test packages/bel_domain packages/bel_localization \
         packages/bel_contracts packages/bel_crypto     # 218 tests
dart test packages/bel_client                           # 32 tests
dart test services/api -x integration                   # 131 tests
cd packages/bel_design && flutter test   # 58 component and contrast tests
cd apps/traveller && flutter test        # 54 app tests
cd apps/console   && flutter test        # 11 console tests
cd apps/console   && flutter build web   # the console is a web build
cd apps/scanner && flutter test          # 20 scanner tests
dart run tool/check_layers.dart          # the onion rule, 178 files
./infra/migrations/check.sh              # 26 schema guarantees
./tool/integration.sh                    # 71 tests on real Postgres, incl. the worker
./tool/smoke_api.sh                      # 72 checks, incl. the Dart client
```

Remove `services/api/build` before counting: `dart_frog build` copies the
whole workspace into it, and `dart test services/api` then runs every suite
twice and reports 414.

**525 tests in total**, plus 72 smoke checks and 26 executed schema
guarantees. The smoke run now includes the *typed client* against the running
server — curl proves the HTTP surface, but only the client proves that the URL
it builds is the route dart_frog mounted and that the JSON parses into the DTOs
the screens render. Both halves of that seam have broken here before.

---

## What the last pushes changed, and what they cost

Seven commits: identity, cities, money, the console's API, the worker, the
traveller's payment screen, and the console itself. **An operator can now put
a coach on a road and take cash for it without touching curl**, which is the
first time that has been true.

The first `flutter build web` earned its keep immediately. `bel_localization`
fingerprinted its catalog with 64-bit FNV-1a, which ran correctly on the
server, in the workers and under `dart test`, and which dart2js refuses
outright — an int is a double in JavaScript and `0xcbf29ce484222325` cannot be
represented exactly. That package is imported by the server *and* three
Flutter apps, one of which is now a web build, so the constraint is permanent
and there is a test asserting the hash width so it cannot come back.

## What the six before that changed

Six commits: identity, cities, money, the console's API, the worker, and
the traveller's payment screen. The build went from "a traveller can hold a
seat" to "an operator can put a coach on a road and take cash for it" —
except that the operator has to do it with curl, which is the whole of what
is left.

**The boundaries argued back three times, and each argument was worth
having.** Granting the traveller `stations` tripped `verify_public.sql`;
granting the identity role `operator_staff` tripped `verify_identity.sql`;
the sweeper had no grant on a table created after 0004's blanket one. None
was a mistake in the check — each was a real question about who may reach
what, and the answer is written into the verification rather than into a
commit message.

**Two bugs only a real database could produce.** `savePattern` re-read
through a method that opens its own transaction on its own pooled
connection, so it could not see its own uncommitted row and returned null
every time. `DbScope.platform('worker')` — the obvious thing to write —
fails on the first query, because `app_user_id()` casts that setting to
UUID.

**One bug only a real clock could produce**, again: the Firebase session's
expiry came from `DateTime.now()` inside the client, so the refresh test
could not reach the moment the token goes stale and passed green while
asserting nothing. Identical in shape to the hold countdown's, four commits
apart, in a different package.

## What the identity push changed, and what it cost

Identity. Before it, every hold in the system belonged to one demo user,
because there was no way to become a customer — and nothing downstream of
that could be built honestly.

**The channel reversed, and that is the interesting part.** ADR-0013 made the
phone number the identity; ADR-0018 put it behind Firebase's own phone OTP.
Neither is buildable this week: Firebase phone OTP needs a real billed
project, and we have no provisioned SMS sender, so any message we composed
would go nowhere. ADR-0018 already documents the way out — run the challenge
ourselves, deliver it on a rail we control, answer a correct code with a
Firebase *custom token* — and ADR-0019 asks us to build it early enough to
have the option. ADR-0024 writes down that we did, and that email leads.

Three things the build found:

**The resend button would have sent a code to a string of asterisks.** The
challenge DTO carries the address *masked* — `a***e@example.cg` — which is
right for the screen and useless as an argument. The screen was resending
from what it was rendering. From the traveller's side that failure looks
exactly like a delivery problem, which is the worst possible disguise for it.
The flow now remembers the real address and the screen cannot reach it.

**The Firebase session read the wall clock.** `expiresAt` came from
`DateTime.now()` inside the client rather than from an injectable clock, so
the refresh test could not reach the one moment worth testing — the instant
the token goes stale — and passed green while asserting nothing. This is the
same defect the hold countdown had, in a different file, four commits later.

**`.env.example` could never have worked.** `DATABASE_URL` connected as
`bel_app`, which is not a member of `bel_public` and cannot `SET LOCAL ROLE`
to it — so the traveller surface was unreachable for anyone who followed the
documented setup. It went unnoticed because the integration harness sets its
own URL, correctly, and nothing else had needed a signed-in request.

## What the previous push changed, and what it cost

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

## And the one before that

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
