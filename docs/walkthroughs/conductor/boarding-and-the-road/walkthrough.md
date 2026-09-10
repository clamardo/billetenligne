# Conductor — boarding, the road, and closing the departure

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`, Android emulator, `Africa/Brazzaville`)
**As:** Armand Kibangou (`armand@demo.billetenligne.cg`, `conductor` at Alizés Transport SARL, scoped
to one station) in the standalone scanner app (ADR-0022), on departure
`546e6c92` — BZV → PNR, Thu 10 Sep 06:00, 6 sold, Blaise Samba driving.

The request this walk was made for:

> *"…record a traveller QR and then stamp that to the bus driver QR scanner to see if it validates
> and how the trip is recorded and flow during the driver check out at each stop or whatever we have
> going on."*

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | sign in ([01](01-the-scanner-asks-who-you-are.jpg)) | Does a crew member sign in the same way as everybody else? | ✓ |
| 2 | second factor ([02](02-and-then-for-the-authenticator.jpg)) | Is the authenticator asked for, as `SecondFactorSignIn.isRequiredFor` says it must be? | ✗ then ✓ — [below](#1-the-mandatory-second-factor-was-never-asked-for--p1-fixed) |
| 3 | the coach list ([03](03-the-coaches-leaving-next.jpg)) | Does the conductor see their own departures, and only theirs? | ✗ then ✓ — [below](#4-the-scanner-shows-today-and-has-no-way-to-say-which-today) |
| 4 | pin a coach ([04](04-the-boarding-list-before-anyone-is-on.jpg)) | Is the manifest downloaded for use with no signal? | ✓ — 6 sold, 0 boarded |
| 5 | scan the traveller's code ([05](05-the-payload-read-off-the-travellers-screen.jpg), [06](06-valid.jpg)) | Does the exact string off the traveller's screen validate? | ✓ — **VALID · Chancelvie Okemba · 10A · K195CM** |
| 6 | back to the list ([07](07-one-of-six-boarded.jpg)) | Does the count move, offline, before any sync? | ✓ — 1/6 |
| 7 | scan it again ([08](08-the-same-ticket-a-second-time.jpg)) | Is a second presentation refused, by name? | ✓ — **ALREADY BOARDED** |
| 8 | report Kinkala ([09](09-reporting-kinkala.jpg)) | Is an intermediate stop something the crew can report from the road? | ✓ |
| 9 | sync ([10](10-synced-to-the-office.jpg)) | Do the redemption and the checkpoint reach Postgres? | ✓ — both rows, `synced_at` stamped |
| 10 | close the departure ([11](11-closing-the-departure.jpg), [12](12-departed.jpg)) | Does closing record who closed it, and when boarding began? | ✓ — `closed_by` = Armand, `boarding_at` = the first scan |
| 11 | arrive ([13](13-arrived.jpg)) | Does the trip end in a state the office can see? | ✓ — `arrived` |

## What the trip actually recorded

Read back out of Postgres afterwards, which is the only thing that settles it:

```
departures    status=arrived  boarding_at=00:11:28.238  departed_at=00:13:34  arrived_at=00:14:46
                              closed_by=Armand Kibangou
redemptions   seat 10A  mode=scan  code_was_stale=f  scanned_at=00:11:28.238
                                   scanned_by=Armand Kibangou  synced_at=00:12:45
checkpoints   KLA (Kinkala)  passed_at=00:12:05  recorded_at=00:12:46  reported_by=Armand Kibangou
departure_crew  Armand Kibangou (conductor) · Blaise Samba (driver)
```

`boarding_at` and the first `scanned_at` are the same instant to the millisecond. Nobody typed a
boarding time: the first ticket accepted **is** the moment boarding started, which is the only
version of that number a conductor will never get wrong.

## What the walk found

### 1. The mandatory second factor was never asked for — P1, fixed

`SecondFactorSignIn.isRequiredFor(account)` is `account.staff != null || account.isPlatformStaff`,
and it was returning false for every member of staff in the product — owners, conductors, our own
reviewers. Signing in as an operator's owner went straight to the console with no authenticator step
at all.

The cause is one query. `PostgresIdentity._resolved` upserts into `user_accounts` and builds the
`Account` from the upsert's own `RETURNING` row — and a `RETURNING` clause cannot see the LATERAL
joins that carry `staff.roles`, `custom_roles` and `platform.role`. So **every sign-in produced an
account with `staff: null`**, which then flowed into the MFA decision, the capability checks and the
tenant scope. `byId` had always been right; only the sign-in path was wrong, which is why nothing in
the suites was red.

Fixed by stamping `auth_uid` and then re-reading through the joined query, so one code path builds
every `Account`. Guarded by two integration tests in
`services/api/test/integration/identity_pg_test.dart` — *"signing in resolves who somebody is, not
only that they exist"* and *"our own people are resolved as staff on sign-in too"* — both of which
fail against the old query.

This is the finding that justifies the whole walk. Four apps, a full integration suite and a
migration ledger were green over a product whose second factor did not exist.

### 2. The scanner said "Offline" while it was online — fixed

The staleness chip on the boarding list was keyed `staleOffline`, and its copy asserted the device
was offline whenever the manifest was more than a moment old — including while a sync was completing
over Wi-Fi. Re-keyed to `scanner.boarding.listStale` / `listFresh` and reworded to say what is
actually known: *"List up to date, synced 2 min ago."*

### 3. The scanner could not be driven without a camera, so the loop could not be closed

There was no way to feed a payload to the scanner on an emulator, which is the only place this
journey can be walked at all. `TicketSimulator` offered a handful of canned tickets and nothing else.

It now takes a pasted payload (`scanner.simulator.pasteLabel` / `pasteHint` / `pasteSubmit`), still
behind `TicketSimulator.isAvailable` so it cannot exist in a release build. Three tests in
`apps/scanner/test/simulator_paste_test.dart`. Without it there is no walk: the string in
[05](05-the-payload-read-off-the-travellers-screen.jpg) came off the traveller's screen through a QR
decoder, and had nowhere to go.

### 4. The scanner shows "today" and has no way to say which today

`coachesOn(DateTime.now())`, no date picker. On an emulator sitting in `America/New_York` that is the
wrong day, and the list is empty for a reason the screen does not give. Fixing the emulator
(`adb shell "service call alarm 3 s16 Africa/Brazzaville"`) fixed the list.

Left as observed rather than changed: a conductor is on the coach on the day, so "today" is very
probably right for them, and a date picker on this screen is a decision about the product rather than
a defect in it. Recorded here so the next person to see an empty coach list checks the clock first.

## What was deliberately not chased

**A genuinely offline scan.** The redemption is written locally and reconciled on sync, and step 6
shows the count moving before any sync happened — but the handset was never actually taken off the
network. Proving the reconciliation of two devices that both scanned the same seat while apart is its
own walk, and it belongs with ADR-0012's contention rules rather than here.
