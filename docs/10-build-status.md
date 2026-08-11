# BilletEnLigne — Build Status

**Updated:** 2026-08-11 · after commit *Every row carries its own price*

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
| **The statement as a document** | ✅ done | `04-payments.md` §6.2 asks for a PDF, and this is one — written by a hundred-line PDF writer rather than a layout engine, in the two standard fonts every reader has had since 1993, with the figures in Courier so a money column right-aligns by counting characters instead of by carrying a font-metrics table. Uncompressed: a statement is three kilobytes, and reading it with `strings` when somebody disputes what we sent is worth more than the bytes. **The commission rate is derived from these sales**, not read from the operator's row, because the row can be renegotiated and a document reprinting today's rate over last month's money is the kind of small dishonesty that ends a relationship. **Nothing is invented** — §6.2's mock shows change fees and dispute adjustments, neither is in the ledger, and a `0 FCFA` row for something we never compute is a more convincing lie than an absent one. The console downloads it through the authenticated client and hands it to the browser (a plain link sends no bearer token), and the back office serves **the same bytes from its own route**. Emailing it is **not** built: attachments are missing from the ACS adapter. 18 API unit · 4 Postgres · 4 client · 6 smoke · 3 console tests |
| **IRROPS — declaring, and telling everybody** | ✅ done | The dispatcher declares one of six kinds and everything downstream is derived: the departure's new status, the exemption on every booking, one message per passenger. All of it in **one transaction** — bookings marked involuntary with no declaration behind them is a refund entitlement nobody can account for. A disruption is **public** (the follower of a shared trip link holds no account and is exactly the person who otherwise phones the agency), **not editable afterwards** by a column-level grant, and **one open per departure** by a partial unique index, so "what is happening to my coach?" has one answer. A short delay entitles nobody to anything — the threshold is an hour, it lives in the domain, and the console asks it rather than restating it. 16 domain · 6 contract · 12 Postgres · 5 worker · 7 smoke · 6 console · 2 traveller tests |
| **IRROPS — the rescue coach** | ✅ done | Option ① of `08-disruption.md` §2.2: a different vehicle, the same journey. The seats are **remapped by the domain** — a passenger keeps their label only when the new coach has one of the same kind, because `1D` is a window on a 2+2 and the middle of the back block on a 2+3. Every ticket is **re-signed** in the same transaction as the new manifest, since the QR carries the seat (ADR-0007). A coach that cannot seat everybody is refused **with the number short**, so a dispatcher knows which coach to look for next. Holds with nothing behind them are released rather than slid onto a different seat under somebody who is looking at a seat map. The swap supersedes the breakdown that caused it. 9 domain · 2 contract · 6 Postgres · 5 smoke · 6 console tests |
| **IRROPS — the rebooking wave** | ✅ done | Option ② of `08-disruption.md` §2.2: the passengers go on the operator's own next departure. **Every replacement seat is taken before a single old one is released** (§2.4) inside one transaction, so a paid passenger never exists without a seat. **Partial coverage is a success** — "18 / 42" is what a dispatcher acts on, and refusing anything short of everybody would mean the tool only works on the days it is not needed. A party moves whole or not at all, in the order people booked, which is the only rule that can be said out loud to whoever is left. No fare difference, ever, even onto a dearer departure (ADR-0016). 13 domain · 2 contract · 13 Postgres · 2 worker · 5 smoke · 3 console tests |
| **Payout runs** | ✅ done | `04-payments.md` §6.2. Prepare · approve · release, and the gap between them is the control: **an operator cannot create, approve or edit their own payout**, by grant rather than by handler, and **the person who prepared a run cannot approve it**. The amount is the ledger's own balance (`payable:operator` less their tills) read again at release, never the sum of the statement's line items. Releasing debits the payable and credits every till plus the bank in one movement, which is what makes "cash sales never generate a payout" true in the books. A week of nothing but cash is negative — the operator owes us the fees — and is refused as a transfer. The back office works the queue — the whole statement is in the row, because the person approving is agreeing to a number — and the operator reads their own statements in the console, cash line included — and now downloads each one as the document an accountant files. 8 domain · 3 contract · 13 Postgres · 8 smoke · 2 schema guarantees · 5 back-office · 3 console tests |
| **`config/markets.yaml` is loaded** | ✅ done | ADR-0006, and the gap this document named first. The file is now the authority for the currency, the service fee, the dialling table and the rails; `Market.congoBrazzaville` is the **fallback** for when there is no file. A missing file falls back — that is every unit test and every fresh clone — and a **malformed one kills the process before it is healthy**, because an instance that comes up green serving last release's rails is the failure worth refusing. Enabling Orange Money, or a carrier renumbering, is a file and a restart. A currency whose exponent we do not know is refused by name, never guessed. 19 API tests · 7 smoke checks, two of them a second server started against a different file |
| **IRROPS — the protection agreement** | ✅ done | `08-disruption.md` §5, the commercial half of option ③. Which roads, at what discount off the rescuer's public fare, up to how many seats a month, one way or both — agreed once in an office instead of at the roadside. **One party writes the terms and the other accepts them**, and afterwards the discount, the ceiling and the roads are frozen by a column-level grant. The **only row in the schema that belongs to two tenants**: an agreement neither party can read is not an agreement, so the policy names exactly two operators and an executed guarantee proves it names no third. Naming a competitor goes through a SECURITY DEFINER function returning the two facts a traveller already reads off a search result, because a SELECT policy on `operators` is all-columns and a competitor's negotiated commission is exactly what a competitor must not read. The ceiling reads `31 / 40` on the card, not on the refusal. Settlement posts one payable against the other, **no commission and no cash**, so it nets into the next payout run. 23 domain · 18 Postgres · 11 smoke · 2 schema guarantees · 7 console tests |
| **IRROPS — the protection movement** | ✅ done | `08-disruption.md` §2.2 option ③, §2.3. The agreement now moves people. The dispatcher picks a competitor's departure out of the **public search** — the same list any traveller sees — narrowed to companies an agreement covers, later, with room; the ask lands on their console with what §2.3 says they need to answer: who, how many, which coach, what they will be paid. **Accepting applies the movement in the same transaction**, because a request accepted now and applied later is a window in which the receiving operator sells the seats they just promised. New seats taken before old ones released, both departures locked in id order, `operator_id` and `departure_id` changing together, and **every ticket re-signed under the receiving operator's code** (ADR-0007). The rebill is the discount on the **rescuer's** fare, posted payable-against-payable with no commission and no cash. The **one operation that crosses a tenant boundary**: it escalates into one narrow transaction that re-checks the agreement is still active and the request still pending, and the two SECURITY DEFINER functions it needed hand over only what a traveller can already read off a search result. 18 Postgres · 10 smoke · 2 schema guarantees · 13 console tests |
| **IRROPS — the passenger's own choice** | ✅ done | `08-disruption.md` §3.2 option ⑤. The passengers pick between the plans themselves, and a released seat goes back into the pool the other affected passengers are drawing from — which is why this covers more people than any dispatcher plan. **A default is already assigned** and the screen says so, so nobody is left holding nothing while they decide. **Every travel row states the arrival time**, because that is the question being asked at a roadside. **The refund is last, always present**, issued as an **agency claim with a code** rather than a rail disbursement we cannot make. The deadline states its own fallback in the same sentence. **Another company's coach is never offered to a passenger** — protection is an operator-to-operator settlement, and a traveller cannot commit two companies to money neither agreed to — so the alternatives are the operator's own, later, with room, inside 36 hours. Nothing is cached: the window is re-checked and the departure locked before a seat moves, so a screen open for ten minutes refuses, re-reads and shows what is left **above** the options rather than instead of them. 18 domain · 20 Postgres · 1 worker · 9 smoke · 17 traveller-app tests |

