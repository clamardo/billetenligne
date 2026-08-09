# ADR-0013 — Phone-number identity, no passwords

**Status:** Accepted · **Date:** 2026-08-09

## Context

The target user has a phone number and a mobile money wallet. Many do not have an email address they check, and password managers are not part of the picture. Meanwhile SMS costs money per message and OTP interception is a known fraud vector.

## Decision

**Phone number is the identity.** No passwords anywhere in the traveller app.

- **Sign-up / sign-in:** MSISDN + 6-digit OTP. Session is a refresh token in platform secure storage (Keychain / Android Keystore), rotating on use, 90-day life, revocable from the admin console.
- **Browse before you authenticate.** Search, routes, prices, seat maps — all open. Auth is required only at the moment of holding a seat. Forcing sign-up before the user sees value is the biggest avoidable drop-off in this funnel.
- **OTP hardening:** 60 s resend cooldown with exponential backoff, 5 attempts per code, code TTL 5 min, per-number and per-IP rate limits, and a device-attestation signal before high-value actions. SMS cost is a real budget line — cap it and monitor it.
- **Android SMS Retriever API** so the code auto-fills without SMS-read permission. Removes a permission prompt and a failure mode.
- **Buying for someone else is a first-class flow** (Persona D). The passenger's phone number is a field on the booking, distinct from the purchaser's account. The ticket is delivered to the passenger by SMS and deep link; they need no account to travel.

### Back-office auth is different, deliberately

Console and admin users sign in with **email + password + mandatory TOTP 2FA**. Reasons: back-office staff have desktops and password managers; SMS OTP is too weak for someone who can approve payouts; and SIM-swap against an operator owner must not equal account takeover. Admin app additionally sits behind an IP allowlist (ADR-0011).

Conductors are an exception — they sign in on a phone with a **short-lived device pairing code** issued by their dispatcher, scoped to assigned departures, expiring on shift end. No password to forget at the roadside, and no standing credential on a device that gets lost.

## Consequences

We carry SMS cost and dependency on an aggregator's deliverability in Congo — pick one with local routes and measure delivery rate per operator, per hour, from day one; it is the kind of thing that silently degrades. Number recycling is a real risk (a reassigned MSISDN inheriting an old account): mitigate with a re-verification challenge after long dormancy and by never storing payment credentials against a bare phone number.
