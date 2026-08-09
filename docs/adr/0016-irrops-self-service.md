# ADR-0016 — Disruption handling is operator self-service, modelled on airline IRROPS

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0011, ADR-0012, ADR-0015

## Context

Congo's road network makes disruption routine, not exceptional. On the RN1 corridor a breakdown, a washed-out section in the rainy season, a police checkpoint delay or a mechanical failure mid-route is a **weekly** occurrence for an operator with a dozen coaches. Realistic v1 assumption: **5–10% of departures are disrupted in some way.**

Two failure modes to avoid:

1. **Routing disruptions through BilletEnLigne support.** A dispatcher standing beside a broken-down coach on the RN1 at 04:00 cannot wait for our office to open. If our back office is in the loop, we become the bottleneck for the operator's core operational reality, we need 24/7 staffing we cannot afford, and operators will conclude the platform makes their life worse.
2. **Inventing our own vocabulary.** This problem is fully solved in aviation and rail. Building something bespoke means rediscovering, badly, thirty years of edge cases.

## Decision

**Adopt the airline IRROPS (Irregular Operations) model**, adapted to intercity coach, and put the entire toolset in the **operator console** — self-service, mobile-capable, with **zero BilletEnLigne involvement in the normal path.**

### Vocabulary we adopt (standard, not invented)

| Term | Meaning here |
|---|---|
| **Disruption event** | The operational fact: breakdown, delay, cancellation, equipment downgrade, diversion. |
| **Involuntary change** | A change caused by the operator. **No fee, no fare difference, ever.** The distinction from a voluntary change is the single most important concept in this design. |
| **Re-accommodation** | Moving affected passengers onto alternative departures. |
| **Protection** | Re-accommodating onto **another operator's** departure. In aviation this is interline; here it is an inter-operator agreement, and it is common practice at Congolese gares already — informally, in cash. We formalise it. |
| **Transboarding** | Physically moving passengers from a failed coach to a replacement mid-route. A rescue/equipment swap on the same booking. |
| **Downgrade / equipment swap** | A 60-seater replaced by a 45-seater — produces **displaced passengers** (ADR-0012). |
| **Rebooking wave** | The batch operation that applies a re-accommodation plan to all affected passengers at once. |
| **Duty of care** | What the operator owes stranded passengers (meal, overnight). Recorded, not enforced by us. |

### The design in one rule

> **The operator declares the event. The system generates the options. The passenger chooses, or the policy chooses for them.**

The dispatcher's job is to state a fact — *"coach BZ-4471 has broken down at km 180"* — not to solve 47 individual passenger problems. The system does the combinatorics.

### Involuntary changes bypass the refund policy entirely

An operator-caused disruption triggers the **platform floor** (ADR-0015): full refund to source on request, no fee, regardless of what the operator configured. Rebooking onto any alternative is free even if the alternative costs more. Operators cannot configure their way out of their own breakdown, and this is stated in the operator agreement.

This is deliberately non-negotiable, because it is the promise that makes travellers willing to prepay for a bus in a country where buses break down.

### Where BilletEnLigne *does* get involved

Only three places, all exceptional:

1. **Inter-operator protection settlement** — money moving between two operators runs through our ledger, because neither trusts the other's arithmetic. Automatic; no human unless it fails.
2. **An operator who never resolves a disruption.** If a disruption is left unresolved past the departure time + 2 h, the system **auto-refunds every affected passenger in full** and flags the operator. That is a backstop, not a workflow.
3. **Disruption-rate monitoring.** Chronic disruption is a quality signal that affects search ranking and, eventually, the commercial relationship.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Support-ticket driven (we handle it)** | 24/7 staffing, we become the bottleneck, operators resent us. Rejected. |
| **Cancel-and-refund only** | Trivially simple, and it destroys the traveller's day — they wanted the trip, not the money. Also maximally expensive for the operator. Rejected as the *only* option; retained as one option among several. |
| **Fully automatic re-accommodation, no passenger choice** | Fast, and wrong. A passenger who needs to arrive tonight and a passenger who can go tomorrow want opposite things. Rejected as mandatory; **offered as a default the passenger can override.** |
| **Bespoke model** | Rejected — IRROPS already encodes the edge cases. |

## Consequences

Disruption tooling is a **P0 launch feature, not a phase 2**. Launching without it means the first breakdown becomes a support crisis and the anchor operator's first impression of the platform is that it cannot cope with Tuesday.

It must work on a **phone, on 2G, at the roadside**, because that is where the dispatcher will be. The disruption flow gets the same offline-first treatment as boarding (ADR-0003): declare the event offline, queue the plan, sync when coverage returns.