## Phase 3 and beyond

| Slice | State | What is actually there |
| --- | --- | --- |
| **Trip sharing and the follower page** | ✅ done | ADR-0014. The traveller mints a link and sends it into whatever conversation they were already having; whoever opens it sees the coach. **The page is HTML the API serves, not the Flutter app** (ADR-0004) — six kilobytes, self-contained, rendered before it fetches, then polling once a minute — because the follower is on a borrowed handset with 2G and will open it once. **The link follows a coach, never a person**: no seat, no reference, no fare, no name, no number crosses, and that is a property of the SECURITY DEFINER function's OUT columns rather than of a handler, checked by a guarantee that scans the signature itself. A **disruption reaches the follower**, which is the point — the moment the person at the station most needs to know is the one the passenger is least able to explain. Progress is honest about **which tier it came from**: with no conductor GPS and no checkpoint taps yet the bar is dashed and says *estimation d'après l'horaire*. The token is 160 bits **stored only as a SHA-256 hash**, dies six hours after arrival, and is revoked in one tap with the opens count beside it. Revoked, expired and never-issued answer identically, because a page that distinguishes them is an enumeration oracle. Opening the sheet mints nothing, and **platform staff cannot create one**. 14 domain · 13 Postgres · 13 smoke · 1 schema guarantee · 11 traveller-app tests |
| **Cancel, by the traveller** | ✅ done | `01-feature-spec.md` §8.2. **An unpaid reservation is *released*, never "refunded"** — the commonest cancellation there is, and a claim code for nought francs reads as a bug to whoever is handed it. A paid booking quotes what comes back **beside what is kept**, under **the terms it was sold under** (ADR-0015 rule 1, by the join to `(policy_id, version)`), computed by the same `quoteRefund` the server executes (ADR-0004). **Cash paid at a counter comes back at a counter** whatever the policy's destination says, because a journey paid in notes never had a source; a wallet policy writes the debt as `approved` and the screen commits to a **window**, never to an arrival, since the disbursement float is not built. **Terms that give nothing back warn rather than refuse** — somebody who cannot travel would rather free the seat than no-show — and the warning is a sentence, not `0 FCFA` beside a button. The seat is **on sale again in the same transaction**, which is the whole reason to build this instead of answering the phone. A **payment in flight refuses the cancellation**, because releasing seats a second before a capture lands is what neither end can undo. `refund_policies` became readable by the public role — the first widening of that boundary — with every write still refused and a guarantee asserting both halves. 17 domain · 6 contract · 14 Postgres · 2 worker · 8 smoke · 1 schema guarantee · 20 traveller-app tests |
| **Reschedule, by the traveller** | ✅ done | `01-feature-spec.md` §8.1 and ADR-0012 D-08. **Every row is priced before selection** — fee and fare difference on each line, which is what §8.1's mock asks for and what stops somebody tapping five times to compare four departures. D-08's three numbers are data now, stored on the same row as the refund terms and stamped onto the booking by the same `(id, version)` pair, so ADR-0015 rule 1 covers changes without a second versioning scheme. **New seats taken before a single old one is released**, both departures locked in id order, **ticket re-signed in the same transaction** (ADR-0007). **A cheaper departure gives nothing back**, said above the list rather than after the tap. **A row that cannot be taken is shown with its reason**, because a departure missing from a list is one somebody telephones about. **A change that owes money is refused to the franc** and settled at a counter — collecting it in-app needs a payment intent bound to a held-but-unapplied change, which is its own slice. An operator-caused change is free inside every cutoff (ADR-0016). Operators cannot yet edit these three numbers in the console: every policy stores D-08's defaults. 21 domain · 6 contract · 17 Postgres · 7 smoke · 18 traveller-app tests |

