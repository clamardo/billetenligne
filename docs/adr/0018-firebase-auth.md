# ADR-0018 — Firebase Authentication as the identity provider

**Status:** Accepted · **Date:** 2026-08-09 · **Amends:** ADR-0013 · **Related:** ADR-0020 (local dev)

## Context

ADR-0013 specified phone-number identity with OTP, and assumed we would build the OTP issue/verify/rate-limit machinery ourselves on top of an SMS aggregator. That is a meaningful amount of security-sensitive plumbing — code TTLs, attempt counters, per-number and per-IP throttles, replay protection, session/refresh rotation, revocation — and every line of it is a chance to get authentication wrong.

The CogitovaSchool platform already runs Firebase Authentication in production and the Firebase Emulator Suite locally, with an established pattern for both. That is proven ground in this team.

## Decision

**Firebase Authentication is the identity provider for every surface.** We keep ADR-0013's *product* decisions — phone is the traveller's identity, no passwords in the traveller app, browse before you authenticate, back office is email + password + MFA — and stop hand-rolling the mechanism.

| Surface | Firebase method |
|---|---|
| Traveller app | **Phone number + SMS OTP** (`signInWithPhoneNumber`) |
| Operator console | Email + password + **TOTP MFA** |
| Admin back office | Email + password + **mandatory TOTP MFA**, behind an IP allowlist |
| Conductor | **Custom token**, minted by our API from a dispatcher-issued pairing code, scoped and short-lived |

### Authorisation stays ours

Firebase answers *who you are*. It does not decide *what you may do*.

- **Custom claims** carry the coarse routing facts only: `tenantId`, `roles`, `stations`. Small, because they ride in every token and the JWT has a size limit.
- **Capability checks are server-side, against Postgres** (ADR-0011). A claim is a hint for the UI; the database is the authority. A stale claim must never be able to authorise a refund.
- **Postgres RLS still runs off a verified `tenantId`**, extracted from the token server-side and set as `app.tenant_id`. Unchanged from ADR-0011 — Firebase changes how we learn the tenant, not how we enforce it.
- Claims are refreshed on role change by forcing a token refresh; anything security-critical re-reads the database regardless.

### What this buys, concretely

Phone OTP done properly, MFA, session revocation, secure token storage, refresh rotation, SIM-swap-resistant re-auth prompts, and the Emulator Suite for local development — none of which we now write or maintain.

### What it costs, and how we blunt it

| Risk | Mitigation |
|---|---|
| **Phone-OTP SMS deliverability in Congo** is Firebase's routing, not ours, and it is the single highest-risk dependency in this ADR | Measure delivery rate per operator per hour from day one. If Firebase routing underperforms on Airtel/MTN Congo, fall back to **custom tokens**: we send the OTP via ACS (ADR-0019) on a local route, verify it ourselves, and mint a Firebase custom token. Identity stays Firebase; only the challenge moves. **Prove this path works before launch** — do not discover it during an incident. |
| Vendor lock-in on identity | The app never talks to Firebase for authorisation, and `bel_domain` has no Firebase types. Swapping providers is an infrastructure change, not a domain rewrite. |
| Firebase SDK size on a 2 GB device (ADR-0009) | `firebase_auth` + `firebase_core` only. **No** Firestore, no Analytics, no Crashlytics-by-default, no Remote Config. Our data lives in Postgres (ADR-0003); Firebase is authentication and nothing else. Measured against the 15 MB APK budget in CI. |
| Number recycling | Unchanged from ADR-0013: re-verification after long dormancy, and no payment credential ever bound to a bare phone number. |
| Cost per verification at scale | Monitored. The custom-token fallback above is also the cost lever. |

### Two projects in production, one locally

Following the CogitovaSchool precedent: production isolates **back-office identity** from **traveller identity** in two separate Firebase projects, so a compromise of one cannot mint tokens for the other. Locally, everything shares one `demo-` emulator project so the dev seeder can create every persona in one place (ADR-0020).

## Alternatives considered

| Option | Verdict |
|---|---|
| **Hand-rolled OTP** (original ADR-0013) | Full control over SMS routing, which matters here — but it is security-critical code we would own forever. Rejected as the default; **retained as the documented fallback**, which is the best of both. |
| **Supabase Auth / Auth0 / Cognito** | All credible. None is already running in this team, and Auth0 pricing is unattractive at low ARPU. Rejected. |
| **Firebase for everything** (Firestore, Functions) | Rejected outright. Inventory, ledger and holds require transactional Postgres with `SELECT … FOR UPDATE` (ADR-0012). Firestore cannot express the seat-hold invariant. |

## Consequences

`firebase_auth` appears in the Flutter apps and the Admin SDK in the Dart services — the first dependency that reaches outside the Dart-only story of ADR-0004. Contained deliberately: it lives in `infrastructure/`, behind an `AuthGateway` port, and nothing in `bel_domain` or `bel_contracts` knows it exists.

Local development requires the Firebase Emulator Suite running (ADR-0020). Every developer runs `demo-billetenligne` with no cloud credentials, so no one can accidentally hit a real project.
