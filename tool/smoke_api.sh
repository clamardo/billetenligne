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
check "cities are public"          "200" "$(status "$BASE/public/v1/cities")"

cities="$(curl -s "$BASE/public/v1/cities")"
check "cities carry codes and names" "yes" \
  "$(grep -q '"code":"BZV","name":"Brazzaville"' <<<"$cities" && echo yes || echo no)"
# The SERVER resolves the name. A client choosing between nameFr and nameEn is
# a client that will one day choose wrong for a language it does not know it
# has (ADR-0008).
check "the city name arrives resolved" "yes" \
  "$(grep -q '"nameFr"' <<<"$cities" && echo no || echo yes)"
check "cities answer in English when asked" "yes" \
  "$(curl -s -H 'X-Language: en' "$BASE/public/v1/cities" \
     | grep -q '"name":"Brazzaville"' && echo yes || echo no)"
# Safe to be slightly out of date: a city added this morning appearing this
# afternoon costs nobody a booking, and a round trip per launch costs every
# traveller a slice of a prepaid bundle. The seat map is no-store for exactly
# the opposite reason.
check "cities are cacheable, and vary by language" "yes" \
  "$(curl -sD - -o /dev/null "$BASE/public/v1/cities" | tr -d '\r' \
     | grep -qi '^cache-control: public, max-age=3600' && echo yes || echo no)"
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

# ── Signing in ──────────────────────────────────────────────────────────────
#
# The whole loop over a real socket: ask for a code, read the code the logging
# sender wrote to the server's log (ADR-0019 — blank connection string means
# the message goes to stdout, which is exactly what makes this checkable), and
# answer it.
#
# The code is read from the LOG rather than from the response on purpose. If it
# were ever in the response this suite would still pass, and the check below
# that says it must not be is the one that would notice.
SIGNIN_EMAIL="smoke-$$@example.cg"

challenge_body="$(curl -s -X POST "$BASE/public/v1/auth/challenges" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$SIGNIN_EMAIL\"}")"

check "asking for a code is 202" "202" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/challenges" \
     -H 'Content-Type: application/json' -d '{"email":"other-'"$$"'@example.cg"}')"

check "an address that cannot be one is 400" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/challenges" \
     -H 'Content-Type: application/json' -d '{"email":"not-an-address"}')"

check "supplying both email and phone is 400" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/challenges" \
     -H 'Content-Type: application/json' \
     -d '{"email":"a@b.cg","phone":"060000000"}')"

check "the address is echoed masked" "yes" \
  "$(grep -q '"sentTo":"s\*\*\*' <<<"$challenge_body" && echo yes || echo no)"

# A second ask inside the cooldown. Every resend is a message we pay for, so
# this limit is a cost control as much as a security control (ADR-0019).
check "asking again immediately is 429" "429" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/challenges" \
     -H 'Content-Type: application/json' -d "{\"email\":\"$SIGNIN_EMAIL\"}")"

