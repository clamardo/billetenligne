#!/usr/bin/env bash
# Starts the real API and exercises it over real HTTP.
#
# This exists because two bugs shipped past a green unit suite:
#
#   1. Header lookup used the canonical casing ('If-None-Match'), but the
#      server normalises to lowercase — so conditional GET silently returned a
#      full body every time. Unit tests built the header map by hand and never
#      saw it.
#   2. The middleware chain was ordered backwards. `.use()` wraps, so the LAST
#      call is the OUTERMOST layer; the auth layer ran before the trace-id
#      layer and threw reading a value that did not exist yet. A clean 401
#      became a 500.
#
# Neither is reachable without a socket. This is ADR-0021 layer 4 in miniature,
# and it runs in CI.
#
#   ./tool/smoke_api.sh
#
set -euo pipefail

PORT="${BEL_API_PORT:-8099}"
BASE="http://localhost:$PORT"
API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../services/api" && pwd)"
PATH="$PATH:$HOME/.pub-cache/bin"

pass=0
fail=0
server_pid=""

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '   \033[32mok\033[0m   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '   \033[31mFAIL\033[0m %s\n        expected: %s\n        actual:   %s\n' \
      "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "── building"
(cd "$API_DIR" && dart_frog build >/dev/null)

echo "── starting on :$PORT"
(cd "$API_DIR" && PORT="$PORT" dart build/bin/server.dart >/tmp/bel-smoke.log 2>&1) &
server_pid=$!

for _ in $(seq 1 40); do
  if curl -sf "$BASE/health" >/dev/null 2>&1; then break; fi
  sleep 0.25
done

if ! curl -sf "$BASE/health" >/dev/null 2>&1; then
  echo "server did not start:"; cat /tmp/bel-smoke.log; exit 1
fi

echo "── checks"

check "health responds"            "200" "$(status "$BASE/health")"
check "market is public"           "200" "$(status "$BASE/public/v1/market")"
check "POST to market is refused"  "405" "$(status -X POST "$BASE/public/v1/market")"

# Browsing is deliberately open: forcing sign-up before the user sees value is
# the biggest avoidable drop-off in this funnel (ADR-0013).
check "anonymous browsing allowed" "200" "$(status "$BASE/public/v1/market")"

# A rejected token must be a typed 401, not a 500 — a 500 pages someone at
# 03:00 for what is simply an expired session.
check "bad token is 401" "401" \
  "$(status -H 'Authorization: Bearer definitely-not-valid' "$BASE/public/v1/market")"

body="$(curl -s -H 'Authorization: Bearer definitely-not-valid' "$BASE/public/v1/market")"
check "401 carries a typed code" "yes" \
  "$(grep -q '"code":"auth.unauthorized"' <<<"$body" && echo yes || echo no)"
check "401 carries a trace id" "yes" \
  "$(grep -q '"traceId"' <<<"$body" && echo yes || echo no)"
# The server never sends prose: a message field would reach a French traveller
# in whatever language the server happened to pick (ADR-0008).
check "401 sends no prose message" "yes" \
  "$(grep -q '"message"' <<<"$body" && echo no || echo yes)"

# Conditional GET. A 304 is ~0 bytes against ~1.1 KB, which on a metered
# prepaid bundle is a feature and not a micro-optimisation (ADR-0003).
etag="$(curl -sD - -o /dev/null "$BASE/public/v1/market" | tr -d '\r' \
        | grep -i '^etag:' | sed 's/^[^:]*: //')"
check "market sends an ETag" "yes" "$([[ -n "$etag" ]] && echo yes || echo no)"
check "revalidation returns 304" "304" \
  "$(status -H "If-None-Match: $etag" "$BASE/public/v1/market")"
check "304 has an empty body" "0" \
  "$(curl -s -o /dev/null -w '%{size_download}' -H "If-None-Match: $etag" "$BASE/public/v1/market")"
check "a stale ETag returns 200" "200" \
  "$(status -H 'If-None-Match: "stale"' "$BASE/public/v1/market")"

# Money on the wire is {minor, currency}. A float here loses exactness; a
# pre-formatted string forces the server to guess the reader's locale.
market="$(curl -s "$BASE/public/v1/market")"
check "fee is minor units, not a float" "yes" \
  "$(grep -q '"serviceFee":{"minor":300,"currency":"XAF"}' <<<"$market" && echo yes || echo no)"
check "currency exponent is explicit" "yes" \
  "$(grep -q '"currencyExponent":0' <<<"$market" && echo yes || echo no)"
# Rails come from the server so enabling Orange Money is a config push rather
# than an app release (ADR-0006).
check "rails are server-driven" "yes" \
  "$(grep -q '"cg.airtel_money"' <<<"$market" && echo yes || echo no)"
check "USSD fallback is advertised" "yes" \
  "$(grep -q '\*128#' <<<"$market" && echo yes || echo no)"

check "unknown route is 404" "404" "$(status "$BASE/public/v1/nope")"

echo
if (( fail > 0 )); then
  printf '\033[31m── %d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
printf '\033[32m── %d smoke checks passed\033[0m\n' "$pass"
