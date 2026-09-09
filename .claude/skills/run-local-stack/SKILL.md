---
name: run-local-stack
description: Use when starting, running or screenshotting BilletEnLigne locally — the dev compose stack, the Dart Frog API, or the traveller/scanner/console/admin apps — including when a second isolated Postgres is needed on a non-default port so it will not collide with a stack already running.
---

# Running BilletEnLigne locally

Four layers, started in order. Skipping one does not fail loudly — it fails as
a spinner that never stops.

```
compose (postgres · firebase-auth · azurite · mailpit)
  → tool/migrate.sh      schema
  → tool/demo.sh         a world to look at
  → tool/api_dev.sh      http://localhost:8080
  → flutter run          the app
```

## Which app is which

| App | Target | Notes |
|---|---|---|
| `apps/traveller` | **Android/iOS only** | no `web/` or `linux/` folder — needs an emulator |
| `apps/scanner` | **Android/iOS only** | same |
| `apps/console`, `apps/admin` | Flutter web | `-d chrome` |

`flutter emulators --launch pixel`, then wait for boot before `flutter run`:

```bash
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
```

## The default stack

As written in `infra/dev/README.md`. Use this when nothing else is running on
5432/9099/10000/1025/8025.

```bash
cp infra/dev/.env.example infra/dev/.env        # first time only
docker compose -f infra/dev/docker-compose.yml up -d --wait
./tool/migrate.sh
./tool/demo.sh          # optional, but the apps are empty without it
./tool/api_dev.sh       # http://localhost:8080
./tool/worker.sh        # every pass once, in another terminal
```

## A second, isolated stack

A separate compose **project**, so it gets its own volume and a genuinely
fresh database. Every host port in `docker-compose.yml` is `${VAR:-default}`,
so the defaults are unchanged and only what you set moves.

**First find out what is actually on 5432** — it decides how much you bring up.

```bash
docker ps --format '{{.Names}}\t{{.Ports}}'
ss -ltn | grep -E ':(5432|9099|10000|1025)\b'
```

| 9099/10000/1025 also served | It is this project's own `billetenligne-dev` stack | start `postgres` only, reuse those emulators |
| they are free | an unrelated Postgres | start the **whole** stack; only Postgres has to move |

```bash
export BEL_DEV_PROJECT=billetenligne-alt   # own project ⇒ own volume ⇒ fresh db
export BEL_DEV_PORT=5442
export BEL_ENV_FILE="$PWD/infra/dev/.env.alt"

sed 's#@localhost:5432/billetenligne#@localhost:5442/billetenligne#g' \
  infra/dev/.env > infra/dev/.env.alt        # gitignored; port must match BEL_DEV_PORT

# this project's stack already holds 5432:
docker compose -f infra/dev/docker-compose.yml up -d --wait postgres
# ...or an unrelated Postgres does — take the emulators too:
export BEL_DEV_FIREBASE_DATA="$PWD/infra/dev/firebase-data-alt"
docker compose -f infra/dev/docker-compose.yml up -d --wait

./tool/migrate.sh
./tool/demo.sh
./tool/api_dev.sh
```

### Export all three, in the one shell you run every step from

They are read by different things and none of them covers the others:

| Variable | Read by | Dropping it means |
|---|---|---|
| `BEL_DEV_PROJECT` | `docker-compose.yml`, every `tool/*.sh` | the "is it running" gate and `demo.sh`'s `docker compose exec -T postgres` both land in the **default** project — seeding the database you were avoiding |
| `BEL_DEV_PORT` | `migrate.sh`, `demo.sh` (they do **not** read `BEL_ENV_FILE`) | migrations aimed at 5432 |
| `BEL_ENV_FILE` | `api_dev.sh`, `worker.sh` (they do **not** read `BEL_DEV_PORT`) | the API serves the other database |

### Moving anything other than the Postgres port