challenge_id="$(sed 's/.*"challengeId":"\([^"]*\)".*/\1/' <<<"$challenge_body")"
signin_code="$(grep -o "EMAIL → $SIGNIN_EMAIL\].*code de connexion BilletEnLigne est [0-9]\{6\}" \
  /tmp/bel-smoke.log | tail -1 | grep -o '[0-9]\{6\}$' || true)"

check "the code reached the sender, not the response" "yes" \
  "$([[ -n "$signin_code" ]] && ! grep -q "$signin_code" <<<"$challenge_body" \
    && echo yes || echo no)"

check "a wrong code is 401" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/sessions" \
     -H 'Content-Type: application/json' \
     -d "{\"challengeId\":\"$challenge_id\",\"code\":\"000000\"}")"

session_body="$(curl -s -X POST "$BASE/public/v1/auth/sessions" \
  -H 'Content-Type: application/json' \
  -d "{\"challengeId\":\"$challenge_id\",\"code\":\"$signin_code\"}")"

check "a correct code returns a credential" "yes" \
  "$(grep -q '"customToken"' <<<"$session_body" && echo yes || echo no)"
check "a first sign-in says so" "yes" \
  "$(grep -q '"isNewAccount":true' <<<"$session_body" && echo yes || echo no)"

# Replay. The consume is a conditional write, so the second answer loses.
check "the same code cannot be used twice" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/sessions" \
     -H 'Content-Type: application/json' \
     -d "{\"challengeId\":\"$challenge_id\",\"code\":\"$signin_code\"}")"

session_token="$(sed 's/.*"customToken":"\([^"]*\)".*/\1/' <<<"$session_body")"

# ── Reserving, and paying at the agency ─────────────────────────────────────
#
# The four hours the whole cash-only pilot lives in: a traveller picks a seat
# on their phone and walks to an agency with a code (`04-payments.md` §4.4).
# Over a real socket, because the price is read from the seat row inside the
# transaction that consumes the hold and nothing but a running server proves
# that path.
BOOK_AUTH="Authorization: Bearer $session_token"

book_hold="$(curl -s -X POST "$BASE/public/v1/holds" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-book-$$" \
  -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"5A\"]}")"
book_hold_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$book_hold")"

booking="$(curl -s -X POST "$BASE/public/v1/bookings" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-booking-$$" \
  -d "{\"holdId\":\"$book_hold_id\",\"passengers\":[{\"fullName\":\"Aline M.\",\"seatLabel\":\"5A\"}]}")"

check "reserving returns a booking reference" "yes" \
  "$(grep -q '"ref":"BEL-' <<<"$booking" && echo yes || echo no)"
check "a reservation is unpaid" "yes" \
  "$(grep -q '"state":"pending_payment"' <<<"$booking" && echo yes || echo no)"
check "it carries a payment code and a deadline" "yes" \
  "$(grep -q '"paymentCode"' <<<"$booking" && grep -q '"paymentDeadline"' \
     <<<"$booking" && echo yes || echo no)"
# The price is read from the seat row inside the transaction that consumes the
# hold. No number in the request could have said otherwise, because none
# travels — a client-supplied price is a client-supplied discount.
check "the price comes from the seat, not the request" "yes" \
  "$(grep -q '"total":{"minor":12300,"currency":"XAF"}' <<<"$booking" \
     && echo yes || echo no)"
# Nothing is ticketed before the money is taken. A ticket that exists before
# payment is a ticket that can board before payment.
check "an unpaid booking has no ticket" "yes" \
  "$(grep -q '"tickets"' <<<"$booking" && echo no || echo yes)"

check "reserving needs an account" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/bookings" \
     -H 'Content-Type: application/json' -H 'Idempotency-Key: anon-book' \
     -d '{"holdId":"x","passengers":[]}')"
check "reserving without an idempotency key is 400" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/bookings" \
     -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
     -d "{\"holdId\":\"$book_hold_id\",\"passengers\":[]}")"

# Booking a seat that was not held is a free seat if it works.
other_hold="$(curl -s -X POST "$BASE/public/v1/holds" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-book2-$$" \
  -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"5B\"]}")"
other_hold_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$other_hold")"
check "booking a seat that was not held is refused" "410" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/bookings" \
     -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
     -H "Idempotency-Key: smoke-wrongseat-$$" \
     -d "{\"holdId\":\"$other_hold_id\",\"passengers\":[{\"fullName\":\"X\",\"seatLabel\":\"9Z\"}]}")"

# A booking list carries a payment code and a passenger's name. A shared cache
# holding either is a shared cache leaking both.
check "the booking list is never shared-cached" "yes" \
  "$(curl -sD - -o /dev/null -H "$BOOK_AUTH" "$BASE/public/v1/bookings" \
     | tr -d '\r' | grep -qi '^cache-control: private, no-store' \
     && echo yes || echo no)"
check "a traveller sees their own booking" "yes" \
  "$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/bookings" \
     | grep -q '"state":"pending_payment"' && echo yes || echo no)"

# ── Paying by mobile money ──────────────────────────────────────────────────
#
# The fakes composition runs one fake rail with one verified collection
# account, so the whole funnel is walkable over a real socket with no
# credentials — including the states that only exist because a rail refused.
booking_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$booking")"

options="$(curl -s -H "$BOOK_AUTH" \
  "$BASE/public/v1/bookings/$booking_id/payment-options")"

