# Traveller — the ticket at the door

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`, Android emulator)
**As:** Chancelvie Okemba (`voyageur@demo.billetenligne.cg`) on **My tickets**, holding `BEL-K195CM`,
seat 10A, Alizés Transport SARL, BZV → PNR, Thu 10 Sep 06:00.

The half of the request that is about what the conductor is actually shown:

> *"…where you will record a traveller QR and then stamp that to the bus driver QR scanner."*

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | My tickets ([01](01-my-tickets.jpg)) | Does a ticket survive a restart of the app, with no session re-entry? | ✓ |
| 2 | open it ([02](02-the-ticket-that-was-scanned.jpg)) | Is the boarding point on the ticket, in the operator's own words? | ✓ — *Gare routière de Mikalou · portail bleu, en face de la station-service* |
| 3 | the code ([03](03-the-code-and-the-rolling-check-code.jpg)) | Is the QR a real payload, and is there something a conductor can use when the screen will not scan? | ✓ |
| 4 | decode the QR **optically**, off the screenshot | Does the printed code parse as `TicketPayload`, with the signature it claims? | ✓ |

## What the walk found

### 1. The QR on the screen is the payload, and it was proved by reading it as a camera would

The QR was decoded from the screenshot with `zxing2` rather than read out of the database. What came
back was the ADR-0007 string —

```
1|BEL|K195CM|10A|<departureId>|<epoch>|BZV-PNR|DEMO-ALZ|Chancelvie Okemba|<keyId>.<sig>.<615963>
```

— and it is that exact string, typed into the conductor's scanner, that produced **VALID** in the
[next walk](../../conductor/boarding-and-the-road/walkthrough.md). Nothing in this loop was taken
from Postgres and handed to the reader; the round trip went screen → optics → scanner.

### 2. The rolling check code is a real TOTP, not decoration

`615 963`, with a ring counting down and *"It changes every 30 seconds. Show the screen, not a
screenshot."* It is the third, optional segment of the payload, and the scanner records
`code_was_stale` against the redemption when it is out of date — which is how a conductor waving
through a photograph of somebody else's ticket becomes visible afterwards rather than invisible.

## What was deliberately not chased

**The offline case on the traveller side.** A ticket that has never been opened while online has
nothing to draw; that is the app's own cache behaviour and it needs an aeroplane-mode walk of its
own.
