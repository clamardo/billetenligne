# Local development stack

```bash
cp .env.example .env
docker compose up -d --wait    # --wait, so the next line does not race the database
../../tool/migrate.sh          # a fresh volume has roles and no schema
../../tool/demo.sh             # a world to look at, optional
../../tool/api_dev.sh          # the API on http://localhost:8080
../../tool/worker.sh           # every pass once — in another terminal
```

That is the whole setup. No cloud credentials, no network required (ADR-0020).

**In VS Code, none of the above is typed.** `.vscode/launch.json` carries the
whole thing: press **Everything (API + worker + traveller)** and the compose
stack, the migrations, the demo world, the route table, the server, the drain
and a handset come up in that order, with breakpoints in all of them. The
tasks it chains are also individually runnable from *Run Task*.

| Service | URL | Notes |
|---|---|---|
| Postgres | `localhost:5432` | user `bel_app` — deliberately not a superuser, so RLS actually applies |
| Firebase Auth emulator | `localhost:9099` | project `demo-billetenligne` |
| Firebase emulator UI | http://localhost:4000 | create and inspect accounts |
| Azurite (blob) | `localhost:10000` | KYB docs, operator logos, ticket PDFs |
| Mailpit | http://localhost:8025 | every outbound email lands here |

## Signing in locally

**On a handset**, the Auth emulator does not send SMS: any phone number
accepts the code **`123456`**.

**In the console or the back office**, sign-in is an emailed code and then
TOTP (ADR-0013). The code goes to Mailpit — http://localhost:8025 — because
`SMTP__HOST` is set in `.env.example` and nothing else is; the same sender
delivers ticket links with their QR attached and operator statements with
their PDF, so those are readable rather than a line of log saying a file
existed. SMS has no equivalent and still prints to the API's console, which
is where you would read it anyway.

The seeded staff have **no second factor enrolled**, so the first sign-in
walks through enrolment. There is no QR on that screen on purpose — see
`docs/10-build-status.md` — so copy the setup key into an authenticator by
hand.

Seeded personas are listed in [`seed/README.md`](seed/README.md), which also
explains the demo world and how to remove it.

Checking the whole chain without a browser:

```bash
# ask for a code, read it out of Mailpit, exchange it for a session
CH=$(curl -s -X POST localhost:8080/public/v1/auth/challenges \
  -H 'Content-Type: application/json' \
  -d '{"email":"prosper@demo.billetenligne.cg"}' | jq -r .challengeId)
CODE=$(curl -s 'localhost:8025/api/v1/messages?limit=1' \
  | grep -oE '[0-9]{6}' | head -1)
curl -s -X POST localhost:8080/public/v1/auth/sessions \
  -H 'Content-Type: application/json' \
  -d "{\"challengeId\":\"$CH\",\"code\":\"$CODE\"}"
```

## Running without any of this

`docker compose up` is not required to look at the two handset apps. Both run
on demo gateways with no server at all — a working funnel and a signed demo
departure — which is the **Demo only** compound in `.vscode/launch.json`, or:

```bash
flutter run                # from apps/traveller or apps/scanner
```

The console and the back office have no such mode, and that is deliberate: an
operator surface that invents its own tenant teaches the opposite of what the
surface is for.

## Working on the domain only

`bel_domain` has zero dependencies and needs **no containers at all**:

```bash
dart test packages/bel_domain    # full suite, ~2 seconds
```

If you find yourself starting Docker to test a pricing rule, the rule is in
the wrong layer (ADR-0001).

## Test runs

```bash
docker compose --profile test up -d
```

Brings up a second Postgres on tmpfs alongside the ordinary one, so a suite
starts from an empty schema and leaves nothing behind. Add `FIREBASE_PERSISTENCE=`
to `.env` to stop the emulator importing and exporting accounts between runs —
CogitovaSchool traced a genuinely confusing intermittent failure to one suite
exporting its accounts on the way out and the next suite importing them.

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
