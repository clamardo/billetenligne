# ADR-0006 — Payment rail sequencing

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0005

## Context

Congo-Brazzaville mobile money is a three-player market: **Orange Money ~45%**, **Airtel Money ~35%**, **MTN MoMo ~20%**. The brief names Airtel and MTN. Shipping only those reaches roughly 55% of the mobile money market and leaves the largest single wallet unsupported.

Merchant onboarding with a telco is a commercial process (KYB, merchant agreement, float account, settlement terms, production credentials) that runs on the telco's clock, not ours — routinely 4–12 weeks. It is the long pole, and it is not an engineering task.

## Decision

Build the port once (ADR-0005); sequence the rails by *commercial readiness*, not by preference.

| Wave | Rail | Rationale |
|---|---|---|
| **0 — day one** | **Cash at agency** | No PSP dependency. Proves inventory, holds, ticketing and the console end to end while telco paperwork is in flight. Also the thing that gets operators to say yes. |
| **1** | **Airtel Money** + **MTN MoMo** | As briefed. Whichever returns production credentials first ships first — the adapters are independent. |
| **2 — fast follow** | **Orange Money** | Largest share. Not in the brief, but leaving 45% of wallets unsupported is a growth cap we should not accept. Start the commercial conversation in parallel with wave 1, not after it. |
| **3** | **Card** (Visa/Mastercard, 3-D Secure) | Diaspora and corporate accounts. Low volume, high value per transaction. Via an acquiring PSP, never direct. |
| **4 — optional** | **Aggregator fallback** | Only if wave 1/2 direct integrations prove unreliable. The port makes it a drop-in. |

**Start all commercial conversations at once.** Engineering sequencing follows whichever credentials land. The adapter for a new rail is ~300 lines plus its fake and its state-machine test suite — roughly a week. The paperwork is three months. Optimise the paperwork.

## Consequences

The UI must not hardcode two operators. The payment method list is **server-driven**: the API returns available rails for the user's country + MSISDN, with display name, logo, and enabled/disabled state with a reason. Adding Orange Money must be a config flag flip, not an app release — critical, because in this market a meaningful share of users never update the app.
