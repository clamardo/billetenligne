#!/usr/bin/env bash
# Applies every migration to a throwaway Postgres and asserts the guarantees
# actually hold (ADR-0021 layer 3).
#
# Runs in CI on every pull request. A schema that only compiles is not a
# schema that isolates tenants, balances a ledger, or refuses to let someone
# edit an audit trail — so all three are executed, not assumed.
#
#   ./infra/migrations/check.sh
#
set -euo pipefail

CONTAINER="${BEL_PG_CONTAINER:-bel-schema-check}"
IMAGE="postgres:17-alpine"
DB="belcheck"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

psql_run() {
  docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q "$@"
}

cleanup() {
  if [[ "${BEL_KEEP_PG:-0}" != "1" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}

# Reuse a running container across local runs; always start from a clean
# database, because a suite that inherits the previous run's rows is a suite
# that passes for the wrong reason.
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  trap cleanup EXIT
  docker run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=check -e POSTGRES_DB=postgres \
    "$IMAGE" >/dev/null

  printf 'waiting for postgres'
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then break; fi
    printf '.'; sleep 1
  done
  echo
fi

docker exec -i "$CONTAINER" psql -U postgres -d postgres -q \
  -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -c "CREATE DATABASE $DB;"

echo "── migrations"
for f in "$HERE"/[0-9]*.sql; do
  printf '   %s\n' "$(basename "$f")"
  psql_run < "$f"
done

echo "── guarantees"
psql_run -v ON_ERROR_STOP=1 < "$HERE/verify.sql" 2>&1 \
  | grep -E 'NOTICE|PASSED' | sed 's/^NOTICE:  /   /'

# The balance trigger is DEFERRABLE INITIALLY DEFERRED, so it fires at COMMIT —
# after any DO block has returned, and beyond the reach of a plpgsql handler.
# It gets its own invocation, and must fail for the stated reason.
echo "── deferred ledger balance"
if out=$(psql_run < "$HERE/verify_unbalanced.sql" 2>&1); then
  red "   FAIL: an unbalanced ledger transaction committed"
  exit 1
elif grep -q 'does not balance' <<<"$out"; then
  echo "   OK  an unbalanced transaction is rejected at COMMIT"
else
  red "   FAIL: rejected, but not by the balance check:"
  echo "$out" | sed 's/^/       /'
  exit 1
fi

green "── schema checks passed"
