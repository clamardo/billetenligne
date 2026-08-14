# The four images

```
./tool/images.sh          # the API and the worker
./tool/images.sh --web    # and the console and the back office
```

The script builds them and then **starts** them, because a Dockerfile that
compiles and produces an image that exits on its first request is a green
build and a broken deploy.

```
bel-api       the HTTP API                        23 MB   scratch + one binary
bel-worker    the passes, and the migrations      31 MB   scratch + two binaries
bel-console   the operator console                        nginx + a web bundle
bel-admin     the back office                             nginx + a web bundle
```

**All four build from the repository root.** The server is four path packages and a
route tree; none of them resolve from `services/api` alone.

## What is in the two server images, and what is not

Each is `FROM scratch` with the Dart runtime copied in and one compiled
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


## The two web images

`bel-console` and `bel-admin` are a Flutter web bundle behind unprivileged
nginx. Two things about them are worth knowing before building one.

**They are environment-specific, and that is not a mistake.** The API URL, the
Firebase project and its web key are `String.fromEnvironment` in Dart —
compile-time, because a Flutter web app has no environment to read at runtime.
So `./tool/images.sh --web` needs `BEL_API_URL` and refuses to build without
it, and an image built for staging is a staging image whose tag has to say so.
The alternative is a bundle that fetches a config file before it can do
anything, which is one more request on the critical path of a login and one
more thing to get wrong.

It also refuses a build with **neither** `BEL_FIREBASE_API_KEY` nor
`BEL_FIREBASE_EMULATOR`. The console's Firebase config defaults to
`localhost:9099`, which is right for `flutter run -d chrome` and catastrophic
in a deployment: the bundle ships pointing at an emulator that is not there,
and every sign-in fails with a network error rather than a message.

**The bundle is built outside the Dockerfile.** `tool/images.sh` runs
`flutter build web` and the image copies the result. The alternative is a
third-party Flutter SDK image in the build stage — two to three gigabytes to
pull, on a repository whose CI already installs Flutter for the widget suites.
The coupling is real and it lives in one place.

### One thing the nginx config exists to prevent

nginx inherits `add_header` only into blocks that declare none of their own.
Because `try_files` rewrites every deep link to `/index.html`, a `location =
/index.html` block that sets a cache header **silently drops the entire
security set** for most requests. The first version of this config did exactly
that: no CSP, no frame refusal, on every route but the root. The cache policy
is a `map` now, and every header is set once at the server level.
