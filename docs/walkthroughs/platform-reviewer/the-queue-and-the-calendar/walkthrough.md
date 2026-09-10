# Platform reviewer — the queue, the roster and the expiry calendar

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`), back office at `http://localhost:5001`
**As:** BEL — direction (`direction@demo.billetenligne.cg`, `super_admin`) in the platform back
office.

Our own side of *"check the web app for backoffice … with all the persona possible"*. The back office
is the surface with the fewest users and the most authority, and until this walk nobody had opened
every one of its tabs in a browser in one sitting.

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | Applications ([01](01-the-applications-queue.jpg)) | Are the two pending applicants there, oldest first? | ✓ — Niari Express, Alizés DEMO-CLONE |
| 2 | Operators ([02](02-the-roster.jpg)) | Does the roster count what each company actually has? | ✓ — Alizés *1 coach · 2 routes · 11 staff · Live* |
| 3 | Compliance, 60 days ([03](03-compliance-before-the-fix.jpg)) | Which papers fall due inside the window? | ✗ **P1** — [below](#1-the-compliance-tab-was-404ing-and-the-screen-said-nothing-to-chase) |
| 4 | Compliance, after the fix ([04](04-compliance-after-the-fix.jpg)) | Same question, same window. | ✓ — Cars Lékana **sales stopped**, insurance expired 3 d ago; Kouilou due in 19 d |
| 5 | Payments ([05](05-payments-to-settle.jpg)) | Is an empty limbo queue drawn as empty rather than as broken? | ✓ |
| 6 | Funnel ([06](06-where-people-leave.jpg)) | Where do people leave? | ✗ — [below](#2-the-funnel-counts-one-channel-and-never-says-which) |
| 7 | the identity strip ([03](03-compliance-before-the-fix.jpg)) | Does the back office say who is signed in? | ✗ — [below](#3-the-back-office-identifies-its-own-reviewer-by-uuid) |

## What the walk found

### 1. The Compliance tab was 404ing, and the screen said "Nothing to chase" — P1, fixed

The screen showed a red *"This version of the app does not understand the server's reply. Please
update it."* over a confident **Nothing to chase — no document falls due inside this window**, at a
moment when one operator's fleet insurance had **already lapsed** and another's fell due in nineteen
days.

The cause is one character. `BelApiClient.complianceCalendar` built its request as
`'/admin/v1/compliance?days=$withinDays'` — a query string written **into the path**, which
`Uri.resolve` percent-encodes: the request that actually went out was
`/admin/v1/compliance%3Fdays=60`, a path Dart Frog has no route for. 404, decoded as a shape the
client did not recognise, rendered as a client-version banner over a stale-empty list.

Fixed by passing `query: {'days': '$withinDays'}`. Guarded by *"a compliance window as a query
parameter, not inside the path"* in `packages/bel_client/test/bel_api_client_test.dart`, which
asserts the path has no `?` in it and the `days` parameter is in `queryParameters` — and which fails
against the old line. Recorded in
[`writing-code.md`](../../../../.claude/agent-memory/writing-code.md); it is the second time a query
string has been written into a path in this repo.

**What makes this a P1 rather than a cosmetic bug is the empty state.** A screen that errors is a
screen somebody reports. A screen that says *nothing falls due* while a licence has lapsed is one
nobody reports, because it answered the question.

### 2. The funnel counts one channel and never says which

*Where people leave* showed fourteen consecutive days of *Nothing that day*, with 0 held, 0 booked,
0 paid — against a database holding 26 holds and 26 confirmed bookings.

`PostgresPlatformConsole.funnel` filters `h.channel = @channel` with `channel = 'app'`, and every
hold the demo world creates is `agency` (the seeder sells through the console, as a counter does).
The screen offers a 7/14/30-day window and **no channel control at all**, so a platform whose
counters sell most of its seats reads as a product nobody uses.

The default is defensible — the funnel exists to measure the app's own drop-off, and a counter sale
has no funnel to speak of. What is not defensible is that the screen never says so. Left as observed:
the fix is a line of copy and possibly a channel chip, and both are product decisions rather than
corrections.

### 3. The back office identifies its own reviewer by UUID

Top right, above the role: `ed8713ff-b1b7-48f1-8398-49c9f97131c9` / `super_admin`. The name is
available — `AdminIdentityDto` carries `fullName`, and the test harness has been filling it in as
*Sarah N.* since the surface was written — and the strip draws the id instead.

It matters more here than it would elsewhere: this is the surface where every action is recorded
against a person and a reason, and the one thing the screen shows about that person is the string
least likely to mean anything to them. Left as observed; it is a one-line change in the shell and
belongs with whoever owns that strip's design.

## What was deliberately not chased

**Approving an application, or moving money.** Both are writes against seeded companies, and both
would have changed the world the other five walks were photographed against. The queue was read, not
worked.