Three items of it are built, out of order and deliberately. The follower page is
what makes a disruption reach the person who would otherwise phone the agency,
and that machinery shipped in Phase 2. Self-service cancellation is the other
half of the refund path the counter already had, and every piece it needed —
policies as data, the ledger, the claim code, the outbox — was already there;
leaving it out would have meant a system that can refund a booking only when
somebody walks into an office. §8 is now built on both sides — cancel and reschedule — with one boundary
named rather than implied: a change that owes money is quoted to the franc and
settled at a counter, because collecting it in-app needs a payment intent bound
to a held-but-unapplied change. Everything else in Phase 3 — the stores,
offline tickets on device, card via PSP, analytics — is not started. `09-roadmap.md` has the remaining
Phase 1 work in **dependency order**. With both consoles rendered, the vitrine complete, TOTP in front of
both back offices, object storage built, the section builder shipped and
refunds executing end to end, the sales horizon extending itself and an
operator able to sign themselves up, and the phone channel plumbed behind an
announcement, **every engineering item in Phase 1 is built.** What remains
there is commercial. Phase 2 is where the unbuilt work
lived: the re-accommodation plan, payout runs and the `config/markets.yaml`
loader are all built, as is the whole of option ③ — the protection agreement
and the movement under it — and option ⑤, the passenger's own choice. What is
left there is a telco's sandbox becoming production credentials, and an
attachment on the ACS email adapter so a statement can be sent as well as
downloaded.

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
6. **A passenger's refund is a claim at a counter, never money pushed back.**
   The choice screen (§3.2) and the console's refund desk both end at an
   agency claim with a code, because `source` disbursement down a mobile-money
   rail is not built and stops at `approved`. That is honest rather than
   convenient — a promise the counter has to refuse is worse than a counter
   somebody can walk into — but it does mean a traveller in Pointe-Noire whose
   coach failed collects at an agency rather than on their phone, and the
   sentence on the screen has to keep saying so until the disbursement half
   exists.
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
13. **A statement can be downloaded but not emailed.** `04-payments.md` §6.2
   asks for both. The document exists and both surfaces serve it; what is
   missing is an *attachment* on the ACS email adapter, which sends bodies
   and nothing else today. Sending a link back to a login instead would be
   worse than not sending: an operator who has to sign in to read what they
   were paid will phone us instead, which is the call the statement exists to
   prevent.
14. **A followed trip is estimated from the timetable, not observed.**
   ADR-0014 §2 names three tiers of tracking; only the third exists. Conductor
   GPS needs a driver-facing surface nobody has built, and checkpoint taps need
   somebody with a handset at a station. So the follower page draws a **dashed**
   bar and says *estimation d'après l'horaire* rather than a solid line
   somebody would read as a position — a coach that left forty minutes late
   shows as on schedule until a dispatcher declares the delay. The other two
   tiers are written and tested in the domain, so the day either data source
   appears the page improves without the model changing.

---

## How to verify any of this yourself

```bash
# One package at a time. `dart test packages services/api` in a single
# invocation fails to load about half the suites on this machine, and running
# them separately is also what melos does.
dart test packages/bel_domain packages/bel_localization \
         packages/bel_contracts packages/bel_crypto     # 457 tests
dart test packages/bel_client                           # 36 tests
rm -rf services/api/build                               # see below — it matters
dart test services/api -x integration -x storage        # 214 tests
cd packages/bel_design     && flutter test  # 65 component and contrast tests
cd packages/bel_backoffice && flutter test  # 10 sign-in and enrolment tests
cd apps/traveller && flutter test        # 153 app tests
cd apps/console   && flutter test        # 86 console tests
cd apps/admin     && flutter test        # 23 back-office tests
cd apps/console   && flutter build web   # the console is a web build
cd apps/scanner && flutter test          # 20 scanner tests
dart run tool/check_layers.dart          # the onion rule, 345 files
./infra/migrations/check.sh              # 40 schema guarantees
./tool/integration.sh                    # 298 tests on real Postgres, incl. the worker
./tool/smoke_api.sh                      # 270 checks, incl. the Dart client
./tool/storage.sh                        # 10 tests against real Azurite
```

Remove `services/api/build` before counting: `dart_frog build` copies the
whole workspace into it, and `dart test services/api` then runs every suite
twice — and, worse, runs a *stale copy* of a package's tests, which is how a
green suite reported a failure in a file that no longer existed.

