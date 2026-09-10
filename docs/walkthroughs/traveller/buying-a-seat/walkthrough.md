# Traveller — buying a seat

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`, API `http://localhost:8080`, Android emulator)
**As:** nobody, then Chancelvie Okemba (`voyageur@demo.billetenligne.cg`) on the traveller app.

The request this walk was made for:

> *"please check the driver and traveller journey from the app perspective, where you will record a
> traveller QR and then stamp that to the bus driver QR scanner to see if it validates."*

This half is the front of it: does somebody with no account get from a search box to a ticket, and
does the money actually move. The scan is [the conductor's walk](../../conductor/boarding-and-the-road/walkthrough.md).

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | open the app ([01](01-the-search-screen.jpg)) | Does browsing start without an account at all (ADR-0013)? | ✓ |
| 2 | BZV → PNR, Thu 10 Sep ([02](02-two-coaches-on-the-day.jpg)) | Are the coaches the ones in Postgres, and are both operators there? | ✓ — Alizés 06:00 XAF 12,300 · Kouilou 07:30 XAF 11,300 |
| 3 | pick the 06:00 ([03](03-the-seat-map.jpg), [04](04-a-seat-held.jpg)) | Does the seat map draw the real layout, and does tapping a seat hold it? | ✓ |
| 4 | continue ([05](05-an-email-address-is-asked-for.jpg), [06](06-the-six-digit-code.jpg)) | Is the account asked for **after** the seat is held, not before? | ✓ |
| 5 | passenger details ([07](07-who-is-travelling.jpg), [08](08-the-seat-is-reserved.jpg)) | Is the booking `pending_payment` with the seat already ours? | ✓ |
| 6 | mobile money, `060000001` ([09](09-mobile-money.jpg), [10](10-waiting-on-the-rail.jpg)) | Does the screen poll rather than sit, and does the fake rail settle? | ✓ |
| 7 | settled ([11](11-paid.jpg), [12](12-the-ticket.jpg)) | Is a signed ticket issued on settlement, with a QR on it? | ✓ |

## What the walk found

### 1. Nothing. The funnel works end to end, on a handset, against real Postgres.

Search, hold, sign-in-at-the-last-moment, passenger, payment, ticket. Every screen drew what the
database held: two operators, the fare in XAF, the seat map from `seat_layouts`, and a ticket whose
QR carries a real Ed25519 signature.

Worth recording because it is the one thing no suite proves: the integration suite proves each
adapter, and the widget suites prove each screen, and neither has ever pressed **Pay** on a phone.

### 2. The magic MSISDN is not discoverable, and it is the whole demo

`060000001` settles one poll later; `060000000` declines; **every other number leaves the payment
pending forever**, which reads exactly like a broken poller. That is now the first thing in
[`running-the-stack.md`](../../../../.claude/agent-memory/running-the-stack.md), because it cost an
hour the first time.

## What was deliberately not chased

**The screens below the fold on the results page.** The illustrated empty state
([02](02-two-coaches-on-the-day.jpg), *"That is every coach on Thu 10 Sep"*) is the work of an
earlier slice and was left as it is; this walk was about the path to a ticket.
