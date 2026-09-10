# ADR-0034 — The ticket on paper

**Status:** Accepted · **Date:** 2026-09-09 · **Depends on:** ADR-0007, ADR-0010, ADR-0013, ADR-0026

## Context

ADR-0026 gave the walk-in a ticket they can *reach* — a link, in a message,
resolving to a page with a scannable QR on it. It assumed the customer has
somewhere to receive a message.

Most of them do not. The counter sale in this market is cash, across a desk,
to somebody with a feature phone or no phone, who will not install an app and
often cannot receive an email. The guichet already creates an unverified
account from the number the vendor types, and with SMS off in this market
until a sender number exists, that account **has no reachable channel at
all.** For that customer, ADR-0026 ends where it started: the ticket is
issued, signed, and unreachable.

They are not a fringe. They are the most likely ticket this product will ever
issue.

What stopped this being obvious was a **wrong sentence in the codebase.** The
console's counter receipt said, in its class doc comment:

> *"a printed one from this screen would be a frozen code that fails the check
> (ADR-0007)"*

It would not. Nothing else in the repo agreed with it — `LinkedSeat.payload`
says *"static — it cannot rotate on a page or in an inbox"*, and ADR-0026's
whole page is built on that. But it was the only prose anybody would read
before deciding whether printing was possible, and it said no.

### Why a printed QR boards and a screenshot does not

Both are true, and the difference is the design.

`tickets.payload` is a complete signed string carrying **no freshness code**.
The control at the door is *one scan per seat*: the manifest records a
redemption and the second presentation of the same seat is refused by name.
Nothing on a printed ticket can go stale, so `VerificationResult` returns
`valid`.

The rotating six digits under the QR in the traveller app defend against a
different attack: a photograph of a **live screen**, forwarded to somebody who
did not buy a seat. Those digits are only ever *presented alongside* a scan.
A printed ticket presents none, and is not `staleCode` for exactly that
reason.

## Decision

**1. The printed ticket is a first-class artefact, not a fallback.**
Rendered by `PrintedTicketPage` at `/b/{token}?format=…`. One URL, not two:
the vendor printing it, the cousin doing the collecting and the passenger at
the door all hold the same address, and a second one would be a second thing
to lose.

**2. The default format means ordinary paper.** "Boarding pass" normally
implies a thermal printer and rolls of card. An agency in Dolisie has an A4
inkjet and a ream of copier paper. So `boardingPass` lays the pass out **three
to an A4 sheet with a cut line** — a pair of scissors and a third of a page —
and `a4` gives one per sheet for the counter that hands over a whole page as
the receipt. The choice is made at the printer, by the vendor, not stored as
an operator setting.

**3. The design is the operator's, and it is data.** `TicketDesign` in
`bel_domain`: a format, one of the eight verified hues, one of the four
motifs, their mark, which optional lines to print, and a sentence of their own
at the foot. Stored per operator in `ticket_designs` as a JSONB document, with
four starters shipped as domain constants.

**Bounded, for the same reasons the vitrine is bounded and more so.** A ticket
is read by a machine in a yard at half past five. A free colour picker
guarantees somebody eventually prints a hue invisible in direct sun, or a dark
ground behind a code a cheap scanner refuses. A free layout guarantees
somebody eventually moves the QR under the fold. So an operator chooses among
bounded things, and everything that makes the ticket *work* is not theirs to
move.

**4. Tolerant on read, canonical on write.** `TicketDesign.fromJson` drops
what it does not recognise and never throws; the adapter stores what the
domain read back rather than what arrived. A build that meets a design saved
by a newer build prints a ticket. **A counter that cannot sell because a JSON
document gained a field is a counter that turns customers away**, and that is
a worse failure than printing last month's motif.

**5. Colour prints, unlike the traveller's own copy.** The ADR-0026 boarding
pass strips the operator's hue on print — a station's printer is not owed
somebody else's cartridge. This one does not: it is the operator's own
stationery and they asked for their header on it. The operator who would
rather spend no ink chooses the `economyPass` starter, which has none to
spend.

**6. Nothing on the page is fetched.** No stylesheet, no webfont, no image, no
script the ticket depends on. A print dialog that opens before a font arrives
lays out the wrong widths; an `<img>` that 404s leaves a white hole where the
company's mark should be, **on paper, where nobody can reload it.** The mark
is a drawn monogram, the weave is a `data:` URI, and the QR is inline SVG.

**7. The till gets a token, and it is the only place that does.**
`POST /console/v1/bookings/{ref}/print` returns a URL. `queueSend` still
refuses to, and the reason stands: a link on a counter screen is a ticket
anybody behind the customer can photograph. The exception is made as small as
it goes — **twenty minutes**, its own `print` channel, `sent_to` recording the
till rather than an address, never sent anywhere, and no revoking of the
customer's own emailed link.

## Consequences

**Good.** The most common sale in this market ends with something in the
customer's hand that boards a coach. No app, no address, no signal, no
smartphone. An operator's ticket carries their own name and colours, which is
what makes a company recognisable in a yard. And the artefact at the door is
still the one already proven: same signature, same scanner, same single-use
rule.

**Cost, and we own it.** A second renderer for the same ticket, which will
drift from the boarding pass unless somebody notices. A JSONB document whose
vocabulary lives in Dart rather than in constraints. And a print token that is
a real, if narrow, widening of what the console may hold.

**The guard that matters.** The whole feature rests on one claim: *the square
printed on the paper is the square the scanner accepts.* Asserting the payload
appears in the HTML would not prove it — the payload is not in the HTML, only
a drawing of it is. So `printed_ticket_page_test.dart` reads the rectangles
back out of the drawn `<path>` and compares them **module for module** with
the encoder's own output for the same string. An optimisation of `QrSvg` that
shifts a run by one module fails there rather than at a coach door.

**Walked, not assumed:** `docs/walkthroughs/agency-customer/the-ticket-you-print/`
— printed pass, conductor's reader, **VALID**, and the redemption row read
back out of Postgres with `synced_at` stamped.

**Watch for:** the design growing into a layout editor. It is a set of bounded
choices about a fixed layout. The moment an operator can move the QR, the
constraint that makes every ticket scannable has been traded for one that
makes most of them scannable.

**Still open:** the operator's uploaded logo is not on the printed ticket —
the monogram is, because `ticket_by_link()` does not return the asset and a
print page must be one request. Inlining it as a `data:` URI is the honest
fix, and it needs that function to return it.
