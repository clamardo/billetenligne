# BilletEnLigne — Build Status

**Updated:** 2026-08-10 · after commit *TOTP on both back offices*

Updated on every push. Each row is either **done** — built, tested and green in
CI — or **in progress**, with what is actually missing named rather than
implied. Nothing is marked done because it compiles.

Legend: ✅ done · 🔨 in progress · ⬜ not started

---

## Phase 0 — Foundations

| Feature | State | Notes |
|---|---|---|
| Monorepo, Melos, pub workspace | ✅ done | 7 packages, 2 services and 4 apps, one `dart pub get` |
| Layer-boundary check in CI | ✅ done | `tool/check_layers.dart`, 5 rules, 248 files |
| `bel_domain` — money, market, policies, state machines | ✅ done | Zero dependencies; DRC stood up entirely in test code |
| `bel_localization` — YAML catalogs, fr + en | ✅ done | Missing-key, orphan, placeholder and SMS-length guards |
| `bel_contracts` — wire format | ✅ done | Money is always `{minor, currency}` |
| `bel_crypto` — Ed25519, HMAC | ✅ done | Verified against the RFC 4231 vector |
| `bel_design` — Kilo tokens, three themes, components | ✅ done | 10 components, 65 tests; **gallery app still not built** |
| Postgres schema, RLS, ledger | ✅ done | 11 migrations, 26 executed guarantees |
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
| Ticket delivery to the app | ✅ done | Issued, queued for SMS by the outbox, and rendered in the app: QR, live 30-second code, one ticket per seat |
| Boarding scanner (standalone app) | ✅ done | Camera, five verdicts, offline, debug simulator |
| **Traveller app — browse and hold** | ✅ done | Onboardingless search → results → seat map → hold → release. 45 tests |
| **Identity — sign in with an emailed code** | ✅ done | Challenge → Firebase custom token → ID token. Server, client and app. ADR-0024 |
| **TOTP on both back-office surfaces** | ✅ done | RFC 6238, proved against the RFC's own Appendix B vectors. Travellers are never asked; staff with nothing enrolled sign in and land on the enrolment screen and nowhere else. Replay refused by a conditional `UPDATE` on `last_window`, and three simultaneous identical codes produce one sign-in. Shared by both apps via `bel_backoffice`. 22 unit · 15 vector · 17 integration · 10 widget tests |
| `bel_client` — typed API client | ✅ done | Retries, idempotency keys, offline taxonomy, Firebase session refresh. 32 tests |
| Traveller app — reserve and pay | ✅ done | Passenger names → payment code → agency. 54 app tests |
| **Traveller app — tickets and history** | ✅ done | Upcoming and past, unpaid reservations included with their code. The QR and its rotating secret travel inside the booking, so opening a ticket costs no request. 11 flow and widget tests |
| **Operator console — API** | ✅ done | Fleet, routes, timetables, materialisation, guichet, manifests |
| **Operator console — the app** | ✅ done | Flutter web. Fleet, routes, timetables, the dispatcher's day, the guichet, manifests. 11 tests |
| Admin back office — API | ✅ done | `/admin/v1`: the queue, one operator's page, six lifecycle decisions, the negotiated commission. Every read and every write audited with actor and reason. 8 integration tests |
| **Admin back office — the app** | ✅ done | Flutter web. The review queue, one operator's file with its documents and trail, six lifecycle decisions, the negotiated commission, and the reconciliation queue. The reason lives in the frame and no write happens without one. 15 tests |
| **The vitrine** | 🔨 in progress | Title, tagline, accent and header pattern, with a live preview drawn by the real widgets — and the public storefront at `/public/v1/operators/{code}`. **Logo upload is not built**: it needs object storage, which is its own slice |
| Operator onboarding — the wizard | ⬜ not started | `03-operator-lifecycle.md` §2.2. The first ten operators are onboarded by hand, which is what the queue is for |
| Refund policy wizard + execution | ⬜ not started | Domain policy engine is built and tested |
| Email on ACS | ✅ done | Signed requests, logging fallback; **only the sign-in code routes through it so far** |
| SMS / push on ACS + Firebase | 🔨 in progress | Port, templates, drain and channel plumbing all done; **no provisioned sender number, so the API refuses the phone channel with a 503** |
| Session in platform secure storage | 🔨 in progress | `SessionStore` port is there; the app uses `MemorySessionStore`, so **a session lasts until the app is killed** |

