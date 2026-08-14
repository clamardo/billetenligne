#!/usr/bin/env bash
# Builds the two images a deployment runs, and proves each one starts.
#
#   ./tool/images.sh                 # the API and the worker, then smoke them
#   ./tool/images.sh --web           # and the console and the back office
#   ./tool/images.sh --push          # push what was built to $BEL_REGISTRY
#   BEL_TAG=v3 ./tool/images.sh      # a tag other than the git sha
#
# **Building is not the check.** A Dockerfile that compiles and produces an
# image that exits on its first request is a green build and a broken deploy,
# and the two failures this has actually caught are both of that kind: a
# runtime image with no translation catalog in it, and a migration runner with
# no migrations. So each image is started here and asked to do the smallest
# real thing it does — the API answers `/health`, the runner refuses politely
# with no database to talk to.
#
# The images are deliberately built from the repository root: the server is
# four path packages and a route tree, and none of them resolve from
# `services/api` alone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${BEL_REGISTRY:-}"
TAG="${BEL_TAG:-$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo dev)}"
PUSH=0
WEB=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --web)  WEB=1 ;;
    *) echo "unknown argument: $arg"; exit 64 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

name() {
  if [[ -n "$REGISTRY" ]]; then echo "$REGISTRY/bel-$1:$TAG"; else echo "bel-$1:$TAG"; fi
}

API="$(name api)"
WORKER="$(name worker)"

echo "── building $API"
docker build -f "$HERE/infra/docker/api.Dockerfile" -t "$API" "$HERE"

echo "── building $WORKER"
docker build -f "$HERE/infra/docker/worker.Dockerfile" -t "$WORKER" "$HERE"

# ── does it actually run ────────────────────────────────────────────────────
echo "── the API answers"
PORT="${BEL_IMAGE_PORT:-8099}"
CONTAINER="bel-api-smoke-$$"
docker run -d --rm --name "$CONTAINER" -p "$PORT:8080" "$API" >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

ok=0
for _ in $(seq 1 40); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.25
done
if [[ "$ok" != 1 ]]; then
  red "── the API image did not answer /health"
  docker logs "$CONTAINER" || true
  exit 1
fi

# The catalog is a directory copied into the image, and a missing one is
# invisible until somebody renders a page in French. This is that somebody.
#
# Captured into a variable rather than piped into `grep -q`: under `pipefail`,
# grep exiting early closes the pipe, curl dies of SIGPIPE, and the pipeline
# fails **because the match succeeded**. That cost twenty minutes once.
landing="$(curl -s -H 'Accept: text/html' "http://localhost:$PORT/")"
if ! grep -q 'Réservez' <<<"$landing"; then
  red "── the API image has no translation catalog in it"
  exit 1
fi
docker rm -f "$CONTAINER" >/dev/null

echo "── the migration runner refuses politely"
# No database, on purpose: what is being proven is that the binary is there,
# the migrations are there, and it fails for the reason it should rather than
# with a missing-file error nobody can read.
out="$(docker run --rm "$WORKER" 2>&1 || true)"
if ! grep -q 'MIGRATE_DATABASE_URL' <<<"$out"; then
  red "── the runner failed for the wrong reason:"
  echo "$out"
  exit 1
fi

echo "── and migrates a real database"
# The whole chain, over a socket, from the image that will actually do it:
# forty-five files copied into a scratch container reaching a Postgres it was
# not built with. `infra/migrations/check.sh` proves the SQL; this proves the
# *image*, which is a different claim and the one a deploy depends on.
PG="bel-image-pg-$$"
PGPORT="${BEL_IMAGE_PGPORT:-5439}"
docker run -d --rm --name "$PG" -e POSTGRES_PASSWORD=postgres \
  -p "$PGPORT:5432" postgres:17-alpine >/dev/null
trap 'docker rm -f "$CONTAINER" "$PG" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

out="$(docker run --rm --network host \
  -e MIGRATE_DATABASE_URL="postgres://postgres:postgres@localhost:$PGPORT/postgres?sslmode=disable" \
  "$WORKER" 2>&1)" || { red "── the runner failed:"; echo "$out"; exit 1; }

