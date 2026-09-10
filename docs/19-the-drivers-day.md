# The driver's day

**Status:** partly built · **Depends on:** [ADR-0022](adr/0022-standalone-scanner-app.md),
[ADR-0024](adr/0024-email-first-signin.md), migration `0049_departure_crew`
· **Related:** [`18-the-platform-other-companies-can-join.md`](18-the-platform-other-companies-can-join.md) J3–J5

## Why this document exists

`apps/scanner` was built to answer one question in under two seconds with the
radio off: *does this person board?* That was the right first question, and it
is now answered well. It is not the only question the person holding the
handset has.

A driver's day has three other moments in it, and the app is silent in all
three:

1. **The yard, the night before.** *Which runs are mine this week?* The list
   was one day wide, so the answer was: ask the office, by phone.
2. **The road.** *Has anything changed?* Nothing reaches the handset. A
   dispatcher who needs to tell a driver something rings them, on a network
   where that fails for four hours at a stretch on the RN1.
3. **Anything unusual.** *How do I tell the office?* Same answer, same phone,
   same four hours.

None of these is a boarding feature, and none of them may be allowed to cost
the boarding feature anything. That constraint decides most of what follows.

## What is built

| | |
|---|---|
| **The list is a span** | ✅ `GET /console/v1/boarding?from=&to=`, inclusive **local** dates, capped at 31 days. `date=` still works — the handsets in the field are sideloaded APKs an agency updates when somebody drives to the office. One call rather than seven, because a week assembled from seven requests over a yard's signal finishes only if all seven do. |
| **A row knows whose it is** | ✅ `crewRole` on each row, from `departure_crew`, as a **LEFT JOIN and never a filter** — a company that has not filled in a rota must not wake up to an empty screen. Where one person both drives and conducts, driving is the job named: it is the earlier commitment and the one a rota is planned around. |
| **The handset says who is holding it** | ✅ `GET /console/v1/me` answers `fullName`, `staffRef`, `operatorName`, `operatorCode`. It used to answer a UUID, which is what three surfaces were showing where a person's name belongs. Best-effort: a failure leaves the header blank rather than stopping a sign-in. |
| **The matricule is not a credential** | ✅ ADR-0024, restated because it keeps being asked for. `staff_ref` is written on the roster, printed on the manifest and stuck to the dashboard of the coach. Accepting it at a sign-in prompt would add a secret to phish rather than a factor to hold. |

## What is left

### D1 — The plan, on the handset · **not built**

A Day · Week · Month filter on the coach picker, and the identity strip that
says whose plan it is.

The server half is done; nothing on screen uses it yet. Three decisions the
UI has to take, and they are the whole of the slice:

- **Rows outside today are plan rows, not pinnable.** A manifest downloaded
  three weeks early is a list of tickets that have not been sold yet, and a
  conductor who pinned one would arrive at the door with a manifest missing
  half the coach. Pinning is offered within ±1 day; further out the row is
  legible and inert, and says so.
- **Grouped by date once the span is wider than a day**, with the date as a
  sticky header. A flat list of forty rows is a timetable, not a rota.
- **Mine is a chip on the row, not a filter that empties the screen.** The
  toggle belongs in the same segmented control as the span, defaulting to
  *mine* only when the person actually has crew rows in the span.

### D2 — The agency schedules a month · **not built** (endpoint exists)

`POST/DELETE /console/v1/departures/{id}/crew` has existed since J3 and **no
console screen calls it**, so today a rota can only be written with `curl`.

The slice is a Rota screen in the console: staff down the side, days across
the top, a month at a time, filling from the departures the timetable already
materialises. Behind `departure.manage` — the dispatcher's capability, not
`staff.manage`, because granting somebody the driver role and putting them on
Tuesday's 06:00 are different jobs done by different people (the route's own
doc comment argues this at length; it stands).

**The one thing to get right:** assigning a person to a departure they cannot
work is refused by the *database* — `departure_crew_is_staff` is a composite
foreign key into `operator_staff`, so another company's employee cannot be
rostered rather than merely being refused a screen. The console should surface
that refusal, never re-implement the check.

### D3 — Alerts, with a bell and a read state · **not built**

A bell in the scanner's header with an unread count; tapping an alert opens
it as a thread.

**What it must not become:** a notification centre. The things worth pushing
to a coach door are few and all of them are operational — this departure is
cancelled, your coach has changed, ring the office. A bell that also carries
marketing is a bell people stop reading, and the one time it matters they will
not have read it either.

Read state is per person and per device-independent: a driver who read
something on the office handset has read it. That means it is a row on the
server, not a flag in the app's SQLite.

### D4 — Driver ⇄ agency messages, over SSE · **not built**

Text, both ways, between the handset and whoever is on the dispatcher's
screen.

**Server-sent events rather than a WebSocket**, which is what was asked for
and is also the right call: this is one-way push with an ordinary `POST` for
the reply, it survives a proxy that mangles upgrades, it reconnects by itself
with `Last-Event-ID`, and it costs a `text/event-stream` handler rather than a
second protocol in the API. A coach on the RN1 loses the stream for four hours
either way; what matters is what happens when it comes back, and SSE's own
resume story is better than one we would write.

**It has to work offline, because the RN1.** A message typed in a dead zone
queues exactly as a boarding does, and the thread shows it as *sending* rather
than pretending it has gone. The outbox for it is a third one alongside
`RedemptionOutbox` and `CheckpointOutbox`, and for the same reason they are
separate: they are about different things, and sharing a table means every
query about who boarded has to remember to exclude the chatter.

**What it must not be:** a support inbox for travellers. This is staff to
staff, inside one operator, and the tenancy is the ordinary row-level one.

### D5 — The scan page wears the brand · **not built**

The boarding screen is the last all-white outlier in the product. Its header
is a `surfaceRaised` strip with a time, a road and a counter on it; everything
else in the app has a woven band ([§8.1](05-design-system.md#81-no-screen-is-a-white-field)).

The camera below it is necessarily a black rectangle, which is exactly why the
band above matters: without it the screen reads as a system camera with some
text stuck on top rather than as this company's app.

**The constraint:** whatever is added must not take a pixel from the camera
or a millisecond from a scan. The band replaces the strip that is already
there; it does not stack above it.

## The rule this whole document is under

Everything here is secondary to the door. The scanner exists to answer one
question in under two seconds with the radio off, and a rota, a bell and a
chat thread are all things somebody does while *not* standing in front of a
queue. None of them may sit in the boarding path, hold a lock on the
redemption log, or run a timer while a verdict is on screen.
