# ADR-0015 — Refund, reschedule and fee policies are data, configured by the operator

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0004

## Context

Operators do not agree on refund rules, and they should not have to. One will refund 100% up to 48 h before departure; another refunds nothing but allows a free reschedule; a third will only refund **in cash, in person, at the agency that sold the ticket** — which is not an edge case here, it is a completely reasonable stance for a business whose treasury is physical cash.

Requirement: the operator configures this themselves through a wizard, and the traveller sees the resulting rule in plain language *before* paying.

If these rules live in code, every operator we sign becomes an engineering ticket, and the marketplace stops scaling at about five operators.

## Decision

**Policies are versioned data**, authored by the operator, evaluated by a pure function in `bel_domain` that both the app and the server call (ADR-0004).

```dart
final class RefundPolicy {                    // stored as JSONB, versioned, immutable
  final PolicyId id;
  final int version;
  final List<RefundTier> tiers;               // ordered by lead time, descending
  final RefundDestination destination;        // source | agency_cash | credit_note | operator_choice
  final Duration? processingWindow;           // what we promise the user
  final bool refundServiceFee;                // is OUR fee refundable
  final Money? minimumRetained;               // floor
  final List<String> nonRefundableFareCodes;  // promo fares
}

final class RefundTier {
  final Duration minLeadTime;   // e.g. 48h
  final Percentage refundRate;  // e.g. 100%
  final Money? flatFee;         // e.g. 500 XAF admin fee
}
```

Evaluation is one pure function, used by the app to *quote* and by the server to *execute*:

```dart
RefundQuote quoteRefund(Booking b, RefundPolicy p, DateTime now) { … }
```

### Rules that make this safe

1. **Policies are immutable and versioned.** A booking stores `refund_policy_version` at purchase time and is judged by *that* version forever. Changing tomorrow's policy must never change yesterday's customer's entitlement — this is the single most important rule in this ADR, and the one most systems get wrong.
2. **A change takes effect only for future bookings**, and the console says so explicitly before saving.
3. **The wizard generates the human-readable text.** Operators do not write policy prose; they answer questions and we render French and English copy from the structured data. This guarantees the displayed policy and the executed policy are the same object, and it removes an entire class of "the app said X but they charged Y" disputes.
4. **Platform floor.** BilletEnLigne enforces a non-negotiable minimum: operator-caused cancellation (breakdown, cancelled departure, > 3 h delay) is always a **100% refund to source**, regardless of policy. Operators cannot configure their way out of their own failure. This is stated in the operator agreement and enforced in code.
5. **`agency_cash` destination is legitimate but constrained.** If an operator requires physical presence, the app must say so *before purchase*, prominently, on the departure detail screen — not in fine print at cancellation. Refund then becomes a **claim** with a QR the traveller shows at the counter, and the vendor closes it against their till.
6. **The same engine drives reschedule fees** — same tier shape, different outcome. One concept, two uses.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Hardcoded platform-wide policy** | Simple, and unsellable. Operators will not cede control of their treasury rules. Rejected. |
| **Free-text policy per operator** | Trivial to build, impossible to execute. A human reads it, a machine cannot. Guarantees disputes. Rejected. |
| **A scripting language / rules DSL** | Maximum flexibility, and a security and support nightmare — someone will write an infinite loop into a refund calculation. Rejected. |
| **Structured tiers + wizard-generated prose** | **Chosen.** Expressive enough for every real policy we found, and still a pure, testable function. |

## Consequences

The wizard is a real piece of design work (`04-payments.md` §7) — it must be answerable by a bus company owner with no legal training, in French, on a tablet, in ten minutes. If it takes an hour or needs a support call, we have failed and operators will pick the default.

We ship **three sensible presets** — *Souple*, *Standard*, *Strict* — so an operator can be live in one tap and tune later. Most will never leave the preset, and that is fine.