**1,064 tests in total**, plus 270 smoke checks, 40 executed schema guarantees,
298 further tests against real Postgres and 10 against real Azurite. The smoke run now includes the *typed client* against the running
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

**Reschedule, by the traveller** (`01-feature-spec.md` §8.1, ADR-0012 D-08) —
the other half of §8, and the half the spec is most emphatic about.

**Every row carries its own price.** §8.1's mock shows a list of departures
with a fee and a fare difference on each line, and that detail is the whole
feature. Somebody choosing a new departure is comparing four of them; a screen
that prices only the row you tapped makes them tap four times, on a connection
that drops between two of them, and then decide from memory. So the server
quotes every candidate in one query and the list arrives priced — *Gratuit* on
the free ones, the fee broken out on the rest, and the reason spelled out on
the ones that cannot be taken at all.

**A row that cannot be taken is shown anyway, with its reason.** Dropping it
would produce a shorter, cleaner list and a telephone call: a departure the
traveller knows exists and cannot find on the screen is a departure they ring
the agency about. *Complet*, *trop tard*, *déjà partie* on the row is longer
and answers the question.

**D-08's three numbers are data now**, and they live on `refund_policies`
rather than in a table of their own: free with at least twenty-four hours'
notice, ten percent of the fare inside that window, refused inside two hours.
Putting them on the refund row was the point — they inherit the `(id, version)`
stamp the booking already carries, so ADR-0015 rule 1, *judged by the terms it
was sold under*, covers changes without a second versioning scheme to keep
honest. The migration header says so, because the next person will wonder.

**The new seats are taken before a single old one is released.** Both
departures are locked in id order inside one transaction, the quote is
recomputed against the locked rows rather than trusted from the GET, and the
**ticket is re-signed in the same transaction** — the QR carries the seat and
the departure (ADR-0007), so a rebooked passenger holding the old code is
holding a code for a coach that left.

Three boundaries are deliberate, and each of them is a refusal to promise
something the rest of the system cannot do.

**A cheaper departure gives nothing back**, and the screen says so above the
list rather than after the tap. Refunding a downward difference means either a
disbursement we cannot make or a counter claim worth less than the counter time
it consumes.

**A change that owes money is refused, to the franc.** Somebody cannot board a
coach they have not paid for; collecting the difference here needs a payment
intent bound to a held-but-unapplied change, which is a slice of its own; so
the amount is stated exactly and settled at a counter, which is how these
agencies already work.

**An operator-caused change is free inside every cutoff there is** (ADR-0016),
and that check runs *before* the window rather than after it — a passenger
whose coach was cancelled at ninety minutes is not inside a two-hour cutoff of
their own making.

What it cost: 21 domain tests, 6 contract round-trips, 17 against real
Postgres, 7 smoke checks, 18 traveller-app tests, one migration, one port, one
route, one screen. What it did not build: collecting the difference in-app, and
the console wizard questions for the three change numbers — every policy
currently stores D-08's defaults because the console never passes them.

---

## What the cancellation push changed, and what it cost

**Cancelling, by the traveller** (`01-feature-spec.md` §8.2) — the half of
§8 that carries money, and the half most ticketing systems here make you
telephone for.

**The commonest cancellation in the system is a reservation nobody paid
for.** A payment code issued, never used, and a seat held against a person
who has changed their mind. That case owes nobody anything, and the whole
screen turns on saying so: it is a **release**, the word *remboursement*
never appears, and no claim code is issued. Modelling it as a refund of zero
would have been fewer branches and a worse product — a code for nought francs
reads as a bug to whoever is handed it, and the support call it generates
costs more than the seat.

**What is retained is shown beside what comes back.** A traveller who sees
only the smaller figure assumes a mistake; a traveller who sees both is
reading a policy they agreed to. Under **the terms the booking was sold
under**, resolved by the join to `(refund_policy_id, refund_policy_version)`
rather than by the operator's current default — the rule ADR-0015 calls its
most important, and the one a test here re-checks by writing a more generous
policy after the sale and asserting the quote does not move.

**Cash paid at a counter comes back at a counter**, whatever the policy's
destination field says. That field describes wallet and card journeys; a
journey paid in notes never had a source, and "back to source" for it is a
sentence nobody can honour. The domain decides it, so the screen and the
server decide it identically.

**A wallet refund says "sous 72 heures" and never says "envoyé".** The debt
is written as `approved` and posted to the ledger; the disbursement float is
a separately funded API that does not exist. §8.2 asks for a window rather
than an instant, which turns out to be exactly what an unbuilt rail can
honestly promise. The SMS is worded the same way, and a test asserts the word
"sent" is not in it.

**Terms that give nothing back warn rather than refuse.** The bands may all
have elapsed. Hiding the button does not give somebody their money back, and
a person who knows they cannot travel would rather free the seat than
no-show — so the cancellation is still offered, and the sentence above it
says *ne vous rend rien* in words rather than showing `0 FCFA` beside a
confirm button, where it would be read by nobody. Nothing is written to
`refunds` in that case either: a refund row of nought is a row somebody would
later try to pay.

**The seat is on sale again inside the same transaction.** This is the
commercial argument for the whole slice: a seat released at 22:00 the night
before is a seat somebody else buys at 05:30, and a cancellation that waits
for an agency to open is a seat that travels empty.

