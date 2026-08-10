#!/usr/bin/env bash
# Runs the object-store adapter against real Azurite (ADR-0021 layer 3).
#
# Shared Key signing is the reason this exists. Thirteen lines in a precise
# order, with empty lines that are not padding, and a service that answers 403
# with no hint about which one was wrong. A unit test can assert the
# string-to-sign — and it does — but only a real blob service can tell us the
# string we agreed on is the string Azure expects.
#
#   ./tool/storage.sh
#
# Azurite ships the well-known development account and key, which are public
# and identical on every machine. They are hardcoded below for that reason:
# they are not a secret, and reading them from the environment would only make
# the script fail differently on a fresh clone.
#
#   BEL_KEEP_AZURITE=0 ./tool/storage.sh   # tear the container down afterwards
#
set -euo pipefail

CONTAINER="${BEL_AZURITE_CONTAINER:-bel-azurite}"
IMAGE="mcr.microsoft.com/azure-storage/azurite:latest"
PORT="${BEL_AZURITE_PORT:-10010}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="devstoreaccount1"
KEY="Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

cleanup() {
  if [[ "${BEL_KEEP_AZURITE:-1}" != "1" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "── azurite"
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker run -d --name "$CONTAINER" -p "$PORT:10000" "$IMAGE" \
    azurite-blob --blobHost 0.0.0.0 --skipApiVersionCheck >/dev/null
elif [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]]; then
  docker start "$CONTAINER" >/dev/null
fi

for _ in $(seq 1 40); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/$ACCOUNT?comp=list"; then break; fi
  sleep 0.5
done

echo "── storage adapter"
cd "$HERE"
if STORAGE__ACCOUNT="$ACCOUNT" \
   STORAGE__KEY="$KEY" \
   STORAGE__ENDPOINT="http://127.0.0.1:$PORT/$ACCOUNT" \
   dart test services/api --tags storage; then
  green "── storage checks passed"
else
  red "── storage checks failed"
  exit 1
fi