if ! grep -q 'schema up to date' <<<"$out"; then
  red "── the runner did not finish:"
  echo "$out"
  exit 1
fi
printf '   %s\n' "$(tail -1 <<<"$out")"
docker rm -f "$PG" >/dev/null

built=("$API" "$WORKER")

# ── the two web apps ────────────────────────────────────────────────────────
#
# Opt-in, because unlike the server images these are **environment-specific**
# and cannot be built without being told which environment. The API URL, the
# Firebase project and its web key are `String.fromEnvironment` in Dart —
# compile-time, because a Flutter web app has no environment to read at
# runtime — so the values are baked in and an image built for staging is a
# staging image.
if [[ "$WEB" == 1 ]]; then
  if ! command -v flutter >/dev/null 2>&1; then
    red "── --web needs the Flutter SDK on PATH"
    exit 1
  fi
  if [[ -z "${BEL_API_URL:-}" ]]; then
    red "── --web needs BEL_API_URL — the address these builds will call"
    exit 1
  fi
  # The console's Firebase config defaults to the local emulator, which is
  # right for `flutter run` and catastrophic in a deployment: the bundle would
  # ship pointing at localhost:9099, and every sign-in would fail with a
  # network error rather than a message. A build must say which it is.
  if [[ -z "${BEL_FIREBASE_EMULATOR:-}" && -z "${BEL_FIREBASE_API_KEY:-}" ]]; then
    red "── set BEL_FIREBASE_API_KEY, or BEL_FIREBASE_EMULATOR for a local build"
    echo "   Neither is set, so this bundle could not sign anybody in."
    exit 1
  fi

  for app in console admin; do
    echo "── building the $app bundle"
    (cd "$HERE/apps/$app" && flutter build web --release \
      --dart-define=BEL_API_URL="$BEL_API_URL" \
      --dart-define=BEL_FIREBASE_EMULATOR="${BEL_FIREBASE_EMULATOR:-}" \
      --dart-define=BEL_FIREBASE_PROJECT="${BEL_FIREBASE_PROJECT:-demo-billetenligne}" \
      --dart-define=BEL_FIREBASE_API_KEY="${BEL_FIREBASE_API_KEY:-}" >/dev/null)

    image="$(name "$app")"
    echo "── building $image"
    docker build -f "$HERE/infra/docker/web.Dockerfile" \
      --build-arg APP="$app" -t "$image" "$HERE"

    echo "── the $app answers, and a deep link is not a 404"
    web="bel-$app-smoke-$$"
    docker run -d --rm --name "$web" -p "$PORT:8080" "$image" >/dev/null
    ok=0
    for _ in $(seq 1 40); do
      curl -sf "http://localhost:$PORT/" >/dev/null 2>&1 && { ok=1; break; }
      sleep 0.25
    done
    if [[ "$ok" != 1 ]]; then
      red "── the $app image did not answer"
      docker logs "$web" || true; docker rm -f "$web" >/dev/null; exit 1
    fi
    # A refresh on a deep link is the commonest thing anybody does to a
    # single-page app, and the default nginx answer to it is 404.
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/fleet/coaches")"
    if [[ "$code" != 200 ]]; then
      red "── a deep link into the $app answered $code"
      docker rm -f "$web" >/dev/null; exit 1
    fi
    # The URL is compiled in. If it is not in the bundle, this image is
    # pointed somewhere else and nothing about running it would say so.
    bundle="$(curl -s "http://localhost:$PORT/main.dart.js")"
    if ! grep -qF "$BEL_API_URL" <<<"$bundle"; then
      red "── the $app bundle does not carry $BEL_API_URL"
      docker rm -f "$web" >/dev/null; exit 1
    fi
    docker rm -f "$web" >/dev/null
    built+=("$image")
  done
fi

if [[ "$PUSH" == 1 ]]; then
  if [[ -z "$REGISTRY" ]]; then
    red "── --push needs BEL_REGISTRY"
    exit 1
  fi
  echo "── pushing"
  for image in "${built[@]}"; do docker push "$image"; done
fi

green "── built and started: ${built[*]}"
