# Platform viewer — what an analyst may read

**Walked:** 2026-09-09 · **Build:** 0.1.0+1 (`0a6c851`) · **Against:** dev stack (`billetenligne-dev`), back office at `http://localhost:5001`
**As:** BEL — lecture (`lecture@demo.billetenligne.cg`, platform `viewer`) in the platform back
office.

Walked immediately after [the reviewer's walk](../../platform-reviewer/the-queue-and-the-calendar/walkthrough.md),
on the same screens, for the contrast: `viewer` holds `booking.read` and `finance.read` and neither
of the two capabilities the back office is mostly built from.

| # | Step | What was checked | Result |
|---|------|------------------|--------|
| 1 | sign in and land ([01](01-a-viewer-landed-on-a-screen-they-cannot-open.jpg)) | Is the first screen one this person can actually open? | ✗ then ✓ — [below](#1-a-viewer-landed-on-the-application-queue-they-are-not-allowed-to-see) |
| 2 | the same ([02](02-and-now-lands-on-one-they-can.jpg)) | And after the fix? | ✓ — lands on Payouts, no banner |
| 3 | the rail ([02](02-and-now-lands-on-one-they-can.jpg)) | Are the four forbidden sections absent rather than greyed (ADR-0011)? | ✓ — two tabs: Payouts, Funnel |
| 4 | Payouts ([03](03-the-payout-queue-an-analyst-may-read.jpg)) | Can an analyst read the queue without holding the authority to move it? | ✓ — the queue renders, with no approve control |

## What the walk found

### 1. A viewer landed on the application queue they are not allowed to see

The first screen after sign-in was **Applications** — a section the rail beside it did not even
offer — carrying a red *"You do not have access to this action."* over an empty state reading
*"Nothing in this view. New applications appear here, oldest first."* Two applications were in fact
waiting.

The rail and the body were being built from two different lists. `AdminShell._visibleSections`
filtered destinations by capability; `AdminWorkspace._section` still held its default,
`AdminSection.queue`, and the body drew whatever that said. The shell noticed the disagreement —
`index < 0 ? 0 : index` highlighted the first tab — and papered over it in the rail only.

Fixed by moving the list onto the workspace as `AdminWorkspace.sections` (it is a capability decision,
not a layout one) and having `start()` move `_section` to the first section this person can open
before the first load. `AdminShell` now reads that one list. Guarded by *"a viewer lands on a section
they can open"* in `apps/admin/test/admin_widget_test.dart`.

**Same shape as the compliance defect one directory over**: a permission failure rendered as *there
is nothing here*. Both screens told a true-sounding lie, and neither would have been reported by
whoever saw it.

### 2. The rail rule holds, and it is the reason this persona is worth walking

Four sections absent — not greyed, not 403ing on tap. That is what ADR-0011 asks for and it is
correct here. It is also what hid finding #1: a rail with the right two tabs on it looks so obviously
right that nobody looks at the body beside it.

## What was deliberately not chased

**The `operations` platform role.** It sits between these two — it reviews and reconciles but does
not hold `finance.read` — and it is a third walk rather than a variation on this one.
