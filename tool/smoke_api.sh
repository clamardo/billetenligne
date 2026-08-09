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
# From scratch, every time. `dart_frog build` generates into build/ without
# removing what is already there, so a route that has been renamed or moved
# stays mounted from the previous run and the suite tests a server that no
# longer exists in the source tree. That cost an hour once.
rm -rf "$API_DIR/build"
(cd "$API_DIR" && dart_frog build >/dev/null)

# A server left over from an earlier run would answer every request below and
# the suite would pass or fail against code that is no longer in the tree. It
# happened: an orphan from the first run served forty minutes of misleading
# results before anyone looked at `ps`.
if curl -sf "$BASE/health" >/dev/null 2>&1; then
  echo "something is already serving $BASE — stop it first"; exit 1
fi

echo "── starting on :$PORT"
# `exec` so the subshell is REPLACED by dart. Without it, $! is the subshell's
# pid, the trap kills the shell, and dart is orphaned holding the port.
(cd "$API_DIR" && exec env PORT="$PORT" dart build/bin/server.dart >/tmp/bel-smoke.log 2>&1) &
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

# ── Holding a seat, over a real socket ──────────────────────────────────────
#
# The unit and integration suites both build their own request context. What
# neither exercises is the wire: header casing, the auth layer running before
# the handler, and the idempotency key arriving as an actual HTTP header.
AUTH='Authorization: Bearer fake:traveller'
DEP='dep-demo-0001'

hold() {  # $1 = idempotency key, $2 = seat labels JSON
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/holds" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $1" \
    -d "{\"departureId\":\"$DEP\",\"seatLabels\":$2}"
}

hold_body() {
  curl -s -X POST "$BASE/public/v1/holds" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $1" \
    -d "{\"departureId\":\"$DEP\",\"seatLabels\":$2}"
}

# Browsing needs no account; holding does. A hold with no owner is one nobody
# can be warned about before it expires.
check "anonymous hold is 401" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/holds" \
     -H 'Content-Type: application/json' -H 'Idempotency-Key: anon' \
     -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"1A\"]}")"

# Missing the key is a 400, not a silently accepted duplicate charge waiting
# to happen.
check "hold without an idempotency key is 400" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/holds" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"1A\"]}")"

smoke_key="smoke-$$"
body="$(hold_body "$smoke_key" '["1A"]')"
check "hold returns the seats" "yes" \
  "$(grep -q '"seatLabels":\["1A"\]' <<<"$body" && echo yes || echo no)"
check "hold prices in minor units" "yes" \
  "$(grep -q '"total":{"minor":12300,"currency":"XAF"}' <<<"$body" && echo yes || echo no)"
check "hold carries an expiry instant" "yes" \
  "$(grep -q '"expiresAt"' <<<"$body" && echo yes || echo no)"

# The retry that Congo's networks make routine. Same key, same answer, and a
# header saying so — which is how support tells "held twice" from "asked
# twice, held once".
replay="$(curl -sD - -o /dev/null -X POST "$BASE/public/v1/holds" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $smoke_key" \
  -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"1A\"]}" | tr -d '\r')"
check "a retry is flagged as a replay" "yes" \
  "$(grep -qi '^idempotency-replayed: true' <<<"$replay" && echo yes || echo no)"

# Same key, different body. Almost always a client bug, and worth failing
# loudly rather than silently picking one of the two requests.
check "key reused with a different body is 409" "409" \
  "$(hold "$smoke_key" '["1B"]')"

check "a seat already held is 409" "409" "$(hold "smoke-other-$$" '["1A"]')"
check "a seat not on the coach is 404" "404" "$(hold "smoke-ghost-$$" '["99Z"]')"
check "seven seats is 400" "400" \
  "$(hold "smoke-many-$$" '["2A","2B","2C","2D","3A","3B","3C"]')"

# ── Browsing ────────────────────────────────────────────────────────────────
#
# Open to anyone, and that is the point: forcing sign-up before a traveller
# sees a price is the largest avoidable drop-off in this funnel (ADR-0013).
TOMORROW="$(date -u -d '+1 day' +%Y-%m-%d)"
TRIPS="$BASE/public/v1/trips?from=BZV&to=PNR&date=$TOMORROW"