**A payment still in flight refuses the cancellation.** Somebody is typing a
PIN on a handset we cannot observe. Releasing the seats a second before the
capture lands is the one outcome neither end can undo, and it is the same
instinct as the spec's thirty-second rule (§6.2) seen from the other side of
the same window.

**The two verbs answer identically about a stranger's booking.** The GET
returns 404 and so does the POST — which it did not, at first: the POST
answered 409 `nothing_to_cancel`, and a smoke check caught it. A booking
reference is six characters, and an endpoint where "not yours" and "does not
exist" differ is a way to test whether a reference is real.

**`refund_policies` became readable by the public role.** The first widening
of the sales boundary since 0005 drew it, so it got a migration of its own
and an executed guarantee rather than a line in an existing one. The
reasoning is that the terms are *published*: §4.1 prints them on the
departure screen before anybody buys, §8.2 quotes them at cancellation, and
an operator who did not want travellers reading them would have no way to
sell under them. SELECT crosses operators deliberately — somebody comparing
two companies holds a booking under neither. Every write stays refused, and
the guarantee asserts both halves, because "we only granted SELECT" is a
claim about a line of SQL and the check is a claim about the database.

**No reason field.** The counter's refund demands one — a vendor moving
somebody else's money has to answer "why did we give this person money?" six
weeks later. A traveller cancelling their own owes nobody an explanation, and
a mandatory free-text box would have collected the word "annulation" eleven
thousand times.

**Found on the way:** the money rows on the sheet overflowed by ten pixels on
a 400 px viewport with a six-figure amount. The label yields now, never the
figure — a wrapped "Payé" is cosmetic and an elided amount is a lie.

**What it did not build:** reschedule (§8.1). It is a different problem — it
takes a seat before it releases one, and it needs a change-fee policy that
does not exist in the schema yet — and shipping half of it inside this slice
would have meant a screen that could take money without a rule behind it.

**What it cost:** 17 domain tests, 6 contract, 14 against real Postgres, 2 in
the worker, 8 smoke checks, one executed schema guarantee, 20 traveller-app
tests, one migration, one port, one route and one screen.

---

## What the trip-sharing push changed, and what it cost

The **shareable trip link and the follower page** (ADR-0014) — the first
Phase 3 item, built early because the machinery it depends on shipped in
Phase 2 and because it is what turns a declared disruption into something the
person waiting at the station actually learns.

**The follower has no account, and that is the whole design.** Somebody
standing at Pointe-Noire at midnight waiting on a brother's coach is the
person who phones the agency, and no amount of app-side polish reaches them:
they have not installed anything and they are not going to. So the traveller
mints a link and drops it into whatever conversation they were already having.

**The page is HTML the API serves, not the Flutter app.** ADR-0004 already
said the follower page is not Flutter Web, and building it made the reason
concrete: a 3 MB canvas download and a cold engine start, on a borrowed
handset on 2G, to read one progress bar somebody will look at once. What
ships instead is six kilobytes, self-contained, with **the route, the times
and the operator's name in the first response** so it renders before it
fetches anything — then it polls once a minute for movement. Words come from
the same catalog as every other surface (ADR-0008), injected as JSON rather
than interpolated into markup, and `?lang=en` is honoured because the person
who receives the link is not necessarily the person who bought the ticket.

**The link follows a coach, never a person.** No seat, no booking reference,
no fare, no passenger name and no telephone number crosses to a follower —
and that is a property of the `followed_trip` function's OUT columns rather
than of the handler that calls it. A schema guarantee scans the signature
itself for `seat|ref|fare|price|minor|phone|msisdn|name`, so widening the
function later fails the check rather than quietly widening the leak. The
privacy sentence is on the share sheet *before* anybody sends a link, because
"what will they see?" is the question people ask before sending, not after.

**Revoked, expired and never-issued answer identically.** A page that
distinguishes them is an oracle: it tells somebody guessing tokens which
guesses were once real. And the token itself is 160 bits of `Random.secure`,
**stored only as a SHA-256 hash**, so a database dump is not a set of live
links to strangers' journeys.

**Three ways a link ends, and the traveller controls one of them.** It dies
six hours after arrival on its own — nobody has to remember. It can be
revoked in one tap. And the **opens count sits on the sheet beside it**, which
does two jobs: it tells somebody their message arrived, and it tells somebody
who sent it to the wrong group chat that it did too, while there is still time
to revoke. That count is incremented inside the resolve function and only for
live links, so a revoked token does not tick.

**Opening the share sheet mints nothing.** A traveller who taps *partager* to
see what it does must not discover afterwards that they published their
journey. The sheet reads; a second, deliberate tap creates. A test asserts the
gateway saw a read and no write.

**Platform staff cannot create one.** The insert policy names the purchaser,
so a support agent who can read every booking in the system still cannot
publish a customer's trip. That was found rather than designed: the first
version of the schema guarantee inserted as `bel_admin` and was refused, and
the right response was to keep the refusal and rewrite the test.

**Progress is honest about which tier it came from.** ADR-0014 §2 names three:
conductor GPS, checkpoint taps, and the schedule. Only the third exists today
— there is no driver app and no checkpoint hardware — so the bar is **dashed**
and labelled *estimation d'après l'horaire*. A solid line drawn off a
timetable is a position somebody would believe, and believing it is how a
person leaves for the station an hour early. The other two tiers are written
in the domain and tested, so the page changes when the data arrives rather
than the model.

