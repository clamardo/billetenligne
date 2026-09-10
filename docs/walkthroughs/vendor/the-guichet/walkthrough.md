# Vendor — the guichet

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`), console at `http://localhost:5000`
**As:** Perside Bantsimba (`perside@demo.billetenligne.cg`, `vendor` at Alizés Transport SARL, scoped
to Gare routière de Mikalou) in the operator console.

Walked because a journey taken as the owner proves almost nothing about the product: the owner holds
every capability there is, and the whole point of ADR-0011 is that most people do not.

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | sign in and land ([01](01-what-a-vendor-is-given.jpg)) | Is the rail cut to what a vendor holds — absent, not greyed? | ✓ — Today · Counter · Terms · Agreements, and nothing else |
| 2 | the same screen ([01](01-what-a-vendor-is-given.jpg)) | Does the empty state point somewhere a vendor can go? | ✗ — [below](#1-the-empty-state-sends-a-vendor-to-a-tab-vendors-do-not-have) |
| 3 | Counter ([02](02-the-counter.jpg)) | Are the four counter jobs there, and does the first one explain itself? | ✓ — Collect a code · Counter sale · Refund · Missed coach |
| 4 | the payment-code field ([02](02-the-counter.jpg)) | Does it say what shape the code is before it is wrong? | ✓ — *"The code is five characters"*, with `K4M2Q` as the ghost |

## What the walk found

### 1. The empty state sends a vendor to a tab vendors do not have

*"No departures on this day — **Publish a timetable from the Timetables tab** to put departures on
sale."*

There is no Timetables tab on this screen. There cannot be: publishing a timetable needs
`fleet.write`, which is exactly what a `vendor` does not hold, and the rail beside the sentence is
four items long. The copy was written for whoever would most plausibly see an empty day — and the
person who actually sees it most is the one standing at the counter at 06h00 wondering whether the
system is broken.

The right sentence for a vendor says who to ask, not which button to press. Not changed in this pass
because it needs a catalog entry per audience rather than one reworded string, and that is a copy
decision (ADR-0008 puts the sentence on the client, so it can legitimately differ by capability).

### 2. A vendor's day was empty because the demo world's coaches run tomorrow

Secondary, and a seeding observation rather than a defect: `09/09/2026` had no departures at all,
because `DemoWorld` builds its coaches for the following day. It is what made finding #1 visible, so
it is worth keeping — but a vendor persona whose first screen is always blank is a poor demo, and the
seeder should put at least one coach on the current day.

## What was deliberately not chased

**Actually taking cash.** Collecting a code needs a live payment code from a traveller who chose
*pay at the counter*, and the traveller walk paid by mobile money. That is a second traveller journey
to seed, and it belongs with the counter's own slice.
