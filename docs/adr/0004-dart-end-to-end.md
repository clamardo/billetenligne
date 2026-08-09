# ADR-0004 — Dart end to end (one language, one domain, four surfaces)

**Status:** Accepted · **Date:** 2026-08-09 · **Supersedes:** nothing · **Drives:** ADR-0005, ADR-0010

## Context

We now have **six** deliverables, not one:

1. Traveller mobile app (iOS + Android)
2. Conductor / boarding mode (ships inside #1, different surface)
3. Operator console — schedules, fleet, agents, cash sales, payouts
4. BilletEnLigne internal admin back office — operator approval, compliance, finance, support
5. Public API + services
6. Background workers — payment reconciliation, notifications, outbox drain

Written the conventional way that is Dart + TypeScript + probably SQL-in-a-third-dialect, with the **booking, pricing, refund and payment-state rules re-implemented on both sides of the wire**. That duplication is where money bugs are born: the client thinks the reschedule fee is 10%, the server thinks it's 15%, and a customer gets charged twice.

The stated goal is a unified language to avoid context switching. There is a stronger reason than ergonomics: **a single domain implementation shared by client and server.**

## Decision

**Dart everywhere.** One language, and — more importantly — one *domain package* compiled into both the app and the server.

```
billetenligne/
├─ packages/
│  ├─ bel_domain/        pure Dart. Entities, value objects, policies, state machines.
│  │                     ZERO dependencies (not even Flutter). Used by app AND server.
│  ├─ bel_contracts/     API DTOs + validators + error codes. Single source of truth
│  │                     for the wire format. Server serialises them, clients parse them.
│  ├─ bel_design/        the Kilo design system. Flutter. Used by mobile + both consoles.
│  └─ bel_client/        generated, typed API client over bel_contracts.
├─ apps/
│  ├─ traveller/         Flutter mobile — booking, wallet, conductor mode
│  ├─ console/           Flutter Web — operator back office
│  └─ admin/             Flutter Web — BilletEnLigne internal back office
└─ services/
   ├─ api/               Dart Frog — HTTP API
   └─ worker/            Dart — cron + queue consumers
```

Monorepo managed with **Melos**. `bel_domain` is `dart test`-only, runs in ~2 s, and is the most-tested code we own.

### What this buys us, concretely

- `CancellationPolicy.quoteRefund(booking, now)` is called by the Flutter app to render "Remboursement : 7 200 XAF" **and** by the server to actually issue the refund. They cannot disagree, because they are the same function.
- `Money` arithmetic (XAF zero-decimal, integer minor units) is defined once. No float drift between client display and server ledger.
- The `PaymentIntent` state machine is one sealed class. The app's UI states and the server's transitions are exhaustively checked by the same compiler.
- Adding a field to a booking is one edit in `bel_contracts` and both ends fail to compile until updated. That is the good kind of breakage.

### Backend framework: Dart Frog

Dart Frog for the API — file-based routing, middleware, compiles to a single self-contained binary (~10 MB), trivial to containerise, no runtime dependency. Postgres via `postgres` + hand-written SQL/`drift_postgres`. No ORM magic in the money path; the ledger uses explicit SQL and explicit transactions.

### Consoles: Flutter Web (CanvasKit), not a JS framework

Both back offices are Flutter Web. This is the part that needs justifying, because Flutter Web is usually the wrong answer for content sites.

It is the right answer *here*:
- Back-office users are on laptops in offices on wifi — the 1.5–2 MB CanvasKit payload is a one-time cost for a tool used 8 h/day, not a bounce-rate problem. It is cached after first load.
- They reuse `bel_domain`, `bel_contracts` and `bel_design` verbatim. An operator console that shows a seat map renders the *same widget* as the mobile app.
- Support agents in the admin console need to see exactly what the traveller sees. Same code = same pixels.
- One CI pipeline, one dependency graph, one hiring profile.

**Not** Flutter Web for any future public/marketing/SEO surface — that stays static HTML.

### Note: where a CSS framework like Tailwind fits (and where it cannot)

Worth stating explicitly, because it comes up. **Tailwind is a CSS utility framework — it has no backend role at all.** The Dart Frog API returns JSON; there is no HTML for it to style.

It also cannot style the consoles: Flutter Web paints to a canvas via CanvasKit, so there is no DOM for CSS to reach. Styling there is `bel_design` tokens, full stop.

Tailwind **is** a good fit for exactly two surfaces in this system, both of which are deliberately plain HTML:

- The **shared-trip follower page** (ADR-0014 §2) — ~50 KB, opened by strangers on unknown phones, where a Flutter payload would be indefensible.
- Any **marketing / SEO pages**, which must be static HTML for indexing.

Use it there, with the JIT build so the shipped CSS stays a few KB. Do not introduce it anywhere else — a second styling system that overlaps `bel_design` is exactly the divergence ADR-0010 exists to prevent.

If the underlying question is *"should the back offices be React + Tailwind instead of Flutter Web?"* — that is the serious alternative below, and it is a live option if the team we hire is TypeScript-heavy.

## Alternatives considered

| Option | Verdict |
|---|---|
| **TypeScript backend (NestJS) + React consoles + Flutter app** | Deepest ecosystem, easiest hiring, best admin-UI component libraries (TanStack Table, shadcn). But it forces the domain to be written twice and reintroduces exactly the context switch we are trying to remove. **This is the serious alternative** — if the team we hire is TS-heavy, revisit. Rejected for now. |
| **Serverpod** (Dart backend + generated Flutter client) | Very close to what we want, and its generated client is excellent. Rejected because it is opinionated about ORM, auth and project layout in ways that fight ADR-0001's layering, and because the money path should not sit behind generated abstractions we don't fully control. |
| **Kotlin backend + KMP shared domain** | Also solves domain sharing, and the JVM payment/ops ecosystem is stronger. Loses Flutter. Rejected — the app is the product. |
| **Go backend** | Great ops story, no domain sharing, third language. Rejected. |

## Consequences

**Good:** one language, one domain, one design system, four surfaces. Domain bugs are fixed once. Onboarding a new engineer is one ecosystem.

**Bad and we own it:**
- Dart's server ecosystem is thinner. Things we get for free in Node/JVM that we will write ourselves or wrap: PDF generation, some PSP SDKs (we call the REST APIs directly — see `04-payments.md`), advanced admin tables. Budget for this.
- Hiring "Dart backend engineer" is a narrow search. Mitigation: the backend is deliberately boring — HTTP handlers, SQL, and the shared domain. A competent Flutter engineer is productive on it in a week.
- Flutter Web consoles will never feel as snappy as a React admin panel on first load, and accessibility on Flutter Web is weaker than DOM. Accepted for internal tools; **re-evaluate if the operator console ever becomes self-serve at scale.**

**Escape hatch:** because `bel_contracts` defines the wire format language-agnostically (and we publish an OpenAPI document generated from it), any service can be rewritten in another language without touching the clients. The commitment is reversible per-service, which is the only kind of commitment worth making.