check "payment options are offered" "yes" \
  "$(grep -q '"railId"' <<<"$options" && echo yes || echo no)"
# A number with no name beside it is what a scam looks like. Both travel.
check "each option says where the money goes" "yes" \
  "$(grep -q '"collectionMsisdn"' <<<"$options" \
     && grep -q '"collectionName"' <<<"$options" && echo yes || echo no)"
# The server never sends prose (ADR-0008): a catalog key, not a sentence.
check "the wallet label is a catalog key" "yes" \
  "$(grep -q '"labelKey"' <<<"$options" && echo yes || echo no)"
# Carries a merchant number and the traveller's own.
check "payment options are never shared-cached" "yes" \
  "$(curl -sD - -o /dev/null -H "$BOOK_AUTH" \
     "$BASE/public/v1/bookings/$booking_id/payment-options" \
     | tr -d '\r' | grep -qi '^cache-control: private, no-store' \
     && echo yes || echo no)"

pay_body="$(curl -s -X POST "$BASE/public/v1/payments" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-pay-$$" \
  -d "{\"bookingId\":\"$booking_id\",\"railId\":\"cg.fake_money\",\"payerMsisdn\":\"061234567\"}")"

# `pending`, never `paid`: nobody has typed a PIN yet, and saying otherwise is
# a lie the waiting screen would repeat.
check "starting a payment answers pending" "yes" \
  "$(grep -q '"state":"pending"' <<<"$pay_body" && echo yes || echo no)"
check "the amount comes from the booking" "yes" \
  "$(grep -q '"amount":{"minor":12300,"currency":"XAF"}' <<<"$pay_body" \
     && echo yes || echo no)"
check "the app is told when to poll" "yes" \
  "$(grep -q '"pollAfterSeconds"' <<<"$pay_body" && echo yes || echo no)"

check "paying needs an account" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/payments" \
     -H 'Content-Type: application/json' -H 'Idempotency-Key: anon-pay' \
     -d '{"bookingId":"x","railId":"cg.fake_money","payerMsisdn":"061234567"}')"
# A duplicate tap must not put two PIN prompts on one handset.
check "paying without an idempotency key is 400" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/payments" \
     -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
     -d "{\"bookingId\":\"$booking_id\",\"railId\":\"cg.fake_money\",\"payerMsisdn\":\"061234567\"}")"

intent_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$pay_body")"
check "the traveller can watch their own payment" "200" \
  "$(status -H "$BOOK_AUTH" "$BASE/public/v1/payments/$intent_id")"
check "another traveller cannot" "401" \
  "$(status "$BASE/public/v1/payments/$intent_id")"

# The rail refused outright: a specific code, not "payment failed".
declined="$(curl -s -X POST "$BASE/public/v1/payments" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-decline-$$" \
  -d "{\"bookingId\":\"$booking_id\",\"railId\":\"cg.fake_money\",\"payerMsisdn\":\"060000000\"}")"
check "a decline names its reason" "yes" \
  "$(grep -q '"code":"payment.insufficient_funds"' <<<"$declined" \
     && echo yes || echo no)"

# A callback is untrusted input, and an unknown reference is far more likely a
# stale retry than a problem worth breaking delivery over.
check "an unknown callback is answered 200, not 404" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/hooks/payments/fake" \
     -H 'Content-Type: application/json' -d '{"referenceId":"nope"}')"
check "a callback for an unknown rail is answered 200" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/hooks/payments/nope" \
     -H 'Content-Type: application/json' -d '{}')"

check "the profile needs an account" "401" "$(status "$BASE/public/v1/me")"
me="$(curl -s -H "Authorization: Bearer $session_token" "$BASE/public/v1/me")"
check "the profile is the address that signed in" "yes" \
  "$(grep -q "\"email\":\"$SIGNIN_EMAIL\"" <<<"$me" && echo yes || echo no)"
# Roles here would be a claim the client could edit. What a caller may do is
# decided server-side on every request (ADR-0018).
check "the profile carries no roles" "yes" \
  "$(grep -q '"roles"' <<<"$me" && echo no || echo yes)"

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
