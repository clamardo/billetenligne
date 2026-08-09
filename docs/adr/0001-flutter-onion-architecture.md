# ADR-0001 — Flutter with Onion (Clean) Architecture

**Status:** Accepted · **Date:** 2026-08-09

## Context

Mobile-first mandate, iOS + Android from one codebase, must run on low-end Android. The app has four distinct surfaces (traveller booking, ticket wallet, conductor scan mode, agent cash-sale) that share a domain but not a UI. The domain — inventory, holds, pricing, payment state machines, refund policy — is where the real complexity is, and it must be testable without a device, a network or a PSP sandbox.

## Decision

**Flutter** for the client. **Onion architecture** with strict inward-only dependencies.

```
                    ┌─────────────────────────────┐
                    │   Presentation (Flutter)     │  widgets, routing, controllers
                    │  ┌───────────────────────┐  │
                    │  │  Application          │  │  use cases, orchestration, ports
                    │  │  ┌─────────────────┐  │  │
                    │  │  │    Domain       │  │  │  entities, value objects,
                    │  │  │   (the core)    │  │  │  policies, domain services
                    │  │  └─────────────────┘  │  │
                    │  └───────────────────────┘  │
                    └─────────────────────────────┘
                       Infrastructure ──────┘  implements Application ports
                       (http, sqlite, psp adapters, platform)
```

**The rule, stated once and enforced by CI:** dependencies point inward only. Domain imports nothing but Dart. Application imports Domain. Infrastructure imports Application + Domain. Presentation imports Application + Domain, and *never* Infrastructure.

Concretely, per feature package:

```
lib/features/booking/
  domain/            # zero Flutter imports, zero package imports
    entities/          Trip, Seat, Booking, Hold, Money, SeatMap
    value_objects/     TripId, SeatLabel, PhoneNumber, Currency
    policies/          CancellationPolicy, ReschedulePolicy, PricingPolicy
    errors/            DomainFailure hierarchy
  application/
    ports/             TripRepository, BookingRepository, PaymentGateway (abstract)
    usecases/          SearchTrips, HoldSeats, ConfirmBooking, RescheduleBooking
    dto/               request/response shapes crossing the boundary
  infrastructure/
    remote/            Retrofit-style clients, DTO↔entity mappers
    local/             Drift DAOs, cache policy
    repositories/      concrete impls of the ports
  presentation/
    controllers/       Riverpod notifiers — thin, no business rules
    pages/ widgets/
```

Cross-cutting lives in `lib/core/` (design system, i18n, result type, DI, network primitives, telemetry).

### Why Onion over "Flutter Clean Architecture" as commonly practised

The usual `data / domain / presentation` triad is Onion with the labels changed, but it routinely leaks: repositories return DTOs, `dartz`'s `Either` becomes gospel, and everything ends up in one giant `data` folder. We commit to the stricter form:

- **Ports live in Application, not Domain.** The domain does not know that persistence exists. `TripRepository` is an application-layer interface because *searching trips* is a use case concern, not an invariant of a `Trip`.
- **Entities are behaviour-bearing, not anaemic.** `Booking.reschedule(newTrip, now)` returns a `Result<Booking, RescheduleFailure>` and enforces the 24h/2h windows itself. If the domain folder is only data classes, we built the wrong thing.
- **`Money` is a value object, never a `double`.** XAF is a zero-decimal currency; a `double` here is a bug generator. Integer minor units + explicit `Currency`.
- **One `Result<T, F>` type**, hand-rolled in `core/`, no `dartz`. Sealed classes give us exhaustive `switch` in Dart 3.

### Enforcement

`import_lint` / a custom `dart analyze` rule + a CI check:
- `lib/**/domain/**` may not import `package:flutter/*`, `dart:io`, or any `infrastructure/`.
- `lib/**/presentation/**` may not import `infrastructure/`.
- `lib/**/application/**` may not import `infrastructure/` or `presentation/`.

A rule that isn't enforced by CI is a comment. This one is enforced.

## Alternatives considered

| Option | Verdict |
|---|---|
| **React Native** | Larger runtime, worse cold start on 2 GB devices, and the JS bridge is the wrong place to be when we need a fast offline QR scanner. Rejected. |
| **Native Android + iOS** | Best performance, 2× the team. We do not have 2× the team. Rejected. |
| **KMP + Compose Multiplatform** | Genuinely attractive for the shared domain, but iOS UI story is still less mature and the user asked for Flutter. Rejected for v1, revisit never. |
| **Flutter, feature-first without layers** | Fast for 3 months, unmaintainable at 12. The payment state machine alone justifies the layering. Rejected. |
| **Hexagonal / Ports & Adapters** | Effectively the same shape. We use Onion vocabulary for consistency with the backend. |

## Consequences

**Good:** domain is pure Dart, unit-testable at thousands of tests/second with no mocks of Flutter. Swapping Airtel for Orange Money touches one adapter. The conductor scan feature reuses the ticket domain with a different presentation.

**Bad:** more files, more mapping code, more ceremony for genuinely simple features. We accept the mapping cost; we do *not* accept adding a layer "for symmetry" where a feature has no domain logic — a static content page can be a widget and an API call.

**Guard against:** the layering becoming cargo cult. Review question for every PR: *"which invariant does this layer protect?"* If there is no answer, collapse it.
