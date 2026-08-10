# BilletEnLigne — Build Status

**Updated:** 2026-08-10 · after commit *Logo upload, end to end*

Updated on every push. Each row is either **done** — built, tested and green in
CI — or **in progress**, with what is actually missing named rather than
implied. Nothing is marked done because it compiles.

Legend: ✅ done · 🔨 in progress · ⬜ not started

---

## Phase 0 — Foundations

| Feature | State | Notes |
|---|---|---|
| Monorepo, Melos, pub workspace | ✅ done | 7 packages, 2 services and 4 apps, one `dart pub get` |
| Layer-boundary check in CI | ✅ done | `tool/check_layers.dart`, 5 rules, 255 files |
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
| **`services/worker`** | ✅ done | Outbox drain, the payment poller, the sales horizon and three sweepers. Run-once, not a service |
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
| **Operator console — the app** | ✅ done | Flutter web. Fleet, routes, timetables, the dispatcher's day with its disruption form and its rescue-coach sheet, the guichet, manifests, refund terms and refunds — and, for somebody who belongs to no operator yet, the onboarding wizard instead of the console. 56 tests |
| Admin back office — API | ✅ done | `/admin/v1`: the queue, one operator's page, six lifecycle decisions, the negotiated commission. Every read and every write audited with actor and reason. 8 integration tests |
| **Admin back office — the app** | ✅ done | Flutter web. The review queue, one operator's file with its documents and trail, six lifecycle decisions, the negotiated commission, and the reconciliation queue. The reason lives in the frame and no write happens without one. 15 tests |
| **The vitrine** | ✅ done | Title, tagline, accent, header pattern and logo, with a live preview drawn by the real widgets — and the public storefront at `/public/v1/operators/{code}` |
| **The seat-layout section builder** | ✅ done | The coach no preset fits, drawn section by section, with `KSeatMap` — the widget that sells the seat — redrawn on every keystroke. Start rows are computed, not typed. `Abreast` in the domain now parses to null instead of throwing, which turned three 500s into field-named 400s. 8 domain · 5 contract · 6 widget tests, and 15 smoke checks on a real socket |
| **Object storage** | ✅ done | `ObjectStore` port, Azure Blob adapter over REST, and an in-memory one. What we accept is sniffed from the bytes; 40 KB / 512 px for a logo, refused with the number to get under rather than downscaled. 10 tests against real Azurite (`tool/storage.sh`), which caught a SAS signature that was wrong under sv=2020-10-02 |
| **Operator onboarding — the wizard** | ✅ done | Self-signup, §2.2. The application **is** the operator in its early lifecycle states, so the review queue, the audit trail and the six decisions all work unchanged. An applicant is a member of the public: INSERT on `operators` pinned by policy to `application_draft`, UPDATE granted on four columns, and the one transition they cause through a SECURITY DEFINER function that also writes the audit row. **Activation creates the `org_owner`** — the line that removes the phone call. Documents are declared, not photographed; the reason is a schema guarantee. 15 domain · 11 Postgres · 12 smoke · 7 console · 3 back-office tests |
| **Refund policy wizard** | ✅ done | Operators answer questions; `RefundPolicy.describe()` writes the sentences, in both languages, from the same numbers the server executes (ADR-0015 rule 3). Policies are append-only **by grant** — a booking stores `(policy_id, version)` at sale time and is judged by that version forever. Bands in the wrong order are refused, because tiers match in order and a shortest-first list silently answers everything with its most generous rate |
| **Scheduled materialisation** | ✅ done | A rolling 21-day sales horizon, extended by the worker rather than by a dispatcher remembering. Enumerates active patterns of active operators across every tenant under the worker's platform scope, then materialises each one back under its own tenant — so the pass sees everything and writes nothing outside the operator it is writing for. Idempotent by the same unique key the console's button relies on, so a run that half-finished is fixed by running it again. A backlog past the batch limit is reported in the pass name, never silently dropped. 6 Postgres tests |
| **Cash refunds** | ✅ done | Quote, approve, collect. Approval moves a debt rather than undoing a sale: the retained share stays credited to the operator. The ticket voids at approval, the seat goes back on sale in the same transaction, and the claim code is single-use by statement. `source` disbursement down a rail is **not** built and stops at `approved`. 5 domain · 8 Postgres · 12 smoke · 5 widget tests |
| Email on ACS | ✅ done | Signed requests, logging fallback; **only the sign-in code routes through it so far** |
| **A bound on codes per host** | ✅ done | The per-destination cooldown cannot see one host walking a list of a thousand addresses, and every one of those is a message we pay for. Thirty per hour per source, env-tunable, and **deliberately loose** — carrier-grade NAT means one address here is routinely one building, so this is a cost control before it is a security control. The address is never stored: an HMAC of it under the same key the codes are hashed with. The rightmost `X-Forwarded-For` hop, not the leftmost, because the leftmost is whatever the caller typed. 5 unit · 1 Postgres · 4 smoke tests |
| SMS / push on ACS + Firebase | 🔨 in progress | Port, templates, drain and channel plumbing all done; **no provisioned sender number, so the API refuses the phone channel with a 503**. What is no longer missing is the *switch*: `/public/v1/market` announces which channels the deployment can deliver on, the traveller app renders the option from that announcement, and a smoke check asserts the announcement and the route agree. The day a number is provisioned is a config push, not a release |
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
| **IRROPS — declaring, and telling everybody** | ✅ done | The dispatcher declares one of six kinds and everything downstream is derived: the departure's new status, the exemption on every booking, one message per passenger. All of it in **one transaction** — bookings marked involuntary with no declaration behind them is a refund entitlement nobody can account for. A disruption is **public** (the follower of a shared trip link holds no account and is exactly the person who otherwise phones the agency), **not editable afterwards** by a column-level grant, and **one open per departure** by a partial unique index, so "what is happening to my coach?" has one answer. A short delay entitles nobody to anything — the threshold is an hour, it lives in the domain, and the console asks it rather than restating it. 16 domain · 6 contract · 12 Postgres · 5 worker · 7 smoke · 6 console · 2 traveller tests |
| **IRROPS — the rescue coach** | ✅ done | Option ① of `08-disruption.md` §2.2: a different vehicle, the same journey. The seats are **remapped by the domain** — a passenger keeps their label only when the new coach has one of the same kind, because `1D` is a window on a 2+2 and the middle of the back block on a 2+3. Every ticket is **re-signed** in the same transaction as the new manifest, since the QR carries the seat (ADR-0007). A coach that cannot seat everybody is refused **with the number short**, so a dispatcher knows which coach to look for next. Holds with nothing behind them are released rather than slid onto a different seat under somebody who is looking at a seat map. The swap supersedes the breakdown that caused it. 9 domain · 2 contract · 6 Postgres · 5 smoke · 6 console tests |
| **IRROPS — the rebooking wave** | ✅ done | Option ② of `08-disruption.md` §2.2: the passengers go on the operator's own next departure. **Every replacement seat is taken before a single old one is released** (§2.4) inside one transaction, so a paid passenger never exists without a seat. **Partial coverage is a success** — "18 / 42" is what a dispatcher acts on, and refusing anything short of everybody would mean the tool only works on the days it is not needed. A party moves whole or not at all, in the order people booked, which is the only rule that can be said out loud to whoever is left. No fare difference, ever, even onto a dearer departure (ADR-0016). 13 domain · 2 contract · 13 Postgres · 2 worker · 5 smoke · 3 console tests |
| **Payout runs** | ✅ done | `04-payments.md` §6.2. Prepare · approve · release, and the gap between them is the control: **an operator cannot create, approve or edit their own payout**, by grant rather than by handler, and **the person who prepared a run cannot approve it**. The amount is the ledger's own balance (`payable:operator` less their tills) read again at release, never the sum of the statement's line items. Releasing debits the payable and credits every till plus the bank in one movement, which is what makes "cash sales never generate a payout" true in the books. A week of nothing but cash is negative — the operator owes us the fees — and is refused as a transfer. The back office works the queue — the whole statement is in the row, because the person approving is agreeing to a number — and the operator reads their own statements in the console, cash line included. 8 domain · 3 contract · 13 Postgres · 8 smoke · 2 schema guarantees · 5 back-office · 3 console tests |
| **`config/markets.yaml` is loaded** | ✅ done | ADR-0006, and the gap this document named first. The file is now the authority for the currency, the service fee, the dialling table and the rails; `Market.congoBrazzaville` is the **fallback** for when there is no file. A missing file falls back — that is every unit test and every fresh clone — and a **malformed one kills the process before it is healthy**, because an instance that comes up green serving last release's rails is the failure worth refusing. Enabling Orange Money, or a carrier renumbering, is a file and a restart. A currency whose exponent we do not know is refused by name, never guessed. 19 API tests · 7 smoke checks, two of them a second server started against a different file |
| IRROPS — protection, and the passenger's own choice | ⬜ not started | `08-disruption.md` §2.2 options ③ and ⑤: a standing inter-operator agreement (§5) with settlement through our ledger, and letting the passengers pick between the options themselves (§3.2). Both need something that does not exist yet — an agreement table, and a traveller-facing choice screen |