## Phase 2 — Mobile money

| Feature | State | Notes |
|---|---|---|
| **Airtel Money adapter** | ✅ done | USSD push, against the real contract. Own transaction id, headers for country/currency, national MSISDN |
| **MTN MoMo adapter** | ✅ done | `requesttopay`, keyed on the `X-Reference-Id` we generate |
| **Fake rail** | ✅ done | Every terminal state plus a declining number. ADR-0005 makes this a release gate, not a convenience |
| **Payment intents + state machine** | ✅ done | `indeterminate` first-class; illegal transitions refused; every answer written to `payment_events` |
| **Traveller payment experience** | ✅ done | Wallet, payer number, confirmation, waiting, receipt, refusal, unresolved. 13 flow tests |
| **Operator collection accounts** | ✅ done | Per rail, saved unverified, replacing deactivates rather than edits |
| **Callback endpoint** | ✅ done | Body trusted only to select a row; state always re-queried. Answers 200 to everything |
| **Payment poller** | ✅ done | Backoff from the domain; 15 min of silence becomes `indeterminate` |
| **Commission, per operator** | ✅ done | `CommissionTerm` in basis points, read from `operators.commission_bps` when a fare settles. Netted at source; unreadable terms keep nothing rather than guess |
| Production credentials | ⬜ not started | **Commercial, not engineering.** Both adapters run against sandbox hosts |
| `indeterminate` reconciliation — API | ✅ done | The queue, joined to the booking, the operator and the traveller's number. Three exits: ask the rail again · captured · failed. 5 integration tests |
| **`indeterminate` reconciliation — the screen** | ✅ done | In the back office. Longest-waiting first, everything needed to decide in the row, three exits — and captured/failed demand a sentence about *that* payment, which becomes the `payment_events` row |
| Payout runs and operator statements | ⬜ not started | `payable:operator:<id>` is correct and derived; nothing pays it out |
| IRROPS / disruption tooling | ⬜ not started | P0 for this phase (`08-disruption.md`) |

## Phase 3 and beyond

Not started. `09-roadmap.md` has the remaining Phase 1 work in **dependency
order**. With both consoles rendered, the vitrine shipped and TOTP in front of
both back offices, the top of it is the object storage a logo upload needs —
the same plumbing a KYB document scan will want — followed by the seat-layout
section builder, the refund policy wizard and a scheduler for the worker.

---

## Known gaps worth naming

These are true today and each one is a decision, not an oversight.

1. **`config/markets.yaml` is loaded by nothing.** The API still reads the
   compiled-in `Market.congoBrazzaville`. Until the loader exists, enabling
   Orange Money needs a release rather than a config push — which is exactly
   what ADR-0006 says it should not need.
2. **`sweepExpired` throws `UnimplementedError` in the API's Postgres
   adapter.** Deliberate, and no longer a gap in the product: the sweep lives
   in `services/worker`, which exists and runs it under platform scope. The
   API refuses it because a request-scoped connection is the wrong place to
   walk the whole table, and the claim path already treats a lapsed hold as
   available — so no inventory is stranded either way. What is missing is a
   *scheduler*: nothing runs the worker on a timer yet.
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
6. **Operator onboarding still starts outside the product.** The back office
   can now decide an application, but nothing *creates* one: the first row in
   `operators` arrives by SQL, and the wizard of `03-operator-lifecycle.md`
   §2.2 is not built. That is deliberate for the first ten operators — they
   are onboarded in a room, and the queue is what makes the decision
   auditable afterwards — and it stops being acceptable the moment an
   eleventh applies without a phone call.
7. **Back-office sign-in is an emailed code plus TOTP, not a password plus
   TOTP.** ADR-0013 specifies email + password + mandatory TOTP; the
   authenticator half now exists on both surfaces and the password half does
   not. That is a narrowing rather than a closing, and the argument for it is
   that a password on top of a one-time code adds a secret to phish rather
   than a factor to hold — the two things somebody would have to compromise
   are already an inbox and a device. Three smaller edges of the same gap,
   each stated rather than buried:
   **enrolment is compulsory on next sign-in rather than retroactive**, so an
   account that never signs in again keeps no factor;
   **the TOTP seed is not encrypted at rest** — a KMS key living in the same
   environment as the database is reassurance rather than a control;
   and **there is no QR code** on the enrolment screen, because a QR encoder
   is a few hundred lines of Reed–Solomon with no independent decoder here to
   check it against, and a bug in one would ship as a code that scans cleanly
   and produces a factor that never matches. The setup key is typed instead,
   in groups of four, which every authenticator app accepts.