**A disruption reaches the follower**, which is the point of building this
alongside IRROPS rather than after it: the one moment the person at the
station most needs to know is the moment the passenger is least able to
explain, because they are on a roadside with a dead battery.

**Found on the way:** a worker fixture built booking references as
`unique('R').substring(0, 6)`, and `unique` appended `microsecondsSinceEpoch %
10000` without padding — so roughly one run in ten the clock landed on a
low value, the string came out five characters, and a test failed with a
`RangeError` that looked nothing like its cause. Padded now.

**What it did not build:** conductor GPS and checkpoint taps — tiers 1 and 2 —
which need a driver-facing surface and hardware at stations respectively.
Named in the gaps rather than implied by the dashed bar.

**What it cost:** 14 domain tests, 13 against real Postgres, 13 smoke checks,
one executed schema guarantee, 11 traveller-app tests, one migration, one
SECURITY DEFINER function, three routes and a 6 KB HTML page.

---

## What the statement-document push changed, and what it cost

The payout statement as a **document** (`04-payments.md` §6.2) — the last
unbuilt item in Phase 2 that was ours rather than a telco's.

**A screen is not a document.** The console has rendered these figures for
several pushes. What it could not do is hand an operator something their
accountant files, their bank asks for, and a dispute six months from now is
settled by. That is the whole reason this exists: not a nicer view of the same
numbers, but an artefact that outlives the session it was produced in.

**A hundred lines of PDF, not a layout engine.** The Dart PDF packages are
widget trees, flex, page breaks and font subsetting, and they carry a font
embedder and a zlib dependency to do it. What §6.2 asks for is one page of
left-aligned labels and right-aligned figures. Three decisions follow, each
taken the conservative way: **standard fonts, never embedded** — Helvetica and
Courier have been in every conforming reader since 1993, and embedding a
TrueType face would add a few hundred kilobytes and a licensing question to a
three-kilobyte file; **figures in Courier**, which is fixed-pitch at 600/1000
em, so the money column right-aligns by counting characters rather than by
carrying a metrics table, and a misaligned column of figures reads as
carelessness about the figures themselves; and **no compression**, because
being able to read the file with `strings` when somebody disputes what we sent
is worth more than the bytes.

**The encoding is where the bugs were, and the tests caught all three.** The
content stream is written as WinAnsi bytes: `/Length` counted in UTF-8 while
the file is written in Latin-1 overruns by one byte per accented character and
renders as a **blank page** rather than as an error — there is now a test that
walks every xref offset and asserts it lands exactly on `N 0 obj`. The narrow
no-break space `Money.format` puts between thousands is U+202F, which WinAnsi
does not have, and dropping it turns `3 429 600` into `3429600` on a page
somebody is checking. And `Money.format` prefixes a deduction with U+2212,
not a hyphen — which rendered as `?185 400 FCFA` on the first document that
came out of this, a missing minus sign on a financial statement.

**The commission rate is derived from these sales, not read from the
operator's row.** The row can be renegotiated tomorrow; what this document has
to say is what was taken from *these* fares. A statement that reprints today's
rate over last month's money is the kind of small dishonesty that ends an
operator relationship, and it would have been the easier thing to write.

**Nothing is invented.** §6.2's mock has a change-fee line and a dispute
adjustment line. Neither exists in the ledger. A `0 FCFA` row for something we
never compute is a *more* convincing lie than an absent one, and a test asserts
those two labels are not on the page.

**The cash question is answered on the document itself.** §6.2 names it as the
number-one operator question, and the answer is a sentence rather than a
figure: counter sales appear in full, pay out nothing because the operator is
already holding the money, and only the service fee on them is withheld. One
line on the page, one phone call a week saved.

**A download needs a bearer token, so it cannot be a link.** An `<a href>`
sends no headers. The bytes come down through the same authenticated client as
everything else and are handed to the browser through a blob URL that is
revoked immediately — a console left open all week would otherwise pin every
statement it had downloaded. That is behind a `FileSaver` port for the same
reason the logo upload is behind a `FilePicker` one: the anchor is the single
thing in the flow a widget test cannot run.

**The server names the file, and both surfaces serve the same bytes.**
`releve-ocean-du-nord-2026-08-01.pdf` — ASCII only, because an accented
filename survives most of the way and then arrives mangled through one proxy
or one mail client. And `/admin/v1/payouts/{id}/pdf` renders from the same
function as the console's route, so a reviewer approving a number and the
company being paid are never holding two different prints of one run.

**Another operator's statement id is a 404 by policy, not by a check.** The
read runs under the caller's tenancy; 0018 gives an operator SELECT on their
own `payout_runs` and nothing else, so the row is not there to refuse. The
platform read takes an actor id instead — and refuses to run without one,
because `app_user_id()` casts the setting to uuid and a label like
`'statement'` fails on the first query.

**Found on the way:** the worker suite purged the outbox once per *suite*,
which left "draining twice does not send twice" counting rows an earlier test
in the same file had queued. It went red on the day this push added tests
elsewhere — the exact failure mode that purge was added to prevent, one scope
too wide. It is per test now.

**What it did not build:** emailing the statement. §6.2 asks for downloadable
*and* emailed; attachments are not implemented on the ACS email adapter, and a
statement that arrives as a link back to a login is not the thing being asked
for. Named here rather than implied by silence.

