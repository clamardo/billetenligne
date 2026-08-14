# The two images

```
docker build -f infra/docker/api.Dockerfile    -t bel-api    .
docker build -f infra/docker/worker.Dockerfile -t bel-worker .
```

Or `./tool/images.sh`, which builds both and then starts them — because a
Dockerfile that compiles and produces an image that exits on its first request
is a green build and a broken deploy.

**Both build from the repository root.** The server is four path packages and a
route tree; none of them resolve from `services/api` alone.

## What is in them, and what is not

Each image is `FROM scratch` with the Dart runtime copied in and one compiled
executable. No SDK, no shell, no package manager — which matters twice here:
the pods are small, and the smaller surface is one fewer thing to patch on a
process that holds a ticket signing key. It also means `kubectl exec` gets you
nothing, and the probes have to be `httpGet`.

Three things are copied in as data rather than compiled:

`i18n/` — the translation catalog. One catalog for the clients and the server
(ADR-0008), and the server renders prose: the storefront, the boarding pass,
the landing page and every SMS and email template.

`config/markets.yaml` — which payment rails this deployment announces. The one
file a market switch touches, which is exactly why it is not compiled in.

`migrations/` — the worker image only. A schema step whose SQL is invisible is
a schema step nobody can review.

## The workspace, trimmed

The root `pubspec.yaml` lists four Flutter apps and three Flutter packages as
workspace members, and `dart pub get` will not resolve a workspace whose
members are missing from disk. Both Dockerfiles `sed` them out.

The alternative was the Flutter SDK in the build stage: a gigabyte and several
minutes, to build a server that never touches it.

**The cost, named:** this resolves the server's dependencies rather than
replaying the committed lockfile, so an image can pick up a patch release CI
has not seen. It is the reason `tool/images.sh` runs in CI on every push
rather than only at release time.

## Two entry points, one worker image

```
/app/bin/migrate   applies what the database has not seen, then exits  (default)
/app/bin/worker    one pass, then exits
```

They share the whole dependency graph and differ by one `bin/` file. Two
images would be two builds, two tags, and two chances for the schema step and
the process that reads it to come from different commits — the one way a
migration goes wrong that nobody notices until the pass runs.

The migration runner is the default command because it is what a deployment
runs first, and a Job that forgets to name a command should do the harmless
thing.

## What a deployment must set

`MIGRATE_DATABASE_URL` is the **owner** connection and is deliberately not
`DATABASE_URL`: `bel_api` is NOINHERIT and holds no privileges at all, and a
role that could both serve requests and rewrite the schema would make
row-level security a comment (ADR-0011).

`TICKETS__SIGNINGSEED` is required. The API refuses to start without it when
it is talking to a real database — see `infrastructure/config/ticket_signing_key.dart`.

The rest is in `infra/dev/.env.example`, which names every variable this
system reads and says which ones are secrets.