8. **The seat-layout section builder is not built.** Four presets cover what
   actually runs in Congo and picking one takes ninety seconds, which is the
   path most operators take anyway (`06-fleet-and-routes.md` §3.2). An
   operator whose coach matches no preset can adjust the row count and no
   more. Named on the screen rather than hidden behind a control that does
   nothing.
9. **A ticket lives only in memory on the device.** It renders offline once
   loaded — everything it needs travels inside the booking — but nothing is
   persisted, so a cold start with no network shows an empty list rather than
   yesterday's QR. Drift/SQLite on device is Phase 3, and until it lands
   "works offline" means "works offline while the app is alive".
10. **The catalog is copied, not shared, into the apps.** `bel_localization`
   is pure Dart — the API imports it — so it cannot declare Flutter assets,
   and Flutter refuses `..` in asset paths. `tool/sync_i18n.sh` copies it and
   `i18n_freshness_test` fails the build if a copy drifts.

---

## How to verify any of this yourself

```bash
# One package at a time. `dart test packages services/api` in a single
# invocation fails to load about half the suites on this machine, and running
# them separately is also what melos does.
dart test packages/bel_domain packages/bel_localization \
         packages/bel_contracts packages/bel_crypto     # 240 tests
dart test packages/bel_client                           # 32 tests
dart test services/api -x integration                   # 584 tests
cd packages/bel_design     && flutter test  # 65 component and contrast tests
cd packages/bel_backoffice && flutter test  # 10 sign-in and enrolment tests
cd apps/traveller && flutter test        # 80 app tests
cd apps/console   && flutter test        # 15 console tests
cd apps/admin     && flutter test        # 15 back-office tests
cd apps/console   && flutter build web   # the console is a web build
cd apps/scanner && flutter test          # 20 scanner tests
dart run tool/check_layers.dart          # the onion rule, 248 files
./infra/migrations/check.sh              # 27 schema guarantees
./tool/integration.sh                    # 111 tests on real Postgres, incl. the worker
./tool/smoke_api.sh                      # 113 checks, incl. the Dart client
```

Remove `services/api/build` before counting: `dart_frog build` copies the
whole workspace into it, and `dart test services/api` then runs every suite
twice — and, worse, runs a *stale copy* of a package's tests, which is how a
green suite reported a failure in a file that no longer existed.

**1,061 tests in total**, plus 113 smoke checks, 27 executed schema guarantees
and 111 further tests against real Postgres. The smoke run now includes the *typed client* against the running
server — curl proves the HTTP surface, but only the client proves that the URL
it builds is the route dart_frog mounted and that the JSON parses into the DTOs
the screens render. Both halves of that seam have broken here before.

---

## What the last push changed, and what it cost

TOTP, in front of both back offices. It was item 2 on the roadmap and it was
taken ahead of item 1: logo upload needs object storage that does not exist
yet, while this is a control on a surface that is live and reaches across
every tenant, and it needed nothing that was not already here.

**The RFC's own vectors came before the flow.** RFC 6238 Appendix B, against
real HMAC-SHA1, written and green before a single route existed. A base32
alphabet off by one character or a window computed from local time fails
there rather than on the first vendor's phone — and neither of those is
visible in a test that checks its own arithmetic against itself.

**Travellers are never asked, and the line is drawn from the database.** A
second factor in front of a coach ticket is a barrier whose whole reward is
protecting one person's own bookings. Operator staff and platform staff are
asked; everybody else is not; and the decision is read from `operator_staff`
and `platform_staff` rather than from anything a client sends.

**Enrolment is not enforced by refusing to sign in.** That would have locked
out every existing staff account the hour it shipped, including the people who
would have to fix it. Staff with nothing enrolled get a real session and land
on the enrolment screen and nowhere else. It is the honest reading of
"mandatory" for a rollout, and it is stated in the use case rather than
discovered in the behaviour.

**The half-session is a signed claim, not a row.** Between "the emailed code
was right" and "the authenticator code was right" there is a caller we have
half-authenticated. Five minutes, single-purpose, worthless without a code the
holder still has to compute — so a table to remember it would buy nothing but
a table. What it must not be is forgeable, which is what the HMAC and the
constant-time compare are for.

