#!/usr/bin/env bash
# Builds the two images a deployment runs, and proves each one starts.
#
#   ./tool/images.sh                 # build both, then smoke them
#   ./tool/images.sh --push          # and push to $BEL_REGISTRY
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
[[ "${1:-}" == "--push" ]] && PUSH=1

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
if ! curl -s -H 'Accept: text/html' "http://localhost:$PORT/" | grep -q 'Réservez'; then
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

if [[ "$PUSH" == 1 ]]; then
  if [[ -z "$REGISTRY" ]]; then
    red "── --push needs BEL_REGISTRY"
    exit 1
  fi
  echo "── pushing"
  docker push "$API"
  docker push "$WORKER"
fi

green "── images built and started: $API, $WORKER"
