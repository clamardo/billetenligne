# ADR-0024 — Email first, phone second, on a challenge we own

**Status:** Accepted · **Date:** 2026-08-09 · **Amends:** ADR-0013, ADR-0018 · **Related:** ADR-0019, ADR-0020

## Context

ADR-0013 made the phone number the traveller's identity and ADR-0018 put that behind Firebase's own `signInWithPhoneNumber`. Both were right about the market: in Congo the phone number *is* the identity, and email is a distant second.

Neither is buildable this week.

- **Firebase phone OTP needs a real Firebase project with billing and a verified app**, and the emulator's phone flow is a fixed test-number table. There is no path from that to a traveller signing in.
- **We cannot send an SMS at all yet.** ADR-0019 chose Azure Communication Services and says a blank connection string is a supported state. What is configured today is the shared CogitovaSchool ACS resource, and it can send **email**. There is no provisioned sender number, so `COMMS__SMSFROM` is blank and any SMS we composed would go nowhere.

Meanwhile every hold in the system belongs to one demo user, and nothing downstream of identity — booking, payment, ticket issuing, the console's guichet — can be built honestly until that is fixed. Identity is the blocking slice, and the blocker on identity is a channel.

## Decision

**Keep Firebase as the identity provider. Move the challenge onto a channel we own, and lead with email.**

This is not a new direction. ADR-0018 documents it as the fallback for exactly this situation and ADR-0019 rule 7 says to *"build the ACS OTP path early enough to have the option"*. We are building it, and the only thing that changes from the fallback as written is which channel goes first.

```
  email address  →  we generate a code  →  ACS delivers it
                 →  we verify it        →  Firebase CUSTOM TOKEN
                 →  the app exchanges it with Firebase
                 →  every later request carries a Firebase ID TOKEN
```

**The split is the point.** We own the challenge, so the code travels over a rail we can price and measure — per channel, per hour, from day one, which is the thing ADR-0019 says degrades silently. Firebase still owns the session, the refresh rotation and the revocation, none of which we then write.

### What "phone second" concretely means

Not "phone later, design later". The flow, the storage and the limits are **channel-agnostic today**: `auth_challenges.channel` is a column, `SignInChannel` is an enum with both values, the use case switches on it, and the SMS template already exists in the catalog at `sms.otp.body`. Adding phone is a provisioned sender number and a config value — `services.smsConfigured` is the switch, and until it flips the API refuses the phone channel with a 503 rather than accepting it and leaving somebody on a screen waiting for a message nobody sent.

### No passwords, still

ADR-0013's substantive rule survives intact and email does not change it. The reference implementation we borrowed the Firebase pattern from (CogitovaSchool) uses email + password, and we deliberately do not: a password is a thing to forget, to reuse, and to phish, and the traveller app has no desktop and no password manager behind it. A one-time code to a channel the person controls is the same proof with none of the storage.

Back-office auth is unchanged and still email + password + TOTP (ADR-0013), for the reasons stated there.

### Consequences that are not obvious

**The account is created by the code, not before it.** Sign-up and sign-in are one operation, so the API never has cause to answer "is this address registered?" — which is the question an enumeration attack asks. The response for a stranger and a returning customer is identical, and there is a test asserting it field by field.

**The Firebase UID is our account id.** We choose it rather than letting Firebase mint one. The alternative is a network round trip to Firebase inside the sign-in transaction, and a failure there leaves an account nobody can ever sign in to.

**A fourth database role exists because of this.** Resolving a bearer token is a read of `user_accounts` that happens before the request has a surface, a tenant or a user id — so none of `bel_public`, `bel_app` or `bel_admin` can perform it, and handing the job to `bel_app` would run the traveller sign-in path with an operator's authority. `bel_identity` (migration 0007) can read and write two tables and cannot reach a seat. This is migration 0005's argument applied a second time.

**We now carry OTP mechanics we said we would not own.** Code TTL, attempt caps, resend cooldown, replay defence, constant-time comparison, keyed hashing. That is the real cost of this ADR and it is why every one of those is executed by a test rather than asserted in prose. What we still do not own is session management, and that was the larger half.

**Email deliverability is now on the sign-in path.** An address that bounces is a traveller who cannot sign in, and unlike SMS there is no second rail to fall back to yet. Measure it per hour from the first day of the pilot; the mitigation is phone, and it is the reason phone is second rather than someday.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Wait for a provisioned SMS sender** | Correct channel, unknown date, and it blocks booking, payment, ticketing and the console behind a telco's paperwork. Rejected for the same reason the whole roadmap sequences around commercial long poles. |
| **Firebase email-link (passwordless)** | Firebase sends the mail, so we lose the delivery measurement and the local dev loop needs a real project. Rejected. |
| **Email + password, as CogitovaSchool does** | Proven, and wrong for this user: no password manager, no desktop, and a forgotten password becomes a support ticket in a market where support is a phone call. Rejected. |
| **Our own session tokens instead of custom tokens** | We already have Ed25519 signing (`bel_crypto`), so it is genuinely one afternoon. It is also revocation, refresh rotation, and secure storage owned forever. Rejected — that is the half of ADR-0018 worth keeping. |
