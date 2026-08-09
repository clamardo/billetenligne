#!/usr/bin/env bash
# Runs the integration suite against a real Postgres (ADR-0021 layer 3).
#
# The unit suite proves the rules. This proves the *race* — and a race cannot
# be proven against a fake, because there is no concurrency to lose to. Fifty
# travellers reaching for seat 1A at 06:00 is a real thing that will happen on
# the Brazzaville–Pointe-Noire run, and the only honest way to test it is with
# the lock manager that will actually arbitrate it.
#
#   ./tool/integration.sh
#
# Leaves the container running between local runs (it is cheap and startup is
# the slow part); the database is dropped and recreated each time, because a
# suite that inherits the previous run's rows is a suite that passes for the
# wrong reason.
#
#   BEL_KEEP_PG=0 ./tool/integration.sh   # tear the container down afterwards
#
set -euo pipefail

CONTAINER="${BEL_IT_CONTAINER:-bel-integration}"
IMAGE="postgres:17-alpine"
PORT="${BEL_IT_PORT:-5434}"
DB="billetenligne_it"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

psql_admin() {
  docker exec -i "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q "${@:2}"
}

cleanup() {
  if [[ "${BEL_KEEP_PG:-1}" != "1" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  trap cleanup EXIT
  docker run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres \
    -p "$PORT:5432" "$IMAGE" >/dev/null

  printf 'waiting for postgres'
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then break; fi
    printf '.'; sleep 1
  done
  echo
fi

echo "── database"
psql_admin postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -c "CREATE DATABASE $DB;"

# Roles are cluster-wide, so they survive the database drop. Created here
# rather than in a migration because the migrations deliberately create them
# NOLOGIN — a role that can log in is an environment decision, not a schema
# one (see 0004 and 0005).
docker exec -i "$CONTAINER" psql -U postgres -d postgres -q <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_app') THEN
    CREATE ROLE bel_app LOGIN PASSWORD 'bel_app' NOSUPERUSER NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_admin') THEN
    CREATE ROLE bel_admin LOGIN PASSWORD 'bel_admin' NOSUPERUSER NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_public') THEN
    CREATE ROLE bel_public LOGIN PASSWORD 'bel_public' NOSUPERUSER NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bel_api') THEN
    CREATE ROLE bel_api LOGIN PASSWORD 'bel_api' NOINHERIT NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;
GRANT bel_public, bel_app, bel_admin TO bel_api;
SQL

echo "── migrations"
for f in "$HERE"/infra/migrations/[0-9]*.sql; do
  printf '   %s\n' "$(basename "$f")"
  psql_admin "$DB" < "$f"
done

# bel_api connects; the suite seeds as postgres, because fixtures legitimately
# cross the tenancy boundary that the application code is forbidden to cross.
export DATABASE_URL="postgres://bel_api:bel_api@localhost:$PORT/$DB?sslmode=disable"
export SEED_DATABASE_URL="postgres://postgres:postgres@localhost:$PORT/$DB?sslmode=disable"

# The worker reads the shared catalog from disk, and its working directory is
# its own package rather than the repo root.
export BEL_I18N_DIR="$HERE/packages/bel_localization/i18n"

echo "── api"
cd "$HERE/services/api"
if ! dart test test/integration --concurrency=1 "$@"; then
  red "── integration failed"
  exit 1
fi

# Separate invocation, and deliberately so: the worker's suite writes rows the
# API's suite would otherwise see mid-run — an expired hold appearing under a
# test that is counting live ones. `--concurrency=1` keeps each suite
# sequential; running them as one would not keep them apart.
echo "── worker"
cd "$HERE/services/worker"
if ! dart test test --concurrency=1 "$@"; then
  red "── integration failed"
  exit 1
fi

green "── integration passed"
