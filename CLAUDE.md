# BilletEnLigne — project guide

Intercity coach ticketing for the Republic of Congo. A **Dart end-to-end melos monorepo**
(ADR-0004): Flutter apps, a Dart Frog API, a worker, Postgres.

- **apps/** — `traveller` (the funnel), `console` (operator back office), `admin` (platform back
  office), `scanner` (standalone boarding app, ADR-0022).
- **services/** — `api` (Dart Frog, hot reload), `worker`.
- **packages/** — `bel_domain` (pure core), `bel_contracts` (DTOs), `bel_client` (API + session),
  `bel_design` (the Kilo design system), `bel_localization` (the catalog), `bel_backoffice`,
  `bel_platform`, `bel_crypto`, `bel_secure_store`.

## Invariants (do not weaken silently)

- **Onion** (ADR-0001). Dependencies point inward; a screen talks to a flow, a flow talks to a port.
- **Tenancy** is row-level and enforced by Postgres, with `FORCE ROW LEVEL SECURITY` and a scoped
  connection per caller (`DbScope`). Never bypass it in Dart.
- **Browsing needs no account** (ADR-0013). Most calls legitimately carry no bearer.
- **The server never sends prose** (ADR-0008). It sends a code and parameters; the sentence is
  chosen from the catalog on the client, in EN and FR.
- **Design tokens only** (ADR-0010). No raw hex, no bare spacing numbers. Lints and contrast gates
  in CI enforce it.
- **Seat contention is a database constraint**, not application locking (ADR-0012, ADR-0025).

## What keeps going wrong — read the agent memory

[`.claude/agent-memory/`](.claude/agent-memory/README.md) is a short, curated index of the mistakes
that have actually recurred here, organised by the step of the loop where each one bites. **Read it
at the start of a task and again at the top of each step, and immediately after any compaction.**
The skills below say what to do; that says what keeps going wrong while doing it, with a tally so it
is visible which trap is still live. It is maintained as work happens: an entry earns its place on
the second occurrence, and is deleted when a guard makes the failure impossible.

## How we work — read the skills

Project skills in [`.claude/skills/`](.claude/skills/):

- **agent-memory** — when to read `.claude/agent-memory/` and what earns a place in it. It is
  the only part of a session that survives compaction; read it before acting, write to it as
  work happens.
- **run-local-stack** — the verified way to bring Postgres, the API, the email emulator and the app
  up together, on ports that do not collide with the machine's own Postgres. Follow it verbatim;
  the `--dart-define`s in it are load-bearing.
- **regression-check** / **mutation-check** — the gates.
- **tenant-isolation** / **secure-coding-tenancy** — before touching anything that reads across
  operators.
- **feature-slice-refactor** — the recipe for moving a slice onto the onion.

## Commands

```bash
./tool/sync_i18n.sh        # after ANY catalog change; apps/*/assets/i18n is generated
./tool/integration.sh      # whole integration suite — do not pass it a path (see agent memory)
melos run analyze          # static analysis across the workspace
```