check "search is open to anonymous" "200" "$(status "$TRIPS")"
trips="$(curl -s "$TRIPS")"
check "search returns the demo departure" "yes" \
  "$(grep -q '"id":"dep-demo-0001"' <<<"$trips" && echo yes || echo no)"
check "search prices include the service fee" "yes" \
  "$(grep -q '"serviceFee":{"minor":300,"currency":"XAF"}' <<<"$trips" && echo yes || echo no)"
check "search echoes the query back" "yes" \
  "$(grep -q "\"date\":\"$TOMORROW\"" <<<"$trips" && echo yes || echo no)"
# A stale list is an acceptable trade for a screen that appears on 2G; a stale
# seat is not, which is why only one of these two is cacheable.
check "search is cacheable" "yes" \
  "$(curl -sD - -o /dev/null "$TRIPS" | tr -d '\r' \
     | grep -qi '^cache-control: public' && echo yes || echo no)"

check "same city both ends is 400" "400" \
  "$(status "$BASE/public/v1/trips?from=BZV&to=BZV&date=$TOMORROW")"
check "a missing date is 400" "400" \
  "$(status "$BASE/public/v1/trips?from=BZV&to=PNR")"

check "seat map is open to anonymous" "200" \
  "$(status "$BASE/public/v1/departures/dep-demo-0001/seatmap")"
seatmap="$(curl -s "$BASE/public/v1/departures/dep-demo-0001/seatmap")"
check "seat map carries seats" "yes" \
  "$(grep -q '"label":"1A"' <<<"$seatmap" && echo yes || echo no)"
check "seat map prices each seat" "yes" \
  "$(grep -q '"fare":{"minor":12000' <<<"$seatmap" && echo yes || echo no)"
# The one screen where a stale answer sells a seat twice.
check "seat map is not cached" "yes" \
  "$(curl -sD - -o /dev/null "$BASE/public/v1/departures/dep-demo-0001/seatmap" \
     | tr -d '\r' | grep -qi '^cache-control: no-store' && echo yes || echo no)"
check "unknown departure seat map is 404" "404" \
  "$(status "$BASE/public/v1/departures/nope/seatmap")"

# ── Releasing ───────────────────────────────────────────────────────────────
release_body="$(hold_body "smoke-release-$$" '["4A"]')"
release_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$release_body")"

check "release needs an account" "401" \
  "$(status -X DELETE "$BASE/public/v1/holds/$release_id")"
check "releasing returns 204" "204" \
  "$(status -X DELETE -H "$AUTH" "$BASE/public/v1/holds/$release_id")"
# Releasing twice is releasing once. The second tap of "Retour" is not a
# failure, but it is honestly reported as nothing-to-do.
check "releasing twice is 404, not an error page" "404" \
  "$(status -X DELETE -H "$AUTH" "$BASE/public/v1/holds/$release_id")"
check "the seat is back on sale" "201" "$(hold "smoke-again-$$" '["4A"]')"

check "unknown route is 404" "404" "$(status "$BASE/public/v1/nope")"

# ── The Dart client against this same server ────────────────────────────────
#
# curl proves the HTTP surface; this proves the seam the *app* actually uses —
# that the URL BelApiClient builds is the route dart_frog mounted, that header
# casing survives a socket, and that the JSON the server emits parses into the
# DTOs the screens render. Both halves have broken here before, and neither
# break is reachable from a test that builds its own request.
echo
echo "── the Dart client, over the same socket"
if client_out=$(BEL_API_URL="$BASE" dart test \
     packages/bel_client/test/live_api_test.dart --reporter=failures-only 2>&1); then
  pass=$((pass + 1))
  printf '   \033[32mok\033[0m   the typed client completes the funnel\n'
else
  fail=$((fail + 1))
  printf '   \033[31mFAIL\033[0m the typed client could not complete the funnel\n'
  echo "$client_out" | sed 's/^/       /'
fi

echo
if (( fail > 0 )); then
  printf '\033[31m── %d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
printf '\033[32m── %d smoke checks passed\033[0m\n' "$pass"
