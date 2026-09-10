# Walkthroughs

**What a journey actually looks like, to the person taking it.** One directory per persona, one per
journey beneath it, numbered screenshots in the order they were taken, and a `walkthrough.md` saying
what was checked and what it found.

## Why these exist

The second factor did not exist. `SecondFactorSignIn.isRequiredFor` says every member of staff must
prove an authenticator, and no member of staff had ever been asked — not an operator's owner, not a
conductor, not our own reviewers — because the sign-in query built its `Account` from an upsert's
`RETURNING` row, which cannot see the joins that carry `staff.roles`. Four apps, a full integration
suite and a green migration ledger sat over it. Signing in **once**, as a person, found it in ninety
seconds, and then found a compliance screen that had been 404ing under a *"Nothing to chase"* while
an operator's insurance lapsed.

> A green suite says the parts work. Only a journey says the door opens.

## Two rules

1. **Overwrite; do not accumulate.** One walk per journey — the latest. Screenshots are binary; a
   repo that keeps every walk grows without bound and never gets pruned, because nobody can tell
   which images still describe the product. The build stamp in each `walkthrough.md` is what makes a
   stale one detectable, and git history keeps the old one if anybody wants it.
2. **Seeded personas on dev or test. Never production, and never a real person.** Everything in this
   folder comes from `DemoWorld` (`services/worker/lib/src/demo_world.dart`) against the local
   `billetenligne-dev` stack. A defect found against real data is still reported the ordinary way —
   in prose, with the evidence described. It is not photographed into the repository.

   Which puts the weight on the seeder, and that is where it belongs: if a persona cannot be walked
   because the demo world has nobody like them, seed one. Eleven of the sixteen operator staff below
   were seeded *for* these walks.

## Walked so far

| Persona | Journey | Last walked | Build | Findings |
|---|---|---|---|---|
| [traveller](traveller/buying-a-seat/walkthrough.md) | buying a seat | 2026-09-09 | 0.1.0+1 · `0a6c851` | 0 — search to signed ticket, on a handset, against real Postgres |
| [traveller](traveller/the-ticket-at-the-door/walkthrough.md) | the ticket at the door | 2026-09-09 | 0.1.0+1 · `0a6c851` | 0 — the QR was decoded **optically** and is the payload it claims to be |
| [agency-customer](agency-customer/the-ticket-you-print/walkthrough.md) | the ticket you print | 2026-09-09 | 0.1.0+1 · `1950540` | 2 — the counter receipt **documented the opposite of the truth** about printed QRs (fixed); a vendor still cannot print from the till |
| [conductor](conductor/boarding-and-the-road/walkthrough.md) | boarding, the road, closing the departure | 2026-09-09 | 0.1.0+1 · `0a6c851` | 4 — the **second factor was never asked for** (P1, fixed), the scanner said "Offline" while online (fixed), no way to drive it without a camera (fixed), and "today" with no clock |
| [operator-owner](operator-owner/the-days-board/walkthrough.md) | the day's board, and who works here | 2026-09-09 | 0.1.0+1 · `0a6c851` | 1 — the navigation rail overflows by 36px on a 900px screen, for owners only |
| [vendor](vendor/the-guichet/walkthrough.md) | the guichet | 2026-09-09 | 0.1.0+1 · `0a6c851` | 2 — an empty state that sends a vendor to a tab vendors do not have, and a seeded day with no coaches on it |
| [platform-reviewer](platform-reviewer/the-queue-and-the-calendar/walkthrough.md) | the queue, the roster and the expiry calendar | 2026-09-09 | 0.1.0+1 · `0a6c851` | 3 — **Compliance 404ing under "Nothing to chase"** (P1, fixed), a funnel that counts one channel silently, and a reviewer identified by UUID |
| [platform-viewer](platform-viewer/what-an-analyst-may-read/walkthrough.md) | what an analyst may read | 2026-09-09 | 0.1.0+1 · `0a6c851` | 1 — a viewer landed on a screen their own rail did not offer (fixed) |

**Two of the eleven findings are the same defect wearing different clothes**, and it is the one worth
remembering: *a permission or transport failure rendered as "there is nothing here."* The compliance
calendar said **Nothing to chase** while a licence had lapsed. The viewer's landing screen said
**Nothing in this view** while two applications waited. Neither would ever have been reported,
because both answered the question that was asked.

## The personas

Every one is seeded, and they are kept because a journey walked as an owner proves almost nothing —
the owner holds every capability there is, and ADR-0011 exists because most people do not.

| Persona | Who | Holds |
|---|---|---|
| traveller | Chancelvie Okemba (`voyageur@`) | no account until the seat is held (ADR-0013) |
| conductor | Armand Kibangou (`armand@`) | `conductor` at Alizés, one station — `boardingScan` + `departureClose` |
| driver | Blaise Samba (`blaise@`) | `driver` — `departureClose` only |
| operator-owner | Angèle Mbemba (`angele@`) | `org_owner` at Alizés |
| vendor | Perside Bantsimba (`perside@`) | `vendor` at Gare routière de Mikalou |
| platform-reviewer | BEL — direction (`direction@`) | platform `super_admin` |
| platform-viewer | BEL — lecture (`lecture@`) | platform `viewer` |

Seeded and **not yet walked**: `org_admin` (Nadège Ekondzo), `finance` (Thierry Ngouabi),
`fleet_manager` (Sylvain Ibara), `dispatcher` (Carine Mabika), `station_manager` (Gaston Nkodia),
`viewer` (Aline Mouko), the operator-invented custom role **Chef d'escale** (Edwige Nsondé), the
platform `operations` role, and Kouilou Voyages' own four — including Fabrice Loemba, who is
conductor *and* driver on the same coach.

## How to walk one

The stack, verbatim, is [`run-local-stack`](../../.claude/skills/run-local-stack/SKILL.md); the ways
it goes wrong are in [`running-the-stack.md`](../../.claude/agent-memory/running-the-stack.md). Two
things are needed on top of it and are easy to lose:

- **Every demo staff account shares one authenticator secret**, `demoTotpSecret` in `demo_world.dart`,
  enrolled and confirmed by the seeder. Any TOTP tool with that secret produces the code the back
  office asks for.
- **Sign-in codes arrive in Mailpit**: `curl -s 'http://localhost:8025/api/v1/messages?limit=5'`, and
  match on the recipient rather than taking the newest.
