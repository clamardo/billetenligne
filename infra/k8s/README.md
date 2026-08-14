# The cluster

```
BEL_REGISTRY=europe-west1-docker.pkg.dev/<project>/bel \
BEL_API_URL=https://blt.cg \
  ./infra/k8s/deploy.sh
```

Three hostnames on one load balancer:

`blt.cg` — the API, and everything a stranger reads: the landing page, an
operator's storefront at `/o/{code}`, a shared journey at `/t/{token}`, a
boarding pass at `/b/{ref}`.

`console.blt.cg` — the operator console.

`admin.blt.cg` — the back office.

**The console is not a path under `blt.cg`, and that is forced rather than
chosen.** `/console` and `/admin` are already API route surfaces (ADR-0011),
so mounting the web apps there would collide with the endpoints they call.
Separate hostnames mean separate origins to a browser, which is why
`BEL__WEBORIGINS` exists and why the API sends CORS headers at all.

## Before the first deploy

**The Secret is not in this repository.** `secrets.example.yaml` names every
key and holds no values; a committed Secret is a committed secret, because
base64 is an encoding and every tool that shows you a manifest decodes it for
you. `deploy.sh` refuses to roll anything if `bel-secrets` is not already in
the cluster — the API would crash-loop on a missing signing seed, which is
correct behaviour and a confusing way to find that out.

**The database roles are created by the migrations, `NOLOGIN`.** A role that
can log in is an environment decision rather than a schema one (0004, 0005),
so `bel_api`, `bel_app`, `bel_admin`, `bel_public` and `bel_identity` need
passwords granted once, by hand, as the owner:

```sql
ALTER ROLE bel_api LOGIN PASSWORD '…';
GRANT bel_public, bel_app, bel_admin, bel_identity TO bel_api;
```

`DATABASE_URL` is then `bel_api`, which is NOINHERIT and holds no privileges
at all until a transaction declares a surface. `MIGRATE_DATABASE_URL` is the
owner and is used by the Job and by nothing else.

**KEDA is a cluster add-on** and the worker does not run without it:

```
gcloud container clusters update <cluster> --location <loc> --enable-keda
```

**The certificate provisions itself** once `blt.cg`, `console.blt.cg` and
`admin.blt.cg` resolve to the load balancer's address, and not before. A
certificate stuck in `Provisioning` is almost always DNS that has not been
pointed yet.

## What runs, and how often

`bel-api` — two replicas, rolling with `maxUnavailable: 0`. This is the
process that sells seats.

`bel-console`, `bel-admin` — one replica each. Static files and a company's
dispatchers, not the public.

`bel-worker-minutes` — every five minutes: `payments refunds outbox holds
changes alerts reservations calls`.

`bel-worker-nightly` — 02:00 Africa/Brazzaville: `departures compliance
challenges onboarding reliability`.

**Two schedules rather than one, because the passes do not share a cadence.**
`payments` is the difference between a traveller boarding and a traveller who
paid and cannot. `reliability` recomputes on-time rates over every departure a
company has ever run. Running the second at the first one's cadence is the
nightly work done a hundred and forty times a day; running the first at the
second's is a traveller waiting until morning to learn whether their payment
landed.

## Liveness and readiness are different questions

`/health` touches no dependency and is the **liveness** probe. A liveness
probe that queried Postgres would restart every pod at once during a database
blip — a thirty-second outage turned into a fleet-wide cold start.

`/ready` takes one round trip to the database and is the **readiness** probe,
and the GKE load balancer's health check as well. A pod that cannot reach
Postgres cannot serve a search, a sale or a boarding pass, so it leaves the
load balancer while it cannot and returns the moment the database does, with
nothing restarted.

## The order of a deploy

Migrations run to completion **before** any pod that reads the schema is
rolled, and the roll does not start if they failed. An init container or a
Helm hook would run the migration once per replica: two runners racing, one of
which loses to the ledger's primary key. That fails safely and looks like a
flaky deploy, which is worse than failing.

`deploy.sh` refuses a dirty tree, because the tag is a git sha and a sha that
does not describe what was built is a tag that lies in `kubectl describe` on
the day somebody is trying to work out what is running.

## What is not here yet

No Terraform — the cluster, the Cloud SQL instance, the Artifact Registry
repository, the static address and the service accounts are all still made by
hand. That is the next slice.

No horizontal autoscaler. Two replicas is a guess, and the honest way to
replace a guess is a load test rather than an HPA reacting to one.

No secret manager. The Secret is created by a person with `kubectl`, which
means the ticket signing seed exists in one shell history. Workload Identity
and Secret Manager are the fix and are not built.
