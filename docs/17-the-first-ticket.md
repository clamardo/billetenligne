# The first ticket

**Status:** The only document that matters right now · **Date:** 2026-08-14

Everything else in `docs/` describes something that could be built. This describes the shortest path to **one real person in Brazzaville holding one real ticket for one real coach**. Nothing else counts until that happens.

---

## The one sentence

**The bus product is finished, it sells for cash, it needs no PSP credentials, and it has never been run outside a laptop.** What stands between it and a pilot is not engineering.

---

## What is already true

Search → seat map → hold → sign in → book → pay at an agency → signed ticket → boarding scan. Every step executed by tests, most against real Postgres. An operator can draw a seat layout, add a coach, open a route, publish a timetable and print a manifest, in a browser, without anybody running SQL.

**Cash at an agency till is a complete payment rail.** It posts to the double-entry ledger, it balances, it issues a ticket. MTN, Airtel, Orange and card are built and waiting on credentials — and the pilot does not need any of them. That was the point of Phase 1 and it is still true.

---

## What is parked, explicitly

Air. Car rental. Hotels. Reviews. Multi-country. The platform split's remaining slices.

All of them are specified, which is the right place for them to be. **None of them gets touched until a first coach ticket has been sold.** Four half-built verticals are worth less than one finished one, and the specifications will still be there.

If any of that starts to feel urgent, that is the feeling this section exists to overrule.

---

## Step 1 — Demo it from a laptop · this week · costs nothing

No cloud, no domain, no accounts. The dev stack is a `docker compose up`.

```
docker compose -f infra/dev/docker-compose.yml up -d
./tool/migrate.sh
./tool/demo.sh                                  # a seeded world: operators, roads, coaches, people
dart run services/worker/bin/worker.dart onboarding   # approves the waiting application
dart run services/worker/bin/worker.dart compliance   # stops the lapsed operator selling
./tool/api_dev.sh                               # the API, on :8080
cd apps/console && flutter run -d chrome --web-port 5000
```

**Port 5000 is not cosmetic.** `BEL__WEBORIGINS` in `infra/dev/.env` allows
`localhost:5000` and `localhost:5001` and nothing else, so a console served
from any other port is refused by CORS before the request leaves the browser
— which the sign-in screen reports as "Pas de connexion. Vérifiez votre
réseau", the one message that sends you to look at the wrong thing.

Sign in as `angele@demo.billetenligne.cg`; the six-digit code arrives in
Mailpit at `http://localhost:8025`. Every demo address is `@demo.billetenligne.cg`.

This run was walked end to end on 2026-08-14 — search, seat map, hold,
booking, mobile-money capture, counter sale, ticket, balanced ledger — and
what it found is below.

Then build the traveller APK against the laptop's LAN address and put it on a real Android phone:

```
BEL_API_URL=http://192.168.x.x:8080 ./tool/release_android.sh
```

**This is enough to sit across a table from a coach operator and show them their own business.** A phone that sells a seat and a browser that prints the manifest is worth more than any deck, and it costs nothing but an afternoon.

Do this before spending a single franc on infrastructure.

---

## Two columns nothing writes

Walking the demo found two gaps of the same shape, and both sit on the
critical path of Step 3. In each case the column exists, the reader exists,
the migration that created it is old — and nothing in the tree has ever
written a value to it.

**`operator_payment_accounts.verified_at`.** `collectionAccounts()` requires
it to be non-null before a rail is offered, and `POST /console/v1/payment-accounts`
saves every account unverified *on purpose*: "a typo here sends every franc to
a stranger, permanently." That reasoning is right. The missing half is the
step that later says yes. Until it exists, an operator can enter their MTN
number and no traveller can ever pay them by mobile money — the payment screen
comes back empty, which is exactly what it did on this run.

**`operator_staff.station_ids`.** Read by `PostgresIdentity` to decide which
till a person may sell from; written nowhere. There is no team surface at all
in the console — no route to invite a clerk, none to attach anyone to an
agency — so the guichet says "aucune agence rattachée" to every person in
every operator, including the owner. For a market where the first hundred
tickets are cash across a counter, this is the screen that matters most.

`services/worker/lib/src/demo_world.dart` now seeds both directly, which is
the only place this world writes a column no product code writes. Both
comments say so and say why. **The demo walks; the product still cannot do
either of these things.**

Neither is large. Verification wants a decision about who says yes — a back
office reviewer, a micro-deposit, an SMS to the wallet — and that decision is
the whole of the work. The team surface is a list, an invite and a
multi-select of stations, plus the capability check that already exists.

---

## Step 2 — A URL · once somebody is interested

Only worth doing when there is a person waiting to see it.

What it needs, in order:

1. **A GCP project with billing.** The decision was already made: the existing GCP account, a new billing account.
2. **A domain.** `infra/k8s/` hardcodes `blt.cg`, `console.blt.cg`, `admin.blt.cg`, and `managed-cert.yaml` asks Google to issue certificates for exactly those names. **If that domain is not owned and pointed at the load balancer, the certificate never provisions and the ingress hangs with no useful error.** `.cg` is a Congolese ccTLD and is neither cheap nor instant. Any domain works — it is three strings in one ConfigMap and one certificate manifest — so if `blt.cg` is slow to obtain, use one already owned and change them.
3. **`terraform apply`.** `terraform/live-module-gcp/prod/`. **It has never been run** — there is no state file anywhere in this repository. Expect the first apply to find real problems; that is what first applies do.
4. **`infra/k8s/deploy.sh`.** Builds and pushes the images, renders the manifests, applies them.
5. **`./tool/smoke_api.sh` against the deployed URL**, then `./tool/demo.sh` pointed at the production database so there is something to look at.

Rough monthly cost, and these are estimates rather than quotes: a GKE Autopilot cluster carries a management fee of roughly \$70–75, the smallest usable Cloud SQL Postgres is roughly \$25, and an HTTPS load balancer is roughly \$18. Call it **\$120–180 a month** to keep a pilot alive. Artifact Registry and egress at pilot volume are noise.

---

## Step 3 — One operator, one route, one ticket

The commercial half, and the actual critical path. It has been the first line of `09-roadmap.md` since the day that file was written.

- **One operator signs.** Not a contract — a willingness to put one road on the platform. The console is free and useful to them on its own, and that is the pitch.
- **Somebody sits with them and configures it**: their coach, their layout, their route, their timetable, their refund policy. An afternoon.
- **One agency till takes cash** against a payment code. This is the part that needs a human on the ground and no technology at all.
- **A conductor scans a ticket at a coach door**, offline, in daylight, on a cracked screen. Nothing in this product has ever been tested in that condition.

---

## What only you can do

Nothing on this list is engineering, and none of it can be started by me.

- Decide the domain, and register it
- Create the billing account and give me a project id
- Find the operator
- Be in the room when the till takes the first cash
- Carry a real phone onto a real Congolese network

## What I can do next, today

- Walk through the `terraform apply` with you, step by step, and fix what it finds
- ~~Do a full local demo run end to end and hand you the exact commands that worked, with screenshots of each screen~~ — done 2026-08-14; the commands are in Step 1 and what it found is in *Two columns nothing writes*
- Build the two missing writers: wallet verification, and a team surface that can attach somebody to a till
- A Play Console listing costs \$25 once, and the signed `.aab` already builds — but sideloading an APK at an agency needs no account at all, and for a pilot that is enough

---

## The measure

Not slices closed, not documents written, not verticals specified.

**One person, one ticket, one coach.** Everything in this repository is instrumental to that, and most of it is already done.