## Phase 3 and beyond

Not started. `09-roadmap.md` has the remaining Phase 1 work in **dependency
order**. With both consoles rendered, the vitrine complete, TOTP in front of
both back offices, object storage built, the section builder shipped and
refunds executing end to end, the sales horizon extending itself and an
operator able to sign themselves up, and the phone channel plumbed behind an
announcement, **every engineering item in Phase 1 is built.** What remains
there is commercial. Phase 2 is where the unbuilt work
lived: the re-accommodation plan, payout runs and the `config/markets.yaml`
loader are all built, and what is left there is a telco's sandbox becoming
production credentials, inter-operator protection, and the statement PDF.

---

## Known gaps worth naming

These are true today and each one is a decision, not an oversight.

1. **A rail enabled in the file still needs credentials to be collectable.**
   The loader exists and `config/markets.yaml` is the authority (see below),
   but two switches have to agree: the file says a rail is *offered*, and
   `ORANGE__CLIENTID` and its adapter say it can be *collected on*. That is
   deliberate — announcing a rail we hold no keys for would put a tile on the
   payment screen that takes a PIN and loses it — but it does mean switching
   on Orange Money for real is a config push **plus** an adapter, and only the
   first half is a one-line change today.
2. **`sweepExpired` throws `UnimplementedError` in the API's Postgres
   adapter.** Deliberate, and no longer a gap in the product: the sweep lives
   in `services/worker`, which exists and runs it under platform scope. The
   API refuses it because a request-scoped connection is the wrong place to
   walk the whole table, and the claim path already treats a lapsed hold as
   available — so no inventory is stranded either way. Every pass the worker
   owns now exists, including the one that *creates* — the sales horizon. What
   is missing is the last mile of deployment: a cron trigger in the
   environment that invokes `dart run bin/worker.dart` each night. Until that
   exists the passes are run by hand, and a night missed is a night nobody can
   book at the far edge of the window.
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
8. **A cover photo can be uploaded but has no control in the console.** The
   API takes one — same port, same sniffing, a bigger budget — and the
   storefront renders one when it is there. What is missing is the picker,
   and it is missing because the storefront was designed to look complete
   without a cover (`03-operator-lifecycle.md` §2.4: "a storefront that looks
   empty without one is a broken design"). Building a control for a field most
   operators will never fill was not worth the slice.
9. **Brand assets are capped rather than downscaled.** The spec asks for three
   raster sizes and a monochrome variant; what ships refuses anything over
   40 KB or 512 px instead. Re-encoding somebody's brand mark is a silent
   change to the one asset they care about most — a resample softens a
   wordmark, and a PNG round trip through a quantiser shifts the colour they
   chose — and the alternative was carrying an image decoder in an API process
   serving fourteen operators. It becomes a real gap when an operator arrives
   with a 2000 px logo they cannot re-export themselves.
10. **The section builder edits sections, not cells.** Rows, abreast, class,
   pitch and a per-section fare are all live, and the preview is the
   traveller's own seat map. What is not built is the *gesture* half of
   `06-fleet-and-routes.md` §3.3: tapping a cell to block it, placing a door
   or a lavatory, reordering sections, undo/redo. The storage format carries
   blocked seats and features already and everything downstream honours them,
   so a layout that has them sells correctly — there is simply no way to draw
   one in the console yet. Numbering is also chosen once for the whole layout
   rather than per section, which the model allows and no operator has asked
   for.
11. **A ticket lives only in memory on the device.** It renders offline once
   loaded — everything it needs travels inside the booking — but nothing is
   persisted, so a cold start with no network shows an empty list rather than
   yesterday's QR. Drift/SQLite on device is Phase 3, and until it lands
   "works offline" means "works offline while the app is alive".
12. **The catalog is copied, not shared, into the apps.** `bel_localization`
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
         packages/bel_contracts packages/bel_crypto     # 352 tests
dart test packages/bel_client                           # 32 tests
rm -rf services/api/build                               # see below — it matters
dart test services/api -x integration -x storage        # 196 tests
cd packages/bel_design     && flutter test  # 65 component and contrast tests
cd packages/bel_backoffice && flutter test  # 10 sign-in and enrolment tests
cd apps/traveller && flutter test        # 87 app tests
cd apps/console   && flutter test        # 62 console tests
cd apps/admin     && flutter test        # 23 back-office tests
cd apps/console   && flutter build web   # the console is a web build
cd apps/scanner && flutter test          # 20 scanner tests
dart run tool/check_layers.dart          # the onion rule, 300 files
./infra/migrations/check.sh              # 34 schema guarantees
./tool/integration.sh                    # 193 tests on real Postgres, incl. the worker
./tool/smoke_api.sh                      # 206 checks, incl. the Dart client
./tool/storage.sh                        # 10 tests against real Azurite
```

Remove `services/api/build` before counting: `dart_frog build` copies the
whole workspace into it, and `dart test services/api` then runs every suite
twice — and, worse, runs a *stale copy* of a package's tests, which is how a
green suite reported a failure in a file that no longer existed.

**847 tests in total**, plus 206 smoke checks, 34 executed schema guarantees,
193 further tests against real Postgres and 10 against real Azurite. The smoke run now includes the *typed client* against the running
server — curl proves the HTTP surface, but only the client proves that the URL
it builds is the route dart_frog mounted and that the JSON parses into the DTOs
the screens render. Both halves of that seam have broken here before.

That total read **1,091** in the previous revision of this document, and the
number was wrong rather than the suite. `dart test services/api` had been
counted with `services/api/build` present, so a stale copy of every package's
tests was counted again as if it were the API's own — the exact trap the
paragraph above warns about, walked into by whoever wrote the warning. Every
figure here has been re-measured from a clean tree.

---

## What the last push changed, and what it cost

`config/markets.yaml` is finally read by something. It was the first entry
under "known gaps" for a reason: the file was written carefully, commented at
length, and loaded by nothing at all.

**The file is the authority; the constant is the fallback.** The API used to
answer `/public/v1/market` from `Market.congoBrazzaville` compiled into the
binary, which made ADR-0006 a comment. Now it parses the file at startup and
serves that, and the constant is what runs when there is no file — a fresh
clone, a unit test, CI. That way round matters: nothing is ever rail-less on
first launch, and nothing that *is* configured is silently overridden by a
constant.

**A missing file falls back. A malformed one stops the process.** The
asymmetry is the whole design. Absent is a normal state. Present-and-wrong is
somebody's deliberate push, and the failure mode we must not have is a deploy
that reports success while serving the rails of the release before it — so the
market file is read in `main.dart`, before the socket opens, and a bad one
means the instance never becomes healthy, the rollout stops, and the previous
version keeps serving. The smoke suite proves both halves by starting a second
server on another port against a different file.

**The dialling table moved too, and that is the quieter half.** ADR-0005 has
always said carrier prefixes are configuration because operators renumber.
They were still a constant in three code paths: the number a traveller signs
in with, the wallet the payment screen pre-selects, and the settlement account
an operator registers in the console. All three now parse against the market's
table, so a renumbering is the same config push as a rail.

**A currency we do not know the exponent of is refused by name.** Not
defaulted to two, not skipped. XAF is zero-decimal and the exponent is what
decides whether 9 000 is nine thousand or ninety — the classic bug in this
market, and not one to guess past on the strength of a typo in a YAML file.

**The two definitions are checked against each other**, and the test earned
its keep on the first run: the compiled-in fallback was offering `cg.card` as
enabled while the file had it switched off. A fresh clone could tap a card
rail that no deployment would have shown it. That is exactly the drift a
fallback grows when nothing compares it to the thing it is falling back from.

**What it cost:** one `yaml` dependency, a loader in the API's infrastructure
layer, a `main.dart` that exists only to fail early, nineteen tests, seven
smoke checks — and `Market` losing `nameFr`/`nameEn` in favour of the catalog
key it should always have carried, since a market that enumerates languages is
a second place to edit when a third one arrives.

## What the payout screens push changed, and what it cost

The payout screens: the back office works the queue, and an operator reads
their own statements.

**The whole statement is in the row.** Not a summary with a link — the person
approving is agreeing to a number, and they should be able to check the sales,
the commission, the refunds and the drawer that produced it without navigating
anywhere. Both halves of the difference are printed, so the net can be
verified rather than trusted.

**Reading the queue needs `finance.read`; moving anything on it needs
`payout.approve`.** Our own analyst can answer "has Océan du Nord been paid?"
without holding the authority to pay them, and the buttons are inert rather
than absent so nobody wonders where they went.

**Approval is not payment, and the notice says so.** A confirmation that read
"approved" without adding "the money has not gone yet" is how a reviewer tells
an operator their transfer is on its way a day early. The release refuses
without a transfer reference, in the screen as well as at the server: a
transfer nobody can find in a bank statement afterwards is one that gets sent
twice.

**A week the operator owes us is not offered as a transfer at all** — no
greyed-out button, no payout with a minus sign. It reads as what it is, in
both consoles.

**The console statement prints the cash line and the drawer deduction.** Cash
is never paid out and appears anyway, with the sentence that answers the
question every operator asks first: you are already holding that money, and
only the service fees come off it.

**What it cost:** five back-office tests, three console tests, and one
`finance.read` tab that a vendor must never see.

## What the payout server push changed, and what it cost

The payout run, server side (`04-payments.md` §6.2). The ledger has been
correct since the first sale and nothing has ever taken money out of it: an
operator could see what we owed them and had no way to be paid it.

**An operator cannot pay themselves, by grant.** `bel_app` gets SELECT on
`payout_runs` and nothing else — no INSERT, no UPDATE, no column exception.
Two-person control on money leaving (ADR-0011) is worth nothing if the party
being paid can move the row that pays them, and a privilege holds against code
written next year by somebody who never read the migration. An executed schema
guarantee proves it rather than the file claiming it.

**Two people, not two roles.** The store refuses an approval by whoever
prepared the run. One super-admin pressing both buttons is a formality, and
this is the largest single movement of money the platform makes.

**The amount is the ledger's balance, not the sum of the statement.** The line
items describe the week and exist to be read and argued with; the money is
`payable:operator:<id>` less the operator's tills, read again at release. A
payout that summed a period would drift from the ledger the first time
anything landed a day late, and then two numbers would both claim to be the
debt.

**The drawers are settled in the same movement as the transfer.** An
operator's till is their asset that we have been carrying against what we owe
them, so releasing a payout debits the whole payable and credits every till
plus the bank. That is what makes "cash sales never generate a payout" true in
the ledger rather than only on the statement — and a week of nothing but cash
comes out *negative*, which is the operator owing us the service fees, refused
as a transfer and left as a conversation.

**What it cost:** a migration with four constraints and two executed
guarantees, thirteen tests against real Postgres, eight domain tests, and one
fixture that posts a rail capture directly — building a whole mobile-money
capture to produce three ledger rows would have tested the rail rather than the
run.

What is **not** built: the statement PDF, the admin screen that works this
queue, and the console screen where an operator reads their own statements.
The routes and the client methods exist; the screens are the next push.

## What the rebooking-wave push changed, and what it cost

The rebooking wave: when there is no spare coach, the passengers go on the
operator's own next departure. Option ② of `08-disruption.md` §2.2, and the
half of a disruption that moves people rather than informing them.

**Every replacement seat is taken before a single old one is released.** §2.4
states it and the transaction alone does not achieve it — the ordering inside
the loop is what keeps a paid passenger from existing, even for an instant and
even in a raise, without a seat on any coach at all. Both departures are locked
in id order first, because two dispatchers moving people between the same pair
of coaches in opposite directions is a deadlock, on exactly the morning it
would happen.

**Partial coverage is a 201, not a 409.** The 14:00 has eighteen seats and
forty-two people need one. Answering "18 / 42" is what lets a dispatcher take
the eighteen and go looking for a coach for the rest; refusing anything short
of everybody would mean the tool only works on the days it is not needed. The
console says the same number per candidate *before* the choice, so nobody does
that arithmetic in their head at a roadside.

**A party moves whole, in the order people booked.** Splitting a family across
two departures to make the arithmetic come out is not something anybody would
accept at a counter, and booking order is the only rule that can be said out
loud to whoever was left behind. First-fit rather than stop-at-the-first-that-
does-not-fit: a family of four blocking the last three seats must not strand
the eleven single travellers behind them.

**No fare difference, ever.** The fare each passenger paid is carried across
unchanged, even onto a dearer departure. That is ADR-0016 and it is the reason
`involuntary_change` exists at all.

**Found on the way:** the rescue coach's own `disruption.resolved` message had
no case in the outbox drain, so every one of those rows was being marked
delivered without being sent — the seat a passenger was moved to was written
down and never told to them. Both that and the new rebooking message are
composed now, and a worker test holds each.

**What it cost:** thirteen domain tests, thirteen more against real Postgres,
five smoke checks, and one fixture city (Oyo) so "a different road is a
different journey" could be tested against a road that exists.

## What the rescue-coach push changed, and what it cost

The rescue coach: a different vehicle, the same journey, everybody remapped
onto whatever seats it actually has. Option ① of `08-disruption.md` §2.2, and
the resolution a Congolese operator reaches for first — the spare, or a coach
pulled off a quieter duty.

**The remap is a domain rule, not a database update.** `remapSeats` keeps a
passenger's seat number when the new coach has one of the same kind, and
otherwise places them by how far they were down the coach and whether they had
a window. A 2+2 and a 2+3 both have a `1D`; on one it is a window and on the
other it is the middle of the back block, and handing somebody the same label
would be handing them a worse seat while telling them nothing changed.

**A coach that cannot seat everybody is refused, with the number short.** Not
"no": a dispatcher told "9 short" knows which coach to look for next. Seating
thirty-nine of forty-two would mean three people finding out at the door, and
there is nowhere to put them until the re-accommodation desk exists.

**Every ticket is re-signed.** The QR carries the seat (ADR-0007), so a swap
that moved somebody and left their ticket alone is a ticket the scanner
accepts for a seat the manifest gives to someone else. The old rows are
replaced inside the same transaction that writes the new manifest.

**Holds are released rather than moved.** Somebody mid-checkout on a coach
that has just been swapped loses their seat and chooses again — silently
sliding them onto a different one, while they are looking at a seat map that
says otherwise, is worse than telling them.

**The swap supersedes the breakdown that caused it.** "What is happening to my
coach right now?" answers with the resolution, not with the problem, because
the disruption row that is still open is the one the passenger's ticket shows.

**What it cost:** six more tests against real Postgres, five smoke checks, nine
domain tests for the remap alone, and one console row that had to become a
`Wrap` — three buttons on a disrupted departure overflowed the row at 1000 px,
which a widget test found and no amount of reading would have.

## What the disruption push changed, and what it cost

Disruption: a dispatcher declares one, and everybody on the coach is told.
`08-disruption.md` has existed since week one and nothing implemented a line
of it, which meant the most common event on this road network — a breakdown on
a Tuesday morning — had no representation anywhere in the system.

**One transaction, and the ordering inside it is the design.** Record the
declaration, supersede whatever was open, restate the departure, mark the
bookings, queue one message per passenger. The one that must never commit
alone is the fourth: bookings flagged `involuntary_change` with no declaration
behind them is a refund entitlement nobody can account for.

**A disruption is public.** `bel_public` may read one. The traveller whose
ticket it affects is the obvious reader; the one that decided the grant is the
*follower* of a shared trip link, who holds no account at all. Withholding why
a coach is late is precisely the behaviour that generates the phone calls this
removes, and there is nothing in the row that is not already being shouted
across a station forecourt.

**The declaration cannot be rewritten, by grant.** An operator may resolve one
and may not touch what they declared, when, or why. It is their own evidence
in a later dispute, and evidence its owner can edit is not evidence. Enforced
by a column-level GRANT rather than by a handler, so it holds against code
written next year by somebody who never read the migration.

**A short delay entitles nobody to anything.** Everything else is involuntary
and permanently exempt from fees; a coach fifteen minutes late is not a free
cancellation for everyone who booked it, because that would mean the operator
who *tells the truth about being late* pays for it. The threshold is an hour,
it lives in `bel_domain`, and the console asks it rather than restating it —
so the dispatcher sees what their declaration will cost while they are still
choosing the offset.

**The form is designed for a roadside, not for a desk.** Four large targets, a
cause, and nothing else required. The new time is picked in offsets, because
"+2 h" is one tap and a clock dialog in the rain is four taps and a mistake.

**Found on the way, and worth more than the feature: every outbound message
was rendering departure times in UTC.** `timestamptz` arrives in Dart as UTC,
so the booking confirmation SMS has been telling travellers that their 06:00
from Brazzaville leaves at 05:00 — for as long as that message has existed.
Times are now formatted by Postgres in the market's zone, which is where the
zone database actually is, and a worker test holds it there. This is the
second time a "small" formatting decision in this repository has turned out to
be a passenger-facing failure, and both were found by a test that rendered the
real string rather than asserting on a DateTime.

**What it cost:** two schema guarantees, seventeen more tests against real
Postgres, and a public grant that had to be argued for rather than assumed.
What is *not* built is the larger half — the re-accommodation plan, protection
on another operator, the passenger's own choice, the rebooking wave. Named in
the table above rather than implied by silence. (Seat remapping was on this
list when it was written; the push above built it.)

## What the logo push changed, and what it cost

Logo upload, and the object storage under it. The columns have been in the
schema since migration 0001 and nothing had ever written one, because a logo
needs somewhere to put a file.

**What we accept is decided by the bytes.** A `Content-Type` is a claim, and
this one decides what we later serve back to a browser — a caller who could
choose it could have a PNG served as `text/html`, which is how an image upload
becomes stored XSS. PNG, JPEG and SVG by magic number, with dimensions read out
of the PNG IHDR chunk and the JPEG frame header.

**A cap rather than a downscale, and that is a decision rather than a
shortcut.** Re-encoding somebody's brand mark is a silent change to the one
asset they care about most: a resample softens a wordmark and a PNG round trip
through a quantiser shifts the colour they chose. Refusing tells them, in the
screen where they can fix it, in the tool that made the file. It also keeps an
image decoder out of an API process serving fourteen operators. The gap this
leaves is named above.

A 40 KB PNG can still be 4000 px square — PNG compresses flat colour extremely
well — and decoding that is 64 MB of bitmap for a mark rendered at 32 dp. The
byte cap alone would not have caught it, which is why there is a pixel cap too.

**`publicUrl` and `signedUrl` are separate methods rather than one with a
flag.** A logo is on a poster and in a cached page, and a signature that
expires would break an image nobody was protecting; a KYB document must never
be readable by URL alone. A boolean argument in the wrong place would publish a
passport, so it is a property of the container instead.

**Azurite caught a bug review did not.** The service SAS string-to-sign carries
`signedEncryptionScope` from sv=2020-12-06 onward, and we were signing it under
2020-10-02. Azure answers that with a 403 and no indication of which of fifteen
lines was wrong. Worse: the first version of those tests ran against the
*public* container, where every one passed without a signature ever being
checked. They run against a private one now, which is the container the feature
exists for.

**The file dialog is a port.** There is no Flutter API for one, and the console
is the only surface that needs it — so `FilePicker` has a `package:web`
implementation in the app and a constant in the tests, and the vitrine screen
omits the upload control entirely when there is nothing behind it. A button
that opens nothing is worse than a sentence saying what the default is.

## What the push before that changed

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

## And the push before that

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

## Three pushes back

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

## Four pushes back

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

## Five pushes back

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

## Six pushes back

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

## Seven pushes back

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

## Earlier pushes

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
