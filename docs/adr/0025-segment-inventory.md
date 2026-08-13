# ADR-0025 — A seat's occupancy is a range, not a state

**Status:** Accepted · **Date:** 2026-08-13 · **Depends on:** ADR-0011, ADR-0023

## Context

The Brazzaville–Pointe-Noire coach passes through Dolisie, and every operator
running it already sells the Dolisie leg — informally, at the roadside, from a
notebook. The road itself now exists in the schema: `route_stops` carries the
towns, their order and their offsets, and the traveller sees them on the search
row.

What does not exist is a way to buy a piece of one. The reason is a single
column:

```sql
seats (departure_id, seat_label, state seat_state, hold_id, booking_id, …)
```

`state` is a scalar, and the question segment selling asks is not scalar. Seat
12A sold Brazzaville→Dolisie and free Dolisie→Pointe-Noire is **one row with
two answers**, and there is no value of an enum that means both.

Everything downstream inherits that shape. The search counts
`state = 'available'`. The seat map colours from it. The hold sweeper reads it.
The manifest, the scanner, the rescue coach, the rebooking wave and the
inter-operator movement all ask "is this seat free?" and expect one answer for
the whole journey. So this is not a feature that can be added at the edge; it
is a change to what a seat *is*.

## The options we rejected

**A row per seat per leg.** `seats` keyed by `(departure, seat, leg)`. Simple
to query and simple to get wrong: a fifty-seat coach with four stops becomes
two hundred rows per departure, a hold takes N row locks instead of one, and
the day an operator inserts a stop the history re-numbers underneath every
booking ever sold. It also makes the commonest case — the whole road, which
is most sales — the most expensive one.

**A bitmask over legs.** `occupied_legs BIT VARYING` on the seat row. Compact,
one row, no join. And unreadable: every availability query becomes bit
arithmetic, the constraint that two bookings do not overlap cannot be
expressed to the database at all, and a stop added in the middle shifts every
bit in every row that already exists. A model whose invariant can only be
enforced in application code is a model whose invariant will eventually not
hold.

**A `segments` column on `bookings` alone,** leaving inventory whole-road.
This is what a first attempt usually looks like, and it sells the same seat
twice on the first busy Friday: if inventory does not know about the segment,
nothing stops a second sale.

## Decision

**Occupancy is a half-open range of stop positions, held in its own table, and
the no-overlap rule is a database constraint.**

```sql
CREATE TABLE seat_occupancy (
  departure_id UUID NOT NULL,
  seat_label   TEXT NOT NULL,
  span         INT4RANGE NOT NULL,     -- [from_position, to_position)
  hold_id      UUID,
  booking_id   UUID,
  …
  EXCLUDE USING gist (
    departure_id WITH =, seat_label WITH =, span WITH &&
  )
);
```

Three consequences, and each is the reason for the choice.

**Two people cannot buy the same piece of the same seat.** Not because a
handler checks — because Postgres refuses to write the second row. That is the
same shape as the append-only trigger on `ledger_entries` and the deferred
balance check on a transaction: the guarantee is *executed*, not reviewed. The
overlap check is exactly the operation a GiST exclusion constraint exists for,
and it is index-backed, so it costs a lookup rather than a scan.

**A stop added tomorrow does not re-number what was sold yesterday.** Positions
come from `route_stops.sequence`, which is server-assigned and already
stable — and a departure captures the road it was sold on, so a route edited
next month leaves last month's manifests alone. Renumbering was the failure
mode in both rejected options.

**Half-open, always.** `[0,2)` and `[2,4)` do not overlap, which is the whole
point: a passenger alighting at Dolisie and one boarding at Dolisie share no
part of the journey, and a closed range would have them fighting over a stop
neither of them occupies.

### The whole road is a range too

There is no special case for an ordinary sale. A departure whose route has N
sellable positions has a whole-road span of `[0, N)`, and a normal booking
writes exactly that. One model, one code path, one constraint — a design where
"the usual case" bypasses the new machinery is a design where the new
machinery is untested in production.

### `seats.state` stays, and stops being written by hand

Every existing reader — search counts, the seat map, the sweeper, manifests,
the scanner, the rescue coach — keeps working, because `state` remains on the
seat row. What changes is who writes it: it becomes **derived from
`seat_occupancy` by trigger**, never set by a handler. Two sources of truth is
the failure this decision exists to avoid, and the way to have one source of
truth and a fast read is a derived column the database maintains.

`seat_state` gains one value, `partial`: some of the road is taken and some is
not. Old readers asking "is this available?" get the honest answer — no, not
all of it — and readers that care about a particular leg ask the occupancy
table. **A reader that has not been taught about segments therefore fails
closed**, which is the only acceptable direction for a change to inventory.

### Priced, never pro-rated

A segment is sellable only when the operator has **priced it**. There is no
distance-based fraction of the through fare, because a fare is a commercial
decision and an operator who finds we invented one will find it on the day a
passenger paid it. Unpriced pairs are simply not offered.

The consequence is the property that makes this shippable: **until an operator
prices a segment, nothing changes.** Every departure sells its whole road for
its whole fare exactly as it does today. The feature arrives switched off by
the absence of data rather than by a flag, which is the same shape as a
payment rail shipped without credentials.

### Boarding and alighting are already answered

`route_stops.allows_boarding` and `allows_alighting` predate this and are
respected: a set-down-only stop can end a segment and cannot start one. This
is the detail every naive model gets wrong and every operator notices in the
first hour.

## Consequences

- `btree_gist` becomes a required extension, for the `=` parts of the
  exclusion constraint. It ships with Postgres; it is not a dependency in any
  meaningful sense.
- Every writer of `seats.state` — the claim, the capture, the release, the
  sweeper, the rescue remap, the protection movement — moves to writing
  occupancy. That is the cost of the decision and it is paid once.
- A manifest becomes a list with boarding and alighting points rather than a
  list of names, and the scanner's verdict gains a leg. Both are follow-on
  work, and both are strictly additive to what exists.
- The traveller-facing search gains segment results only for priced pairs, so
  the wording that says *via* rather than *arrêt desservi* can finally change
  for the roads where it is true.
