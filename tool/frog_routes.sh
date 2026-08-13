#!/usr/bin/env bash
# Regenerates `services/api/.dart_frog/server.dart` and stops.
#
# **Why this exists.** Dart Frog's route table is generated code: a file that
# imports every `routes/**.dart` and wires it to a path. `dart_frog dev`
# writes it on startup and `dart_frog build` writes a *copy* of the whole
# package into `build/`, and neither is what a debugger wants. The copy is the
# problem — a breakpoint set in `services/api/lib/...` never binds, because
# the process is running `build/lib/...`, a different file that merely has the
# same contents.
#
# `.dart_frog/server.dart` imports the real tree, so launching *it* under the
# debugger breaks in the sources you are editing. It is generated, so it is
# not committed, so a fresh clone needs a way to produce it without starting a
# server — which the CLI has no command for. Hence: start the dev server, wait
# for the file, stop.
#
# No database is needed. The route table is written before the entrypoint runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="$HERE/services/api"
OUT="$API/.dart_frog/server.dart"
PORT="${BEL_FROG_GEN_PORT:-8123}"

export PATH="$PATH:$HOME/.pub-cache/bin"

if ! command -v dart_frog >/dev/null; then
  printf '\033[31m%s\033[0m\n' "dart_frog is not on PATH"
  echo "   dart pub global activate dart_frog_cli"
  exit 1
fi

cd "$API"
rm -f "$OUT"

# Detached and silenced: this is a code generator today, and its server output
# would read as a second API starting.
dart_frog dev --port "$PORT" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  [[ -s "$OUT" ]] && break
  sleep 0.25
done

if [[ ! -s "$OUT" ]]; then
  printf '\033[31m%s\033[0m\n' "── the route table was not generated"
  exit 1
fi

echo "── routes  .dart_frog/server.dart"
