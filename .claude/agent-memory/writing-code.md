# 1 · Writing code in this repo

---

## Onion, and the direction of every dependency

`bel_domain` (pure) ← `application` (use cases + ports) ← `infrastructure` (Postgres, HTTP,
gateways) ← presentation. A screen never talks to `bel_client` directly; it talks to a flow, and the
flow talks to a port. When a fix needs a fact only one layer has — *"was this code already spent?"* —
the fix belongs in **that** layer, not in a catch clause further out that has to guess.

## Postgres is not a dumb store here

Row-level security is `FORCE`d and every connection is scoped (`DbScope.traveller` / `tenant` /
`worker` / `anonymous`). Seat contention is an **EXCLUDE** constraint on
`(departure_id, seat_label, span)` with `&&` on an `int4range` road span — not application locking.
A change that "fixes" contention in Dart is almost certainly working around the constraint rather
than with it.

Use `ON CONFLICT DO NOTHING` where a duplicate is expected: a raised conflict poisons the whole
transaction, and the next statement then fails for a reason that has nothing to do with itself.

**Tally: 2 — 2026-09-09.** The second time was a `try { UPDATE } on ServerException catch (e) { if
23505 → return refusal }` around a unique index, which looks like the right shape and is not: the
`catch` runs, but the transaction it sits inside is already aborted, so the value it returns has
nothing left to commit and the caller gets a 500 where a sentence belongs. Where the write is a
plain `UPDATE` — no `ON CONFLICT` arm to hang the recovery on — **ask before writing**, in the same
transaction, and leave the index as the backstop for the genuinely simultaneous case.

---

## A new column on `departures` or `operators` is unwritable until the GRANT names it

**Tally: 1 — 2026-09-09, and it read as a bug in the new code.**

`0050` added four columns and every write to them failed with
`42501: permission denied for table departures` — which points at RLS, at the
`DbScope`, at the policy, and at none of those. `bel_app` holds **no table-wide
UPDATE** on `departures` or on `operators`: 0032 and 0035 revoked it and put a
column list in its place, on the grounds that "revoking one column while a
table-level grant stands is a control that reads as working and does nothing".
The list *is* the control, so a column absent from it is read-only.

**Do instead:** any migration adding a column to `departures` or `operators`
needs `GRANT UPDATE (…new columns…) ON <table> TO bel_app;` in the same file.
And read `permission denied for table X` on a brand-new column as *the grant*,
not as the tenancy scope — the message names the table because that is where
column privileges live, not because the table itself is off limits.

---

## A query that consults only one table answers only for rows that table has

**Tally: 1 — 2026-09-09, and it made the entire purchase funnel impossible.**

Every `POST /public/v1/holds` returned **404 Not found**. `_leg` in `PostgresSeatInventory` priced a
journey by looking in `segment_fares` — which is **empty for an unsegmented road**, where the fare
lives on the route itself. No row found was read as "these two towns are not on sale".

The fix distinguishes the two cases explicitly: join `routes`, select
`rt.origin_city = @from AND rt.destination_city = @to AS whole_road`, and refuse only when there is
no priced segment **and** it is not the road's own pair of ends.

**Do instead:** when a lookup returns nothing, ask what *other* shape of the same data would also
return nothing. An empty result is not a negative answer unless every source of a positive one was
consulted.

---

## A shared column list is a promise every CTE in the file has to keep

**Tally: 1 — 2026-09-09, and it broke eight integration tests in four suites the change never
looked at.**

`PostgresOperatorConsole` keeps `_staffColumns` — one `static const` string, interpolated into four
queries. Adding `s.staff_ref` to it fixed the read that needed it and broke every query where `s`
is a **CTE** rather than the table: `WITH upsert AS (… RETURNING id, user_id, roles, …) SELECT
$_staffColumns FROM upsert s`. The CTE's `RETURNING` list is its own column list, and it did not
have the new column. Postgres said `42703: column s.staff_ref does not exist`, which reads exactly
like a missing migration and is not one — the migration had run, and a different query against the
same real table was reading the column happily two tests earlier.

**Do instead:** after adding a column to a shared `SELECT` fragment, `grep` the fragment's name and
open every use. Where the alias resolves to a CTE, its `RETURNING` list needs the column too. The
compiler cannot see inside a SQL string, so nothing else will tell you.

---

## Ordering of overlays decides which screen you actually see

**Tally: 1 — 2026-09-09 ("Loading payment methods…" forever, on the change/reschedule path).**

`app.dart` draws layers in order. The tickets layer was checked before the payment layer, so a
payment opened *from* a ticket rendered the ticket. It was not a hang; it was the wrong widget.

**Do instead:** when a screen never finishes loading, check what is actually mounted before
debugging the thing you think is loading. And keep the precedence rule **narrow** — the blanket swap
would have regressed "opened a ticket while a hold was counting down".