**Two defects the tests found, not review.** `beginEnrolment` deleted retired
recovery codes, but `bel_identity` is deliberately granted no `DELETE` there —
a burned code is evidence. Retirement became `superseded_at`, and a schema
check now asserts that column exists precisely because the missing grant
depends on it. And a successful recovery code cleared the lock in the memory
adapter but not in Postgres, which would have left somebody who *proved*
themselves with a recovery code still locked out — in the one situation
recovery codes exist for.

**`bel_backoffice` is a new package, and the reason is the control rather than
tidiness.** The console and the admin app had near-identical sign-in screens
already; adding a second factor to each would have made two implementations of
one security control, and two chances for one of them to forget the enrolment
gate. It takes a translate function rather than reading an inherited scope,
because the Flutter half of the catalog lives in each app — `bel_localization`
is pure Dart so the API can read the same YAML from disk.

**The console and back-office widget tests were running nowhere.** They were
listed only under `melos test:apps`, and nothing in the CI workflow installs
melos. Both are now named steps, as is the new package.

## What the push before that changed

The vitrine. The columns have been in the schema since migration 0001 and
nothing had ever read or written one of them.

**The live preview is the whole point of the screen.** The right-hand pane
renders the real widgets — storefront hero, search row, ticket band — from the
form's own state, so an operator sees what a customer will see before saving.
It cannot lie about the result because it is not a second implementation of
it, which is the ADR-0004 bet paying its rent rather than being restated.

**Every bound is refused server-side, not merely absent from the UI.** Eight
accents, three patterns, 30 characters of title and 60 of tagline. An unknown
accent is a 400 naming the field rather than a quiet fallback to the house
green — a storefront rendered in a colour nobody asked for is a support call
nobody can reproduce. The closed lists live in `bel_contracts`, because the
server is what refuses a ninth hue and the server cannot import Flutter.

**`KChip` overflowed instead of narrowing.** A trip card at 360 dp — the
reference phone — broke its row on a spelled-out seats label. The French
string fits and the English one is a third longer, so this was a row that
breaks in the language we test least. Found by putting the real search row
into the preview pane at a phone's width, which no test had done before.

**A storefront must not outlive the right to sell.** It resolves through the
public role, whose policy is already `app_is_public() AND status = 'active'`,
so a suspended operator's page stops existing because the database stops
returning the row. There is no status clause in the adapter, and the test
proves it by suspending an operator rather than by reading the SQL.

Logo upload is not built and is named on the screen rather than hidden behind
a control that does nothing. Until it lands, an operator gets a generated
monogram in their accent — which is the documented default anyway.

## And the push before that

The back office is an app. `/admin/v1` had been complete for two pushes and
nothing rendered any of it — the queue, six decisions, the commission and the
reconciliation exits all existed and could only be reached with curl.

**The reason field is in the frame, not in the dialog.** The server refuses a
mutation without one and records it against the actor on every read
(ADR-0011). A prompt that appears at the moment of confirming is a prompt
people learn to type "review" into; a field attached to the whole session is
one somebody fills in once, and can see while they work. Both consoles now
demonstrate the same thing about audit: it is a design constraint on the
screen, not a column on a table.

**No evidence, no exit.** Declaring a payment captured or failed demands a
sentence about *that* payment, separate from the standing reason, and the
confirm button does not exist until there is one. It becomes the
`payment_events` row that settles a dispute six weeks later.

**The lifecycle table moved into `bel_contracts`.** The buttons the screen
offers are now exactly the transitions the server's SQL guard allows. The
server is still the authority — `WHERE status = ANY(@from)` is unchanged —
but the courtesy of greying a button can no longer drift into a lie.

**`NavigationRail` asserts on zero destinations.** A `viewer` holds neither
capability this app is built from, so the first thing one of our own people
with that role would have met is a crash. Found by the test that checks the
rail is built from capabilities, which is the second time that property has
caught something the screenshot would not have.

Two smaller things fell out: `BelHeaders.reason` now spells `X-Bel-Reason`
once for client and server both, and `melos run test:apps` puts the three
Flutter surfaces into `verify` — the traveller and console suites were green
and ungated, which is a suite waiting to rot.

## Three pushes back

