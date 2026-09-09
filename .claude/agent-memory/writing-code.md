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

## Ordering of overlays decides which screen you actually see

**Tally: 1 — 2026-09-09 ("Loading payment methods…" forever, on the change/reschedule path).**

`app.dart` draws layers in order. The tickets layer was checked before the payment layer, so a
payment opened *from* a ticket rendered the ticket. It was not a hang; it was the wrong widget.

**Do instead:** when a screen never finishes loading, check what is actually mounted before
debugging the thing you think is loading. And keep the precedence rule **narrow** — the blanket swap
would have regressed "opened a ticket while a hold was counting down".

---

## Two `Expanded` buttons in a `Row` truncate whichever label is longer

**Tally: 1 — 2026-09-09 ("Cancel this c…").**

An even split is not a layout decision, it is the absence of one. Stack the buttons unless both
labels are short and known.
