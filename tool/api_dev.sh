#!/usr/bin/env bash
# Runs the API against the local dev stack, with hot reload.
#
#   ./tool/api_dev.sh            # http://localhost:8080
#   BEL_API_PORT=9000 ./tool/api_dev.sh
#
# **Why a script and not `dart_frog dev`.** The server reads a dozen variables
# — the two connection strings, the sign-in HMAC key, the ticket signing seed,
# the Firebase emulator host — and every one of them already has a correct
# local value written down in `infra/dev/.env.example`. Typing them into a
# shell is how a developer ends up debugging a 503 that is really an unset
# `DATABASE_URL`, and how two developers end up on different keys.
#
# `infra/dev/.env` wins if it exists (that is where a real ACS string goes,
# and it is gitignored); the committed example is the fallback, so a fresh
# clone runs with no setup step at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${BEL_API_PORT:-8080}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

ENV_FILE="$HERE/infra/dev/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$HERE/infra/dev/.env.example"

# `set -a` exports everything the file assigns; the file is shell-shaped on
# purpose, which is also why it is sourced rather than parsed.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# The catalog is read from disk at composition time and the API's working
# directory is its own package, not the repo root.
export BEL_I18N_DIR="$HERE/packages/bel_localization/i18n"
export PATH="$PATH:$HOME/.pub-cache/bin"

if ! command -v dart_frog >/dev/null; then
  red "dart_frog is not on PATH"
  echo "   dart pub global activate dart_frog_cli"
  exit 1
fi

if ! docker compose -f "$HERE/infra/dev/docker-compose.yml" \
     ps --status running --services 2>/dev/null | grep -qx postgres; then
  red "── the dev stack is not running"
  echo "   docker compose -f infra/dev/docker-compose.yml up -d"
  echo "   ./tool/migrate.sh"
  exit 1
fi

echo "── env    $(basename "$ENV_FILE")"
echo "── api    http://localhost:$PORT"
cd "$HERE/services/api"

# `dart_frog dev` puts the terminal into raw mode so it can listen for `r` and
# `q`. With no TTY — `nohup`, a CI step, a tmux pipe — that throws
# `StdinException: Error setting terminal echo mode` from a stream callback,
# which is unhandled and takes the server down *after* it has already started
# serving. A health check passes, then the process is gone.
#
# `script` hands it a pty to be disappointed by. Only when there isn't one:
# with a real terminal the hot-reload keys should keep working.
if [[ -t 0 ]]; then
  exec dart_frog dev --port "$PORT"
fi

echo "── no tty, running under a pseudo-terminal so hot reload does not abort"
exec script -qec "dart_frog dev --port $PORT" /dev/null
