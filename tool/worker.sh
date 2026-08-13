#!/usr/bin/env bash
# Runs a worker pass against the local dev stack.
#
#   ./tool/worker.sh                # every pass, in order
#   ./tool/worker.sh onboarding     # one of them
#   ./tool/worker.sh outbox
#
# The sibling of `tool/api_dev.sh`, and it exists for the same two reasons.
# The worker reads `DATABASE_URL` and refuses politely without it — which
# reads as "there is nothing to do" rather than as "you have not set a
# variable" — and it loads the shared catalog from disk while its working
# directory is its own package rather than the repo root. Both are one line
# each and both are the kind of line somebody debugs for twenty minutes.
#
# `infra/dev/.env` wins if it exists; the committed example is the fallback,
# so a fresh clone runs a pass with no setup step at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

ENV_FILE="$HERE/infra/dev/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$HERE/infra/dev/.env.example"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

export BEL_I18N_DIR="$HERE/packages/bel_localization/i18n"

if ! docker compose -f "$HERE/infra/dev/docker-compose.yml" \
     ps --status running --services 2>/dev/null | grep -qx postgres; then
  red "── the dev stack is not running"
  echo "   docker compose -f infra/dev/docker-compose.yml up -d --wait"
  echo "   ./tool/migrate.sh"
  exit 1
fi

echo "── env    $(basename "$ENV_FILE")"
cd "$HERE/services/worker"
exec dart run bin/worker.dart "$@"
