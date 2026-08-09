# ADR-0020 — Local development environment: emulators, offline, ephemeral under test

**Status:** Accepted · **Date:** 2026-08-09 · **Related:** ADR-0018, ADR-0019, ADR-0021

## Context

A developer must be able to clone this repository and run the whole system — API, workers, Postgres, auth, blob storage, notifications — with **no cloud credentials and no network**. Anything less and onboarding is a day, tests are flaky, and someone eventually points a laptop at production.

CogitovaSchool solved this with .NET Aspire, and its `AppHost.cs` encodes several lessons that were learned the hard way. They are worth restating, because they are the whole value of this ADR:

- **Firebase emulator with a `demo-` project id** runs fully offline: no credentials, no cloud project, and it is impossible to accidentally hit a real one.
- **Emulator export/import must target a *subdirectory* of the bind mount**, never the mount point. The exporter clears its target first, which fails on a mount point with "Device or resource busy" — silently, on shutdown. Accounts then vanish on every restart while their Postgres rows survive, leaving user records pointing at UIDs that no longer exist.
- **Azurite** is the most faithful blob emulator available; production swaps the implementation behind the storage port.
- **A test run gets no persistence at all.** Postgres, Azurite and Firebase all drop their volumes. Cogitova traced a genuinely confusing intermittent failure to exactly this: an integration suite exported its Firebase accounts on the way out and the next E2E suite imported them.
- **A blank notification connection string is a supported state** that falls back to a logging sender, so nothing reaches a real person from a developer's machine.

## Decision

Reproduce those semantics for the Dart stack using **Docker Compose plus a small Dart CLI (`bel dev`)**, and carry every lesson above across verbatim.

```
infra/dev/
├─ docker-compose.yml        postgres · azurite · firebase-auth · mailpit
├─ firebase.json             emulator ports, bind-mounted read-only
├─ firebase-data/data/       import/export target — a SUBDIRECTORY, deliberately
├─ .env.example              every variable, documented, safe defaults
└─ seed/                     dev personas, operators, routes, departures
```

| Service | Image | Ports | Notes |
|---|---|---|---|
| **postgres** | `postgres:17` | 5432 | Named volume; **dropped when `BEL_TEST_RUN=true`** |
| **firebase-auth** | `andreysenov/firebase-tools` | 9099 auth · 4000 UI · 4400 hub | Project `demo-billetenligne`; `--import`/`--export-on-exit` to `firebase-data/data` |
| **azurite** | `mcr.microsoft.com/azure-storage/azurite` | 10000–10002 | Blob emulator for KYB documents, operator logos, ticket PDFs |
| **mailpit** | `axllent/mailpit` | 1025 SMTP · 8025 UI | Catches outbound email locally so operator statements are *visible*, not merely logged |

### Why Docker Compose rather than reusing Aspire

Aspire is a better dev experience — the dashboard, service discovery and health-gated startup are genuinely good, and this team already knows it. It was rejected here for one reason: it would put a **.NET SDK requirement on a Dart repository**, which contradicts ADR-0004's single-toolchain premise for a purely local convenience.

This is a soft call, and it is reversible: Aspire orchestrates containers and arbitrary executables perfectly well, so an `AppHost` that launches Dart Frog and these same four containers is roughly an afternoon's work. **If the dashboard is worth the .NET SDK to the team, take it** — nothing else in this ADR changes, because the semantics are what matter, not the orchestrator.

### The rules, carried across

1. **`demo-billetenligne`** as the Firebase project id locally. The `demo-` prefix makes the emulator refuse to talk to the cloud. Non-negotiable.
2. **Export/import to `firebase-data/data`**, a subdirectory. Documented in the compose file at the point of use, with the reason, so nobody "tidies" it back to the mount point.
3. **`BEL_TEST_RUN=true` makes everything ephemeral** — `tmpfs` for Postgres, no Azurite volume, no Firebase import/export. A suite starts from a known world or it is not a suite.
4. **One emulator project locally**, two Firebase projects in production (ADR-0018). Locally, one seeder creates every persona; the isolation that matters is enforced in production configuration.
5. **`COMMS__CONNECTIONSTRING` blank by default.** A fresh clone logs its SMS and delivers its email to Mailpit. Nobody's handset receives anything from a colleague's laptop.
6. **The seeder is idempotent and runs on every API start** in dev, as a safety net for the case where the emulator export did not happen (an ungraceful shutdown skips it).
7. **`docker compose up` and nothing else.** If a developer needs a README step beyond that, the compose file is wrong.

### Seeded world

The seed must be rich enough that every screen has something to render, because an empty dev environment is how empty states ship untested:

- 2 operators — one `active` (Océan du Nord, full fleet and schedules), one `under_review` so the admin approval queue is never empty
- Vehicles covering all three layout presets, including a VIP-front coach and an aircraft (ADR-0017)
- Brazzaville ↔ Pointe-Noire with real intermediate stops, 90 days of departures
- All three refund policy presets in use
- Traveller personas: fresh, with an upcoming ticket, with a past ticket, mid-`indeterminate`-payment
- Operator staff for **every** role in ADR-0011, so RBAC is exercisable by logging in rather than by reading code
- One departure pre-loaded with a declared disruption

## Consequences

Four containers is a real memory footprint on a modest laptop; Azurite and Mailpit can be omitted via a compose profile when working purely on the domain (which needs nothing — `bel_domain` tests run with no containers at all, in about two seconds).

The Firebase emulator has no phone-OTP SMS. Locally, **any phone number accepts the code `123456`** via the emulator's test-number mechanism, seeded in `firebase-data`. This must be impossible outside the emulator, and there is a test that asserts the production configuration never carries a `demo-` project id.
