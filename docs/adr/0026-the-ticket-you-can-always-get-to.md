# ADR-0026 — The ticket you can always get to

**Status:** Accepted · **Date:** 2026-08-13 · **Depends on:** ADR-0007, ADR-0014, ADR-0019, ADR-0024

## Context

A ticket is only worth what the person holding it can get to at the coach
door. Today there are two ways to reach one, and both of them assume a phone
with our app on it:

* the traveller app's *Mes billets*, which needs a sign-in; and
* a plain-text email or SMS that says, in effect, **"your ticket is in the
  app"** — no QR, no link, and nothing a conductor can scan.

That is fine for somebody who bought on their own handset. It is not fine for
the person this market is actually full of: the walk-in at an agency counter.
The guichet already does the right thing structurally — a counter sale creates
an **unverified user account** from the phone number the vendor types, so the
booking has an owner and agency sales reconcile against digital ones instead
of being two ledgers with a spreadsheet between them. But that account has no
password, no verified channel, and — with SMS switched off in this market
until a sender number exists — **no way to be reached at all**. The ticket is
issued, signed, and unreachable except on paper.

Three more facts shape the answer:

* `trip_shares` (ADR-0014) already proves the pattern we need: a
  single-purpose token, stored **only as a hash**, resolving anonymously to
  exactly one booking, expiring, revocable, and served both as JSON and as a
  server-rendered page at `/t/{token}` for people who hold no account.
* The ticket QR is self-contained and signed (ADR-0007). It does not need us
  to be reachable to be verified — which is why a link that merely *displays*
  it is a complete product rather than a stopgap.
* Sign-in by one-time code to a channel already exists end to end (ADR-0024).
  Anything that needs to be stronger than "holds the link" can reuse it rather
  than invent a second authentication system.

## Decision

**One link, sent once, that opens the ticket.** `blt.cg/b/{token}` — `b` for
*billet*, kept clear of `/t/` which is the follower page and a different
promise. Android App Links and iOS Universal Links claim the path, so the app
opens it when installed and the server renders it when not. One URL, because
minting an "app link" and a "web link" turns every support call into *which of
the two did we send you*.

### The token is the credential for seeing, and nothing else is

No name-and-date-of-birth gate. Those are semi-public, guessable, and
shoulder-surfable; they add friction a real customer feels and an attacker
does not. What protects the ticket is the token: 128+ bits, single-purpose,
expiring, revocable, and stored only as a hash — a database dump cannot
reconstitute a live link. The booking reference is **never** accepted here:
six characters is an enumeration, not a credential.

### Seeing and changing are different acts

Viewing costs the link. Changing anything that moves a seat or moves money
takes a **one-time code to the channel the ticket was delivered on**, which
upgrades the anonymous link session into an ordinary traveller session.
Possession of a link that arrived by SMS is weak evidence of identity;
possession of a code sent to that number *just now* is strong evidence, and we
have the whole flow already.

That step-up **claims the booking**: the unverified account the counter
created becomes a verified one the traveller holds. This is the highest-value
line in the feature — it is how a walk-in becomes an app user without anybody
selling them anything.

### The static QR is the same artefact as the printed ticket

The rotating 30-second code (ADR-0007) defends against a ticket forwarded in
advance. A QR in an email, on paper, or on a web page cannot rotate, and
pretending otherwise would be theatre. The control at the door is **one scan
per seat**, which the scanner already enforces through its redemption log —
so a link-displayed ticket is exactly as strong as the printed one an agency
hands over today, and no weaker.

### The counter never offers a channel it cannot send on

SMS is built and off in this market. The vendor's screen reads the market
config and offers only live channels. A tick-box that silently does nothing is
worse than no tick-box.

### The link never offers what it cannot finish

A cash sale cannot be refunded to a card. The page offers what the booking's
own terms and rails allow, and where a refund cannot be paid it names the
agency instead of showing a button that ends in an apology.

### Tenancy is unchanged

A vendor may mint a link only for a booking their own operator sold. It is the
same rule as everything else on the console surface, and it is enforced where
every other one is: the tenant policy, not the handler.

## Consequences

**Good.** The walk-in customer — the majority of this market — gets a ticket
they can reach, on a device they already have, without installing anything.
Losing a phone stops being losing a ticket. The counter gains a growth path
into accounts that costs the vendor one question. And the artefact at the door
is the one already proven: same signature, same scanner, same single-use rule.

**Cost, and we own it.** A second token table to keep correct, a second HTML
page to render server-side, and an email that now carries an image — which
means the notification gateway grows an HTML body and an attachment, having
been plain text since the first month.

**Watch for:** the link growing into an account. It shows one booking. The
moment it starts listing *other* bookings or payment history, it has become a
session without a sign-in, and the token was never strong enough for that.
