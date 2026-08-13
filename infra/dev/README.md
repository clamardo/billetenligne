# Local development stack

```bash
cp .env.example .env
docker compose up
```

That is the whole setup. No cloud credentials, no network required (ADR-0020).

| Service | URL | Notes |
|---|---|---|
| Postgres | `localhost:5432` | user `bel_app` — deliberately not a superuser, so RLS actually applies |
| Firebase Auth emulator | `localhost:9099` | project `demo-billetenligne` |
| Firebase emulator UI | http://localhost:4000 | create and inspect accounts |
| Azurite (blob) | `localhost:10000` | KYB docs, operator logos, ticket PDFs |
| Mailpit | http://localhost:8025 | every outbound email lands here |

## Signing in locally

The Auth emulator does not send SMS. Any phone number accepts the code
**`123456`**. Seeded personas are listed in [`seed/README.md`](seed/README.md), which also
explains the demo world and how to remove it.

## Working on the domain only

`bel_domain` has zero dependencies and needs **no containers at all**:

```bash
dart test packages/bel_domain    # full suite, ~2 seconds
```

If you find yourself starting Docker to test a pricing rule, the rule is in
the wrong layer (ADR-0001).

## Test runs

```bash
BEL_TEST_RUN=true docker compose --profile test up -d
```

Everything becomes ephemeral — Postgres on tmpfs, no Azurite volume, no
Firebase import/export. This is not an optimisation: CogitovaSchool traced a
genuinely confusing intermittent failure to one suite exporting its Firebase
accounts on the way out and the next suite importing them.

## SMS and email

`COMMS__CONNECTIONSTRING` is blank by default and that is a supported state
(ADR-0019). SMS is written to the API log; email goes to Mailpit. Nobody
receives anything real from your machine.

To exercise real delivery, paste the shared development ACS connection string
into `.env` — never commit it.

## Careful with

`firebase-data/data` is a **subdirectory** of the bind mount on purpose. The
emulator's exporter clears its target directory first, which fails on a mount
point with "Device or resource busy" — silently, during shutdown. Accounts
then vanish on every restart while their Postgres rows survive. Do not
"simplify" this path.