The reconciliation queue has an exit. ADR-0005 asks for this screen *before*
launch rather than after the first incident, and half of it now exists: the
queue is a real query and its three resolutions are real transactions.

**A capture resolved by a human settles through the same code a rail's answer
takes** — ledger, this operator's commission, ticket, outbox. A booking
confirmed by an admin and one confirmed by MTN must be indistinguishable
afterwards, because in the ledger they are.

**Only two exits, checked by the domain's own table.** An indeterminate
intent resolves to captured or failed and nowhere else, and the admin path is
refused by exactly the rule a callback is. Marking one `expired` to tidy the
queue does nothing, and the test says so.

**`payment_events` has a vocabulary and it was right.** The first draft wrote
`admin:<uuid>` as the source and the CHECK constraint refused it. Four
greppable sources beat a string somebody has to parse — so the row is
`manual` and the body names who decided and why, as data.

## And the one before

The back office, server side. `/admin/v1` — the third surface, promised in
`02-architecture.md` since the first commit and until now entirely absent.

**`platform_staff` had never been read.** The table has existed since
migration 0001, `PlatformScope` since the first middleware, three platform
roles since `capability.dart` — and nothing anywhere resolved a bearer token
to any of them. `Principal.isPlatform` was false for every request this
system has ever served. Migration 0012 grants the identity surface SELECT on
that one table, and asserts in `verify_identity.sql` that no running surface
can *write* it: a service that can appoint its own administrators makes every
other control decorative.

**Authority is checked before paperwork.** The reason header is mandatory on
every mutation, but a traveller who finds the URL gets a 403 and learns
nothing about it. The first draft asked for the reason first, which told a
stranger there was a header worth sending.

**A decision and its audit row are one transaction**, and the transition is
conditional in SQL as well as in Dart. Two reviewers approving one
application at the same moment produce one approval and one trail entry —
proven with two concurrent calls against real Postgres rather than asserted.

**Reads are audited too.** Opening one operator's file writes a row with the
actor, the subject and the stated reason, because "who looked at Ocean du
Nord's revenue, and why" is a question asked after the fact.

## And before that

The ticket reaches a screen. Until this push the product could take
somebody's money, sign a ticket, store it and text it — and the app that
took the money had nowhere to show it. `travel.reserved.afterPayment`
said "once paid, your ticket appears here with its QR code", and it did
not.

**The server was quietly the larger half.** `GET /public/v1/bookings`
mapped `tickets: const []` — a literal empty list — so the endpoint the
roadmap called "built and typed in `bel_client`" could never have
rendered a ticket. `IssuedTicket` carried no rotating secret and no
issue time, and `_readTickets` did not select them. Nothing was wrong
with the plan; the last twenty percent of it had not been written.

**The rotating secret goes to the device, deliberately.** A signature
proves a ticket is authentic and says nothing about who is holding it —
a screenshot of a friend's QR scans perfectly. The six digits under the
QR are what kills that, and the device can only compute them if it has
the seed. It travels in a `private, no-store` response and nowhere else.

**The QR is black on white in every theme.** Dark mode inverts a code
into something many cheap scanners refuse, and the conductor's handset
is exactly that scanner.

**The fake rail never settled.** It answered `unknown` forever in the
in-memory composition, so a fresh clone could start a payment and never
reach a confirmed booking, a ticket or a QR — the whole reason the fake
exists. It now settles on the second poll, and six smoke checks walk
prompt → poll → capture → ticket over a real socket with no credentials.

## Earlier pushes

Mobile money, end to end — the part that sells this product.

Two adapters written against the real APIs rather than from memory, and
they disagree in ways that matter: MTN keys everything on a reference we
generate, Airtel mints its own and wants the *national* number where we
store E.164. Sending the stored form is a subscriber-not-found that looks,
in every log, like the traveller mistyped their own number.

**The confirmation screen is a separate step**, and that is the whole
argument: amount, wallet, the number the money leaves, the number it
arrives at, and the operator's name beside it — all checkable before
anything irreversible. **The payer number is not the traveller's**, because
somebody whose wallet is empty pays from a relative's. **Never "failed"
when we do not know**, because the money may have moved.

One thing the work found: the compiled-in market rail list was gating which
rails could be offered, which defeats the entire point of ADR-0006's
server-driven list. A rail this deployment can reach, that the operator has
a verified account on, is now offered whether or not a constant in the
binary mentions it.

## What the seven before that changed

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
