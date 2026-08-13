#!/usr/bin/env bash
# Puts a demo world into the local database, and takes it out again.
#
#   ./tool/demo.sh            # seed (re-running replaces, it does not stack)
#   ./tool/demo.sh --purge    # remove every trace of it
#
# **Why a seeded world is not a shortcut.** Several things this product does
# only happen to a company that has existed for a while: paperwork three weeks
# from lapsing, an application small enough for the onboarding pass to approve
# on its own, a second operator on the same road willing to take stranded
# passengers. Without them those paths are written and never once watched
# working. A demo world is how they get watched today rather than in the month
# the first real operator happens to hit each state.
#
# **The mark is the delete path.** Every operator it creates carries a `DEMO-`
# code and every person a `@demo.billetenligne.cg` address; `--purge` removes
# exactly those. Going to production is a command, not an afternoon at a psql
# prompt.
#
# Points at the dev compose stack by default. DATABASE_URL and
# SEED_DATABASE_URL override, so this also seeds a staging box:
#
#   DATABASE_URL=postgres://bel_api:...@host/db \
#   SEED_DATABASE_URL=postgres://postgres:...@host/db ./tool/demo.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$HERE/infra/dev/docker-compose.yml"
PORT="${BEL_DEV_PORT:-5432}"
DB="${BEL_DEV_DB:-billetenligne}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

export DATABASE_URL="${DATABASE_URL:-postgres://bel_api:bel_api@localhost:$PORT/$DB?sslmode=disable}"
export SEED_DATABASE_URL="${SEED_DATABASE_URL:-postgres://bel:bel@localhost:$PORT/$DB?sslmode=disable}"

psql_seed() {
  docker compose -f "$COMPOSE" exec -T postgres \
    psql -U bel -d "$DB" -v ON_ERROR_STOP=1 -q "$@"
}

if ! docker compose -f "$COMPOSE" ps postgres 2>/dev/null | grep -q .; then
  red "postgres is not up — run: docker compose -f infra/dev/docker-compose.yml up -d postgres"
  exit 1
fi

# The compose stack applies the roles file and nothing else, so a fresh volume
# has no schema at all. Applied only when it is missing: the migrations are
# forward-only and re-running 0001 over a live database is an error, not a
# no-op, and pretending otherwise here would hide that.
if [[ "$(psql_seed -tAc "SELECT to_regclass('public.operators') IS NULL")" == "t" ]]; then
  echo "── migrations"
  for f in "$HERE"/infra/migrations/[0-9]*.sql; do
    printf '   %s\n' "$(basename "$f")"
    psql_seed < "$f"
  done
fi

cd "$HERE"
dart run services/worker/bin/seed_demo.dart "$@"

if [[ " $* " != *" --purge "* ]]; then
  green "── the passes that finish the picture:"
  echo   "   dart run services/worker/bin/worker.dart onboarding   # approves Niari Express, flags the duplicate"
  echo   "   dart run services/worker/bin/worker.dart compliance   # stops Cars Lékana selling"
fi
