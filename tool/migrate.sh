#!/usr/bin/env bash
# Applies every migration to the local dev stack, in order.
#
#   ./tool/migrate.sh
#
# `infra/migrations/check.sh` applies the same files to a *throwaway* Postgres
# and asserts the guarantees hold; `tool/integration.sh` does it to a test
# container. Neither touches the database a developer is actually running
# against, which is why a fresh clone used to reach `docker compose up` and
# then a schema-less database with nothing saying so.
#
# Every migration is idempotent enough to re-run — that is a property the
# files already had, because `check.sh` applies them to a container that may
# already exist. So this is safe to run after every `git pull`, which is when
# it matters.
#
# DATABASE_URL is not read on purpose: migrations own the tables, and the
# application user is deliberately not a superuser — a superuser owning them
# would make row-level security a comment (ADR-0011). It goes in as `bel`, the
# compose stack's bootstrap user, which is the one role in the dev cluster
# allowed to create schema.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$HERE/infra/dev/docker-compose.yml"
DB="${BEL_DEV_DB:-billetenligne}"
USER_="${BEL_DEV_USER:-bel}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

if ! docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null |
     grep -qx postgres; then
  red "── the dev stack is not running"
  echo "   docker compose -f infra/dev/docker-compose.yml up -d"
  exit 1
fi

echo "── migrations"
for f in "$HERE"/infra/migrations/[0-9]*.sql; do
  printf '   %s\n' "$(basename "$f")"
  if ! docker compose -f "$COMPOSE" exec -T postgres \
       psql -v ON_ERROR_STOP=1 -U "$USER_" -d "$DB" -q < "$f"; then
    red "── $(basename "$f") failed"
    exit 1
  fi
done

green "── schema up to date"
echo "   seed a world to look at:  ./tool/demo.sh"