The compose knobs — `BEL_DEV_TEST_PORT` `BEL_DEV_FIREBASE_PORT`
`BEL_DEV_FIREBASE_UI_PORT` `BEL_DEV_FIREBASE_HUB_PORT` `BEL_DEV_BLOB_PORT`
`BEL_DEV_QUEUE_PORT` `BEL_DEV_TABLE_PORT` `BEL_DEV_SMTP_PORT`
`BEL_DEV_MAILPIT_UI_PORT`, plus `BEL_DEV_FIREBASE_DATA` — move the *container's*
published port and nothing else. The env file still hardcodes where the API
looks: `FIREBASE_AUTH_EMULATOR_HOST=localhost:9099`, `SMTP__PORT=1025`,
`STORAGE__ENDPOINT=http://127.0.0.1:10000/...`. **Setting the knob alone
silently leaves the API pointed at the old stack's emulator.** Edit `.env.alt`
to match, and give a second Firebase its own `BEL_DEV_FIREBASE_DATA` — two
emulators sharing `./firebase-data` clear each other's accounts.

### Overriding the database is an env file, never an export

`api_dev.sh` and `worker.sh` do `set -a; source "$ENV_FILE"`, which **assigns
unconditionally**. A `DATABASE_URL` exported into either script is silently
overwritten by the file and the API quietly serves the wrong database. Point
`BEL_ENV_FILE` at a copy instead — that is what it is for.

## Pointing an app at the API

```bash
flutter run -d emulator-5554 \
  --dart-define=BEL_API_URL=http://localhost:8080 \
  --dart-define=BEL_FIREBASE_EMULATOR=localhost:9099
```

Write `localhost`, not `10.0.2.2`. `_reachable()` in each app's `main.dart`
rewrites it per platform, so one value is correct on emulator, desktop and
test. (`apps/traveller/README.md` and the doc comment at `main.dart:34` still
say `10.0.2.2`; they predate `_reachable()`. `.vscode/launch.json` is right.)

With **no** `BEL_API_URL` the app wires `DemoTravelGateway` — a working search,
a seat map, a payment code, and zero server contact. The "unconfigured build"
banner is `kReleaseMode` only, so **in debug there is no warning whatsoever**.
Confirm requests reach the API before believing a screen.

Signing in: any phone number takes code **`123456`**. Console/admin codes go to
Mailpit (http://localhost:8025, or `BEL_DEV_MAILPIT_UI_PORT`).

## Verify, don't assume

```bash
curl -s localhost:8080/public/v1/cities          # seeded data, not just /health
docker exec billetenligne-alt-postgres-1 psql -U bel -d billetenligne -tAc \
  "select usename,count(*) from pg_stat_activity where usename='bel_api' group by 1"
```

`bel_api` connections must appear on the stack you started and **not** on the
one you were avoiding. Row counts alone prove nothing — both databases get the
same demo seed.

The role to look for is `bel_api` (`infra/dev/README.md` says `bel_app`, which
is a different, non-login-path role — `bel_api` is a `NOINHERIT` member of it).

## Common mistakes

| Symptom | Cause |
|---|---|
| `Rogue route detected` on API boot | pre-existing, not a failure. Success is `✓ Running on http://localhost:8080` |
| API serves the *other* database | `DATABASE_URL` exported instead of `BEL_ENV_FILE` |
| tool script says "the dev stack is not running" | `BEL_DEV_PROJECT` not exported for that call |
| App shows invented coaches the API never heard of | `BEL_API_URL` unset — it fell back to demo gateways |
| A **correct** one-time code is refused, and the screen says *"Your code was correct, but signing in did not finish"* | `BEL_FIREBASE_EMULATOR` unset. Our API accepted and **spent** the code; the Firebase token exchange that follows it then went to production from an emulator and failed. Relaunch with the define and ask for a new code — the old one is gone. Before that message existed this presented as *"Sign in to continue."*, which reads like a rejected code and is the wrong thing to chase |
| App spins forever instead of erroring | it is calling the *emulator's* own loopback; nothing listens there, so the socket hangs rather than refusing |
| `flutter devices` shows no Android | emulator not launched, or not booted yet |

Run `./tool/migrate.sh` **before** `./tool/demo.sh`: demo.sh has a fallback
that applies the migration files directly when the schema is missing, which
does not write the `schema_migrations` ledger that `migrate.sh` reads.

## Teardown

Name the project inline. `down -v` with `BEL_DEV_PROJECT` unset destroys the
**default** `billetenligne-dev` volume — someone else's database.

```bash
BEL_DEV_PROJECT=billetenligne-alt \
  docker compose -f infra/dev/docker-compose.yml down -v
```
