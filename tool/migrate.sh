#!/usr/bin/env bash
# Applies every migration the local dev stack has not seen yet, in order.
#
#   ./tool/migrate.sh
#
# `infra/migrations/check.sh` applies the same files to a *throwaway* Postgres
# and asserts the guarantees hold; `tool/integration.sh` does it to a test
# container. Neither touches the database a developer is actually running
# against, which is why a fresh clone used to reach `docker compose up` and
# then a schema-less database with nothing saying so.
#
# **The migrations are forward-only, not idempotent, and this is what makes
# re-running safe.** `CREATE TYPE operator_status` on a database that already
# has one is an error, not a no-op — pretending otherwise would mean guarding
# every statement in forty files and getting one wrong. So the applied files
# are recorded in `schema_migrations`, and only what is missing runs.
#
# That table is created by the runner rather than in `0001`, because it has to
# exist before the first migration does.
#
# A database that already has a schema and no ledger — one migrated by an
# earlier version of this script — is refused rather than guessed at. Tell it
# where you are:
#
#   BEL_MIGRATE_BASELINE=0041 ./tool/migrate.sh   # 0001..0041 already applied
#
# **The applying is not done here.** It is done by
# `services/worker/bin/migrate.dart`, which is also the deployment's migration
# job — a cluster has no compose file and no `psql`, and a second
# implementation of the ledger would eventually disagree with this one about
# which files count as applied. This script is the local convenience in front
# of it: it checks the stack is up and hands over a URL.
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
PORT="${BEL_DEV_PORT:-5432}"
PASS="${BEL_DEV_PASSWORD:-bel}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

if ! docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null |
     grep -qx postgres; then
  red "── the dev stack is not running"
  echo "   docker compose -f infra/dev/docker-compose.yml up -d"
  exit 1
fi

export MIGRATE_DATABASE_URL="${MIGRATE_DATABASE_URL:-postgres://$USER_:$PASS@localhost:$PORT/$DB?sslmode=disable}"
export MIGRATIONS_DIR="$HERE/infra/migrations"
# The runner's own name for it. The old one keeps working because it is in
# three READMEs and somebody's shell history.
if [[ -n "${BEL_MIGRATE_BASELINE:-}" ]]; then
  export MIGRATE_BASELINE="$BEL_MIGRATE_BASELINE"
fi

echo "── migrations"
cd "$HERE"
if ! dart run services/worker/bin/migrate.dart; then
  red "── migrations failed"
  exit 1
fi
green "── done"
echo "   seed a world to look at:  ./tool/demo.sh"
