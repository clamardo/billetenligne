# Operator owner — the day's board, and who works here

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`), console at `http://localhost:5000`
**As:** Angèle Mbemba (`angele@demo.billetenligne.cg`, `org_owner` at Alizés Transport SARL) in the
operator console.

The half of the request that is about the office rather than the road:

> *"please also check the web app for backoffice and company staff and traveller with all the
> persona possible by adding person seed data."*

The question this walk answers: after the conductor closed the departure on a handset, does the owner
see it — and is what she sees the same trip.

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | sign in ([01](01-the-console-asks-for-an-address.jpg)) | Address, then a six-digit code by email. | ✓ |
| 2 | second factor ([02](02-and-for-the-authenticator.jpg)) | Is the authenticator asked of an owner? | ✗ then ✓ — same P1 as the [conductor's walk](../../conductor/boarding-and-the-road/walkthrough.md#1-the-mandatory-second-factor-was-never-asked-for--p1-fixed) |
| 3 | Today ([03](03-todays-board.jpg)) | Do the counters agree with what the handset did? | ✓ — 3 Departures · 6 Sold · 141 Free; the 06h00 BZV-PNR reads **Arrived** |
| 4 | the day ([04](04-the-day-in-detail.jpg)) | Are Manifest / Crew / Close departure offered per row, by state? | ✓ — the arrived coach offers no Close; the two later ones do |
| 5 | Manifest ([05](05-the-manifest.jpg)) | Is the scan visible from the office, against the right seat and the right person? | ✓ — *6 sold · 1 boarded · 49 seats*, crew named, **10A Chancelvie Okemba K195CM** ticked |
| 6 | Personnel ([06](06-the-personnel.jpg)) | Are all eleven staff there, with their scope, including a role the operator invented? | ✓ — Edwige Nsondé wears **Chef d'escale** at Gare routière de Mikalou |
| 7 | shrink to 900px ([07](07-the-rail-overflows-at-900px.jpg)) | Does the navigation rail survive a laptop? | ✗ — [below](#1-the-navigation-rail-overflows-by-36-pixels-on-a-900px-screen) |

## What the walk found

### 1. The navigation rail overflows by 36 pixels on a 900px screen

`A RenderFlex overflowed by 36 pixels` on the console's rail, visible in the corner of
[05](05-the-manifest.jpg), [06](06-the-personnel.jpg) and [07](07-the-rail-overflows-at-900px.jpg) as
the yellow-and-black debug band Flutter paints in debug builds.

An owner's rail has eleven destinations plus three trailing controls (theme, language, second
factor). At 900 CSS pixels of viewport height — a 13" laptop with a browser chrome on it, which is
what an operator's office actually has — the column does not fit and the last control is clipped.
Everybody below `org_owner` has a shorter rail and never sees it, which is why it has survived: the
person most likely to hit it is the one least likely to file a bug about their own product.

Not fixed in this pass. It is a layout decision (scroll the rail, or drop `labelType: all` below a
height) rather than a one-line correction, and it wants a design answer.

### 2. The office and the road agree, exactly

This is the finding worth writing down even though nothing is wrong with it. The manifest's *1
boarded* is the redemption row the scanner wrote; the **Arrived** chip is the state the conductor
moved it to; the crew line is the `departure_crew` rows assigned before the day started. Two apps,
one handset and one browser, never talking to each other except through Postgres, describing one
trip in the same words.

## What was deliberately not chased

**Everything the rail offers that this journey does not touch** — Fleet, Routes, Timetables, Terms,
Storefront, Payouts, Billing, Agreements. They have their own slices and their own suites; a walk
that opens eleven tabs proves less about any of them than one walk that follows a single seat.