---

## `dart:io` in a package the web has to compile

**Tally: 1 — 2026-09-09, caught by review rather than by a build.**

`HttpDate.tryParse` was the obvious way to read a `Date` header in
`bel_client`. It lives in `dart:io`, which **does not exist on the web** —
and ADR-0033 makes a browser a first-class surface for this client. The
analyzer says nothing until something actually targets web.

**Do instead:** in `bel_client`, `bel_contracts`, `bel_domain`,
`bel_platform` and anything the API *and* an app both import, treat
`dart:io` as unavailable. It is a twenty-line RFC 7231 parser; it is not a
twenty-line rewrite of the web surface later.

---

## Two `Expanded` buttons in a `Row` truncate whichever label is longer

**Tally: 1 — 2026-09-09 ("Cancel this c…").**

An even split is not a layout decision, it is the absence of one. Stack the buttons unless both
labels are short and known.

---

## A query string written into the path goes out as `%3F` and 404s

**Tally: 2 — 2026-09-09 (payment options), 2026-09-09 (admin compliance).**

You are about to add a client call with a parameter. `BelApiClient._send` builds its URI with
`_base.replace(path: '${_base.path}$path')`, and **`Uri` escapes a path** — so a `?` written inside
the path string becomes `%3F`, the whole thing becomes one segment, no route matches, and the
server answers 404.

```dart
_get('/admin/v1/compliance?days=$withinDays')     // → /admin/v1/compliance%3Fdays=60
_get('/admin/v1/compliance', query: {'days': '$withinDays'})   // correct
```

**What makes it expensive is the screen it produces**, not the 404. The back office rendered
*"This version of the app does not understand the server's reply"* over a cheerful **"Nothing to
chase"** — for a window in which one operator's insurance had already lapsed. Confident, empty and
wrong. It was found by opening the page, months after a test for the identical bug on
`paymentOptions` had been written and had not generalised.

**Do instead:** every parameter goes in `query:`. The guard is one line in
`packages/bel_client/test/bel_api_client_test.dart` — assert `url.path` ends where it should and
`url.toString()` does not contain `%3F`. Write it for the endpoint you are adding; the two that
exist did not stop the third.

---

## A row rebuilt from an upsert's `RETURNING` is not the row the joins describe

**Tally: 1 — 2026-09-09. The most expensive defect found so far: the mandatory second factor did
not exist, for anybody, in any app.**

You are about to build a domain object from a write's own `RETURNING` clause. **A `RETURNING` sees
the table it wrote and nothing else** — not the `LATERAL` joins beside it, not a view, not a
sibling table. `PostgresIdentity._resolved` upserted into `user_accounts` and constructed an
`Account` from that row, so every sign-in produced `staff: null` and `platformRole: null`.

That value then flowed into three decisions that all silently took the wrong branch:

- `SecondFactorSignIn.isRequiredFor` → **no authenticator was ever asked for**;
- the capability checks → whatever they permit for a person with no roles;
- the tenant scope.

`byId` had always been correct, because it reads through the joined query. **Only the sign-in path
was wrong, so nothing was red.** Four apps and a full integration suite were green over a product
whose second factor did not exist, and it was found by signing in as a person and noticing a screen
that did not appear.

**Do instead:** write, then **re-read through the one query that builds this object**, and let the
write return nothing but an id.

```dart
await tx.execute(Sql.named('INSERT … ON CONFLICT … RETURNING id'), …);
final joined = await tx.execute(Sql.named(_columnsWithJoins + ' WHERE id = @id'), …);
return _account(joined.first.toColumnMap());
```

**And test the resolver, not the write.** The guard is an integration test that signs in and
asserts the *identity* that comes back — `services/api/test/integration/identity_pg_test.dart`,
*"signing in resolves who somebody is, not only that they exist"*. A test that only asserts the row
exists passes against the broken version.

---

## A `url()` whose SVG uses single quotes resolves to `none`, and reports nothing

**Tally: 1 — 2026-09-09 (the woven background on the landing and storefront pages).**

You are about to inline an SVG as a `data:` URI in server-rendered CSS. If you swap the SVG's
attribute quotes to `'` and wrap the value in `url('…')`, the CSS string ends at the first
attribute. The declaration is invalid, `getComputedStyle` says `background-image: none`, and
**nothing appears in the console** — a page that looks exactly like one where you forgot the rule.

**Do instead:** leave the SVG's `"` alone, wrap the value in `'…'`, and percent-encode only `%`,
`#`, `<`, `>`. Then verify from the page rather than from the source:

```js
getComputedStyle(document.querySelector('.wrap')).backgroundImage   // must not be "none"
```

The same check catches the other silent one: `Uri.encodeComponent` on a colour *and* a later
`#` → `%23` pass produces `%2523`.
