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
# That table is created here rather than in `0001`, because it has to exist
# before the first migration does.
#
# A database that already has a schema and no ledger — one migrated by an
# earlier version of this script — is refused rather than guessed at. Tell it
# where you are:
#
#   BEL_MIGRATE_BASELINE=0041 ./tool/migrate.sh   # 0001..0041 already applied
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

psql() {
  docker compose -f "$COMPOSE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "$USER_" -d "$DB" -q "$@"
}

if ! docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null |
     grep -qx postgres; then
  red "── the dev stack is not running"
  echo "   docker compose -f infra/dev/docker-compose.yml up -d"
  exit 1
fi

had_ledger="$(psql -tAc "SELECT to_regclass('public.schema_migrations') IS NOT NULL")"
had_schema="$(psql -tAc "SELECT to_regclass('public.operators') IS NOT NULL")"

psql -c "CREATE TABLE IF NOT EXISTS schema_migrations (
           filename   TEXT PRIMARY KEY,
           applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
         )" >/dev/null

if [[ "$had_ledger" == "f" && "$had_schema" == "t" ]]; then
  if [[ -z "${BEL_MIGRATE_BASELINE:-}" ]]; then
    red "── this database has a schema but no migration ledger"
    echo "   It was migrated before this script recorded anything, so which"
    echo "   files it has already seen is not knowable from here. Either:"
    echo
    echo "     BEL_MIGRATE_BASELINE=0041 ./tool/migrate.sh   # up to 0041"
    echo "     docker compose -f infra/dev/docker-compose.yml down -v && \\"
    echo "       docker compose -f infra/dev/docker-compose.yml up -d && \\"
    echo "       ./tool/migrate.sh                            # start over"
    exit 1
  fi
  echo "── baseline $BEL_MIGRATE_BASELINE"
  for f in "$HERE"/infra/migrations/[0-9]*.sql; do
    name="$(basename "$f")"
    [[ "${name%%_*}" > "$BEL_MIGRATE_BASELINE" ]] && continue
    psql -c "INSERT INTO schema_migrations (filename) VALUES ('$name')
             ON CONFLICT DO NOTHING" >/dev/null
  done
fi

applied=0
echo "── migrations"
for f in "$HERE"/infra/migrations/[0-9]*.sql; do
  name="$(basename "$f")"
  seen="$(psql -tAc "SELECT EXISTS (SELECT 1 FROM schema_migrations
                                     WHERE filename = '$name')")"
  [[ "$seen" == "t" ]] && continue

  printf '   %s\n' "$name"
  if ! psql < "$f"; then
    red "── $name failed"
    exit 1
  fi
  # After, never before: a file that failed halfway must run again, and it can,
  # because every migration here is a single transaction.
  psql -c "INSERT INTO schema_migrations (filename) VALUES ('$name')" >/dev/null
  applied=$((applied + 1))
done

if [[ "$applied" == 0 ]]; then
  green "── schema up to date, nothing to apply"
else
  green "── schema up to date, $applied applied"
fi
echo "   seed a world to look at:  ./tool/demo.sh"
