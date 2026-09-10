# Agency customer — the ticket you print, and the door it opens

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`1950540`) · **Against:** dev stack (`billetenligne-dev`, Android emulator, `Africa/Brazzaville`)
**As:** a walk-in who paid cash at an Alizés counter — no account, no app, no smartphone —
holding booking `BEL-EC9FBP`, seat 11B, Juste Bouiti, on departure `546e6c92` (BZV → PNR,
Thu 10 Sep 06:00). Then as Armand Kibangou, the conductor, at the coach door.

The request this walk was made for:

> *"did you walkthrough the cash payment when the user go directly to the agency and the ticket is
> printed with the qr stamped on the ticket and they will present that … that ticket could be
> presented and will be scanned as a normal phone would be. this is the most likely path that will
> happen a lot, so we need that squared off."*

It was not walked before, and the reason it was not is written down in this repo: the counter
receipt's own doc comment said a printed QR **would be a frozen code that fails the check.** That
sentence was wrong, and it was the only thing standing between this market and its most likely
ticket.

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | print the pass ([01](01-three-passes-to-an-a4-sheet.jpg)) | Does `/b/{token}?format=boardingPass` lay a ticket out for ordinary paper? | ✓ — DL pass, three to an A4 sheet, cut line drawn |
| 2 | print a full page ([02](02-or-one-per-a4-page.jpg)) | Is there a format for an agency that hands over a whole sheet? | ✓ — `?format=a4`, code at 86 mm |
| 3 | open the departure ([03](03-the-conductor-opens-the-departure.jpg)) | Is the manifest pinned and the reader live? | ✓ — 1/6 already boarded, list synced |
| 4 | read the code off the paper ([04](04-the-code-off-the-paper.jpg)) | Does the string the printed QR encodes reach the reader? | ✓ |
| 5 | the verdict ([05](05-valid.jpg)) | Does a ticket printed on paper board a coach? | ✓ — **VALID · Juste Bouiti · 11B · EC9FBP** |

| 6 | read it back out of Postgres | Did the office learn that this seat boarded? | ✓ — see below |

## What the paper actually recorded

Read back out of Postgres afterwards, which is the only thing that settles it:

```
 seat_label |         scanned_at         | synced
------------+----------------------------+--------
 11B        | 2026-09-10 02:58:47.814+00 | t
```

The redemption was written on the handset the moment the verdict was drawn — before any network —
and drained to the server when the conductor next opened the departure. A coach in a dead zone
boards its passengers and the office finds out later, which is the same guarantee a ticket on a
phone gets.

## Why a printed QR boards, and a screenshot does not

Both claims are true at once, and the difference is the whole design.

`tickets.payload` is the complete signed string, and it carries **no freshness code**. The control
at the door is *one scan per seat* — the manifest records a redemption, and the second presentation
of the same seat is refused by name (ADR-0007, ADR-0026). So a ticket on paper verifies exactly
like a ticket on a screen, because there is nothing on it that can go stale.

The rotating six digits under the QR in the traveller app defend against a different thing: a
photograph of a **live** screen, passed to somebody who did not buy a seat. Those digits are only
ever *presented alongside* a scan; a printed ticket presents none, and `VerificationResult`
returns `valid` rather than `staleCode` for exactly that reason.

The proof that the square on the paper is the square the scanner accepts is not in this walk — a
screenshot cannot show that. It is in
`services/api/test/printed_ticket_page_test.dart`, *"the square on the paper is the square the
scanner accepts"*, which reads the rectangles back out of the drawn `<path>` and compares them
module for module against the encoder's own output for the same payload. Asserting that the payload
appears in the HTML would prove nothing: the payload is not in the HTML, only a drawing of it is.

## What the walk found

### 1. The counter receipt documented the opposite of the truth — fixed

`apps/console/lib/src/presentation/widgets/ticket_receipt.dart` said, in the class doc comment
future readers would take at face value:

> *"a printed one from this screen would be a frozen code that fails the check (ADR-0007)"*

It would not. Nothing in the codebase agreed with that sentence — `LinkedSeat.payload` says
"static — it cannot rotate on a page or in an inbox", and ADR-0026 is built on it. One stale
comment kept the most common sale in this market ending with a reference number instead of a
ticket. Corrected, with the reasoning that replaces it.

### 2. The default had to mean ordinary paper

"Boarding pass" as a format usually means a thermal printer and rolls of card, which an agency in
Dolisie does not have. So the default lays the pass out **three to an A4 sheet with a cut line**:
it costs a pair of scissors and a third of a page, and it is the format an agency can use on its
first day without buying anything. `?format=a4` is there for the counter that would rather hand
over a whole sheet as the receipt.

### 3. Colour prints here, unlike the traveller's own copy

The traveller's boarding pass strips the operator's hue on print — a station's printer is not owed
somebody else's cartridge. This page does not, because it is the operator's own stationery and
they asked for their header on it. The operator who would rather spend no ink chooses the
`economyPass` starter, which has no motif, no mark, and nothing to spend.

### 4. Still open: the vendor cannot print from the till

This walk printed from a ticket link, which is what a customer holds. A vendor at the counter has
no button for it yet — `sendTicketLink` deliberately never returns the URL, because a URL on a
till screen is a ticket anybody behind the customer can photograph. The next slice is a
short-lived print token minted by the console, so the vendor prints without a shareable link ever
existing.

### 5. Still open: the design is not yet the operator's own

`TicketDesign` exists, four starters exist, and `/b/{token}?format=` renders them — but an
operator cannot yet choose or edit one. The builder, and the row that stores their choice, are the
slice after that.