**What it cost:** 18 API unit tests, 4 against real Postgres, 4 client tests,
6 smoke checks, 3 console tests, two routes, one port method, and three
encoding bugs that would each have shipped as a document somebody could not
read.

---

## What the passenger's-own-choice push changed, and what it cost

The passenger's own choice (`08-disruption.md` §3.2 option ⑤) — the option
most systems never build, and the last unbuilt piece of IRROPS.

**Why it covers more people than a dispatcher plan.** A dispatcher moving
forty-two people onto an eighteen-seat coach is solving an allocation problem
with one lever. Letting the passengers choose adds a lever per passenger: the
person who would rather have the 14:00 than the rescue coach releases a seat
back into the pool the other forty-one are drawing from. Nobody has to be
persuaded of anything for this to work — it is the arithmetic §3.2 describes,
and it is why this screen exists rather than a better dispatcher tool.

**A default is always already assigned, and the screen says which.** The
temptation is to present a clean list of equal options and wait. That leaves
somebody who closes the app mid-thought — or whose battery dies at a roadside
— holding nothing at all. So the server pre-assigns, the screen renders that
row first with `ATTRIBUÉ` and a button that says *Je garde* rather than
*Choisir*, and the deadline states the fallback in the same sentence it states
the time. Choice here is an upgrade on a safe state, never a prerequisite for
one.

**Every travel row states the arrival time.** Departure times are what a
timetable holds and what every booking screen shows, and they are the wrong
answer to the question actually being asked on a roadside at 04:00. "Arrivée
21:30" is the thing somebody decides against. Showing "Départ 14:00" and
letting them add eight hours in their head is the kind of small unhelpfulness
that reads as indifference.

**The refund is an agency claim, not a rail disbursement.** It would have been
easy to write "remboursé sur Airtel Money" on this screen. We cannot push money
back down a rail today — `source` refunds stop at `approved` and that is
written down in the refunds section above — and a promise the counter has to
refuse is worse than a counter somebody can walk into. So the refund issues a
claim with a code, the code is on the receipt and in the SMS, and the sentence
says where to collect it.

**Another company's coach is deliberately not offered to a passenger.**
Protection (§5) is an operator-to-operator settlement under an agreement two
companies signed, with a rebill and a monthly ceiling. A traveller tapping a
competitor's departure would be committing two companies to money neither of
them agreed to, on nobody's authority. So the alternatives on this screen are
the operator's own — later than the disrupted departure, with room, inside a
36-hour horizon — and the protection route stays where it belongs, on a
dispatcher's console with an agreement behind it.

**Nothing on this screen is cached, and the lock decides, not the screen.**
The seat counts are the entire content: an option list held for ten minutes
offers a coach that filled nine minutes ago. So the options are read at the
moment the screen opens, and on the way back in the window is re-checked and
the departure locked *before* the seat is taken. A stale tap does not move
somebody onto a full coach and does not throw them onto an error screen
either — it refuses, re-reads the options and renders the refusal **above**
them. That last part is the design decision worth naming: nearly every refusal
here is the world having changed rather than the passenger having erred, and
their next move is to look at what is left.

**Two bugs the tests found before anybody else could.** A screen that had been
open across a state change was returning `choice.unknown_option` for a
perfectly real departure, because the option id was being matched against a
list rebuilt from current availability rather than handed to the lock; the
window gate now runs first and any id that looks like one goes to the mover,
which is the only thing that can honestly answer. And the alternatives came
back empty on a shared route, because a `LIMIT 8` over every suite's
departures filled up before reaching the ones that mattered — status, free
seats and the horizon are now filtered in SQL rather than after it.

**What it cost:** 18 domain tests, 20 Postgres tests, 1 worker test, 9 smoke
checks, 17 traveller-app tests, two new public routes, and 5 error keys in
both languages so a refusal at a roadside is a sentence rather than a code.

---

## What the protection-movement push changed, and what it cost

The protection **movement** (`08-disruption.md` §2.2 option ③, §2.3). The
agreement went in last time and nothing had moved under it; now a passenger
whose coach failed at Dolisie is carried to Pointe-Noire by another company,
on a ticket that scans at their door.

**The console reads a competitor's timetable through the public search.**
A dispatcher has to name the other company's departure — the 13:00 with room
— and there is no console endpoint that lists somebody else's coaches, nor
should there be. So the sheet asks `/public/v1/trips`, the same list any
traveller with the app can pull up, and narrows it to companies an agreement
in force actually covers. Nothing was widened to make this work; what a
dispatcher is spared is having to open a second app.

**Accepting applies the movement, in the same transaction.** The obvious
design — accept now, move the passengers on a queue — leaves a window in
which the receiving operator sells the seats they have just promised, and the
person who finds out is a passenger at a door. So the accept button does the
whole thing: seats taken, bookings moved, tickets re-signed, ledger posted,
message queued. It is a long transaction on purpose.

**This is the one operation in the system that crosses a tenant boundary.**
Not for convenience — it is not *possible* under either tenancy. The bookings
belong to the sending operator, the seats to the receiving one, and neither
connection can see both halves. So the privilege escalates into a single
narrow transaction, and everything it would otherwise have to trust is
re-checked inside it: the agreement must still be `active` and the request
must still be `pending`. An agreement suspended between the ask and the
answer authorises nothing, and there is an executed guarantee that says so.

**RLS filters rows; it does not raise.** The first version of the inbound
queue joined the request to both departures and returned nothing at all —
whichever coach belonged to the counterparty was filtered out by policy, and
the row vanished from the join rather than arriving short of a column. On the
console of the company being asked for help, that reads as *nobody asked*.
The fix is a SECURITY DEFINER function that takes **no operator argument** —
it reads `app_tenant_id()` itself, so there is nothing to spoof — and hands
back only what §2.3 says a receiving operator needs: when the coach leaves,
which road, how many seats are free. Every one of those is already visible to
any traveller searching that route. The failure mode is worth naming because
it is silent in exactly one direction: the sender's own view worked fine.

**A shared database made an unrelated suite fail.** The API integration suite
and the worker suite run against the same Postgres, and the worker's drain
takes a hundred rows at a time. Adding fifteen tests that queue messages
pushed the backlog past that limit, and a worker test that queues one row and
drains once started failing for somebody else's reasons — the kind of red that
appears on the day an unrelated suite gains a test. The worker suite now
clears the undelivered queue in `setUpAll`.

**The rebill is on the rescuer's fare, not on what the passenger paid.** Two
defensible numbers, and the wrong one is quietly unfair: a company with dearer
seats would be paid less for giving one up than a company with cheap ones. The
sending operator's pricing is none of their business either way. No commission
is taken — taxing a rescue would discourage the only behaviour the agreement
exists to encourage — and no cash moves, so it nets into the next payout run.

**Partial coverage is said as a number, twice.** Before the decision on the
card ("2 sur 5 seulement") and after it in the notice ("2 sur 5 placés"),
because the three still standing at the roadside are somebody's next problem.
The same rule the rebooking wave established, applied to a screen where the
person reading it works for a different company than the people waiting.

**And the ask does not pretend to be a placement.** The sheet says so next to
the send button and the notice says it again afterwards. A dispatcher who
reads *envoyé* as *placed* stops looking for a coach, and the passengers pay
for that reading.

**What it cost:** 3 migrations, 18 Postgres tests, 13 console tests, 10 smoke
checks, 2 executed schema guarantees, and one silent join that would have
shipped an empty queue.

---

## What the protection-agreement push changed, and what it cost

The inter-operator protection agreement (`08-disruption.md` §5) — the
commercial half of IRROPS option ③, and the half that has to exist first.

**We are formalising a practice, not inventing one.** When a coach fails at
Dolisie the dispatcher already walks the forecourt looking for a competitor
with room. That works; what does not work is settling it in cash, at the
roadside, with an argument about what a seat was worth. The agreement is that
same handshake agreed once, in an office, by the people whose job it is:
which roads, at what discount off the rescuer's public fare, up to how many
seats a month, one way or both.

**One party writes the terms and the other accepts them.** The payout run's
rule, one size down, and for the same reason: an agreement one party could
switch on alone would be an invoice one party could write alone. After
acceptance the discount, the ceiling and the roads are absent from the UPDATE
grant, so they cannot be edited by any code path — including one written next
year by somebody who never read the migration.

**The only row in this schema that belongs to two tenants.** Every other
operator table answers to one `app_tenant_id()`; an agreement neither party
can read is not an agreement. That is a widening, and widenings grow, so the
boundary is executed rather than promised: both parties read it, a third
operator reads nothing, and neither party can write a row binding two
companies they are not one of.

**Naming a competitor does not mean reading one.** An operator picks a
counterparty by code — "TBV" — because the UUID is our bookkeeping and appears
on no document either of them holds. But `operators` carries `commission_bps`,
`tax_id` and `settlement_account_id`, and a SELECT policy is all-columns: a
competitor's negotiated rate is precisely what a competitor must not see. So
the privilege moves into a SECURITY DEFINER function that returns an active
operator's id and trading name — the two facts any anonymous traveller already
reads off a search result.

**The ceiling is shown before it bites.** `31 / 40 places ce mois`, on the
card, not on the refusal. A dispatcher planning a rescue needs to know the
agreement is nearly spent while there is still time to find another one.

**The rebill is money on a real fare.** "− 15 % · 7 650 FCFA sur un billet à
9 000" is a term somebody can check against a ticket in their hand; "1500 bps"
is a term they have to be taught. The percentage is typed, the basis points
are stored, and no float appears anywhere between them.

**No commission, and no cash.** The settlement debits one operator's payable
and credits the other's — that is the whole posting. Taxing a rescue would
kill the behaviour the agreement exists to encourage, and nothing leaves our
bank: the difference lands in whichever payout run comes next, which is what
"règlement via BilletEnLigne, mensuel" means in the ledger.

**What is not built, and is not pretended to be:** nothing has moved under one
of these yet. The request the receiving operator accepts, the seats held and
the tickets reissued under *their* name, the movement row and its posting are
the next slice. `protection_movements` exists and is empty, and the ceiling on
the screen counts from it — so the day it stops being empty the number is
already right.

**What it cost:** a migration with two tables, three split policies and two
definer functions, a `protection.manage` capability that a dispatcher
deliberately does not hold, 23 domain tests, 18 against real Postgres, two
executed schema guarantees, eleven smoke checks and seven console tests.

## What the markets-loader push changed, and what it cost

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
