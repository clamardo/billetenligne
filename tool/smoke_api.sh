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

config_pid=""

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  [[ -n "$config_pid" ]] && kill "$config_pid" 2>/dev/null || true
  wait "$config_pid" 2>/dev/null || true
  rm -f /tmp/bel-smoke-markets.yaml /tmp/bel-smoke-markets-broken.yaml
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

# The market this run serves: the shipped file with the card rail switched on.
# Nothing else moves. A card PSP contract does not exist for this market yet,
# so `config/markets.yaml` ships `cg.card` off and this file is the only place
# it is on — which is exactly the shape ADR-0006 asks for, and it lets the
# whole card path be walked over a socket with no merchant account.
sed -e '/id: cg.card/,/disabledReasonKey/ s/enabled: false/enabled: true/' \
    -e '/id: cg.orange_money/,/disabledReasonKey/ s/enabled: false/enabled: true/' \
    "$API_DIR/../../config/markets.yaml" > /tmp/bel-smoke-markets-card.yaml

echo "── starting on :$PORT"
# `exec` so the subshell is REPLACED by dart. Without it, $! is the subshell's
# pid, the trap kills the shell, and dart is orphaned holding the port.
# Six rather than the default thirty, so the per-host bound can actually be
# reached over a socket in a few requests. The number is env-tunable for
# exactly this kind of reason — a market behind one carrier NAT needs a
# different one, and finding that out should not need a release.
# `CARD__SANDBOX` mints checkout pages that go nowhere and charge nobody. Both
# halves of the switch are needed to reach a card here — the market file has
# to announce the rail and the deployment has to have something behind it —
# and the checks below prove each half separately.
(cd "$API_DIR" && exec env PORT="$PORT" BEL_SIGNIN_MAX_PER_SOURCE=6 \
  BEL_MARKETS_FILE=/tmp/bel-smoke-markets-card.yaml \
  CARD__SANDBOX=1 ORANGE__SANDBOX=1 \
  dart build/bin/server.dart >/tmp/bel-smoke.log 2>&1) &
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

# Pagination. The list is answered a page at a time, and the cursor is the
# server's own bookmark handed back to it — a client cannot build one, which
# is what keeps the ordering a server decision rather than a shared contract.
page1="$(curl -s "$TRIPS&limit=1")"
check "a page is the size it was asked for" "yes" \
  "$(grep -o '"id":"dep-demo-[0-9]*"' <<<"$page1" | wc -l | grep -q '^1$' \
     && echo yes || echo no)"
check "and says where the next one starts" "yes" \
  "$(grep -q '"nextCursor"' <<<"$page1" && echo yes || echo no)"

cursor="$(sed 's/.*"nextCursor":"\([^"]*\)".*/\1/' <<<"$page1")"
page2="$(curl -s "$TRIPS&limit=1&cursor=$cursor")"
first_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$page1")"
check "the next page does not repeat the last row" "yes" \
  "$(grep -q "\"id\":\"$first_id\"" <<<"$page2" && echo no || echo yes)"
check "and it is not empty" "yes" \
  "$(grep -q '"id":"dep-demo-' <<<"$page2" && echo yes || echo no)"

# The whole day fits in one page by default, so the last page says nothing
# rather than offering a cursor that leads nowhere.
check "a complete list offers no cursor" "yes" \
  "$(grep -q '"nextCursor"' <<<"$trips" && echo no || echo yes)"

# Silently starting again is how a client scrolls forever reading the same
# rows and nobody finds out.
check "a cursor nobody minted is 400, not page one" "400" \
  "$(status "$TRIPS&cursor=not-a-real-cursor")"

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

# Which channels this deployment can deliver on. Announced rather than
# compiled into the app: the day a sender number is provisioned is a config
# push, not a release (ADR-0006).
market_body="$(curl -s "$BASE/public/v1/market")"
check "the market announces its sign-in channels" "yes" \
  "$(grep -q '"signInChannels":\[' <<<"$market_body" && echo yes || echo no)"
check "email is always one of them" "yes" \
  "$(grep -q '"signInChannels":\[[^]]*"email"' <<<"$market_body" && echo yes || echo no)"

# The invariant, rather than a fact about today's deployment: what the market
# announces and what the challenge route accepts are the same list. An app
# that renders a phone option the server then 503s is worse than one that
# never offered it.
if grep -q '"signInChannels":\[[^]]*"phone"' <<<"$market_body"; then
  expected_phone=202
else
  expected_phone=503
fi
check "the announcement and the route agree about phone" "$expected_phone" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/auth/challenges" \
     -H 'Content-Type: application/json' -d '{"phone":"060192286"}')"

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

# ── The passenger's own choice ──────────────────────────────────────────────
#
# `08-disruption.md` §3.2. The fakes composition has no disruption desk — a
# breakdown is not something to fake — so the screen answers for a journey
# nothing is happening to, which is itself the case worth checking: a
# passenger who follows the link and finds a 404 assumes the worst.
echo
echo "── the passenger's own choice"

booking_ref="$(sed 's/.*"ref":"\([^"]*\)".*/\1/' <<<"$booking")"

check "an anonymous caller sees nobody's options" "401" \
  "$(status "$BASE/public/v1/bookings/$booking_ref/options")"
# A reference that is not theirs reaches the same answer as one that does not
# exist. Anything else is an endpoint that tells a stranger which references
# are real.
check "somebody else's reference is not found" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/$booking_ref/options")"
check "a reference nobody issued is not found either" "404" \
  "$(status -H "$BOOK_AUTH" "$BASE/public/v1/bookings/BEL-ZZZZZZ/options")"
check "POST is not a way to read them" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/$booking_ref/options")"

check "an anonymous caller cannot choose" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/$booking_ref/choice" \
     -H 'Content-Type: application/json' -d '{"optionId":"keep"}')"
check "a choice with no option is refused by name" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/$booking_ref/choice" -H "$BOOK_AUTH" \
     -H 'Content-Type: application/json' -d '{}')"
check "GET is not a way to take one" "405" \
  "$(status -H "$BOOK_AUTH" "$BASE/public/v1/bookings/$booking_ref/choice")"
# Nothing is happening to this journey, so there is nothing to choose — a 409,
# which tells a client to say something rather than to fix its payload.
check "choosing on an undisrupted journey is refused" "409" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/$booking_ref/choice" -H "$BOOK_AUTH" \
     -H 'Content-Type: application/json' -d '{"optionId":"keep"}')"
choice_error="$(curl -s -X POST \
  "$BASE/public/v1/bookings/$booking_ref/choice" -H "$BOOK_AUTH" \
  -H 'Content-Type: application/json' -d '{"optionId":"keep"}')"
check "and the refusal is a key, never a sentence" "yes" \
  "$(grep -q 'choice.nothing_disrupted' <<<"$choice_error" && echo yes || echo no)"

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

# ── A paid booking becomes a ticket on a screen ─────────────────────────────
#
# The fake rail settles on the second poll, so the whole path — prompt, poll,
# capture, ledger, ticket — is walkable over a real socket with no
# credentials. Everything the ticket screen renders has to arrive in this one
# response: a ticket that needs a second call is a ticket that fails at a
# coach door with one bar of signal.
curl -s -o /dev/null -H "$BOOK_AUTH" "$BASE/public/v1/payments/$intent_id"
settled="$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/payments/$intent_id")"
check "polling settles the payment" "yes" \
  "$(grep -q '"state":"captured"' <<<"$settled" && echo yes || echo no)"

paid="$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/bookings")"
check "the booking is confirmed" "yes" \
  "$(grep -q '"state":"confirmed"' <<<"$paid" && echo yes || echo no)"
check "the confirmed booking carries its ticket" "yes" \
  "$(grep -q '"qrPayload"' <<<"$paid" && echo yes || echo no)"
# Without the seed the device cannot compute the 30-second code, and a
# screenshot becomes indistinguishable from the real screen (ADR-0007).
check "the ticket carries its rotating secret" "yes" \
  "$(grep -q '"rotatingSecret"' <<<"$paid" && echo yes || echo no)"
check "the ticket names its passenger and seat" "yes" \
  "$(grep -q '"passengerName"' <<<"$paid" && grep -q '"seatLabel"' <<<"$paid" \
     && echo yes || echo no)"
# A bearer that outlives its purpose is one somebody eventually finds.
check "the payment code is gone once paid" "yes" \
  "$(grep -q '"paymentCode"' <<<"$paid" && echo no || echo yes)"

# ── Paying by card, on somebody else's page ─────────────────────────────────
#
# The one rail that leaves the app. Its own booking, because the one above is
# about to be settled by the fake rail and a booking can only be paid once.
#
# What is worth proving over a socket is the shape, not the charge: the option
# is offered without a wallet number, the first answer carries a page rather
# than a promise that a handset is ringing, and the outcome is still settled
# by polling.
echo
echo "── paying by card"

check "the card rail is announced by the market file" "yes" \
  "$(grep -q '"id":"cg.card","kind":"card"[^}]*"enabled":true' <<<"$market" \
     && echo yes || echo no)"

card_hold="$(curl -s -X POST "$BASE/public/v1/holds" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-card-hold-$$" \
  -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"6A\"]}")"
card_hold_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$card_hold")"

card_booking="$(curl -s -X POST "$BASE/public/v1/bookings" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-card-booking-$$" \
  -d "{\"holdId\":\"$card_hold_id\",\"passengers\":[{\"fullName\":\"Aline M.\",\"seatLabel\":\"6A\"}]}")"
card_booking_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$card_booking")"

card_options="$(curl -s -H "$BOOK_AUTH" \
  "$BASE/public/v1/bookings/$card_booking_id/payment-options")"

check "a card is offered beside the wallets" "yes" \
  "$(grep -q '"railId":"cg.card"' <<<"$card_options" && echo yes || echo no)"
# The field the app branches on. A wallet option never carries it, so an old
# build reading a new response sees the wallets it already understood.
check "and says the card is entered elsewhere" "yes" \
  "$(grep -q '"hostedCheckout":true' <<<"$card_options" && echo yes || echo no)"
check "the card label is a catalog key" "yes" \
  "$(grep -q '"labelKey":"enum.PaymentRailKind.card"' <<<"$card_options" \
     && echo yes || echo no)"

card_pay="$(curl -s -X POST "$BASE/public/v1/payments" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-card-pay-$$" \
  -d "{\"bookingId\":\"$card_booking_id\",\"railId\":\"cg.card\",\"returnUrl\":\"billetenligne://payment/return\"}")"

# No `payerMsisdn` was sent and none was needed: a card payer may never have
# had a mobile-money account in their life.
check "a card payment starts with no wallet number" "yes" \
  "$(grep -q '"state":"pending"' <<<"$card_pay" && echo yes || echo no)"
check "it answers a page to open" "yes" \
  "$(grep -q '"redirectUrl":"https://checkout.invalid/pay/' <<<"$card_pay" \
     && echo yes || echo no)"
check "the amount still comes from the booking" "yes" \
  "$(grep -q '"amount":{"minor":12300,"currency":"XAF"}' <<<"$card_pay" \
     && echo yes || echo no)"

card_intent_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$card_pay")"

# The app may have been killed while somebody was typing a card number into a
# browser. Coming back to a screen with no page on it means a second
# transaction at the PSP for one journey.
card_polled="$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/payments/$card_intent_id")"
check "polling offers the same page again" "yes" \
  "$(grep -q '"redirectUrl":"https://checkout.invalid/pay/' <<<"$card_polled" \
     && echo yes || echo no)"
check "and it is still not paid" "yes" \
  "$(grep -q '"state":"pending"' <<<"$card_polled" && echo yes || echo no)"
# A return URL is a browser redirect and anybody can type one. Coming back
# proves nothing, and the booking stays unpaid until the rail says otherwise.
check "coming back does not confirm anything" "yes" \
  "$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/bookings" \
     | grep -q '"seatLabel":"6A"[^}]*"state":"confirmed"' && echo no || echo yes)"

# ── Orange Money, which does not push ───────────────────────────────────────
#
# The largest wallet in this market, and the one that answers with a page
# rather than a PIN prompt. What is worth proving over a socket is that
# nothing keys on the rail's *category*: this is mobile money and a hosted
# checkout at the same time, and every branch in the system reads the second
# fact rather than the first.
echo
echo "── orange money"

# Its own booking: the card one above is already paying, and a booking can
# only be paid once.
orange_hold="$(curl -s -X POST "$BASE/public/v1/holds" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-orange-hold-$$" \
  -d "{\"departureId\":\"$DEP\",\"seatLabels\":[\"7A\"]}")"
orange_hold_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$orange_hold")"

orange_booking="$(curl -s -X POST "$BASE/public/v1/bookings" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-orange-booking-$$" \
  -d "{\"holdId\":\"$orange_hold_id\",\"passengers\":[{\"fullName\":\"Aline M.\",\"seatLabel\":\"7A\"}]}")"
orange_booking_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$orange_booking")"

orange_options="$(curl -s -H "$BOOK_AUTH" \
  "$BASE/public/v1/bookings/$orange_booking_id/payment-options")"

check "orange money is offered as mobile money" "yes" \
  "$(grep -q '"railId":"cg.orange_money"' <<<"$orange_options" \
     && echo yes || echo no)"
# It has a merchant account and names it, unlike a card — the money lands in
# the operator's own Orange balance.
check "and names who is being paid" "yes" \
  "$(grep -q '"railId":"cg.orange_money","operatorId":"orange"[^}]*"collectionMsisdn":"242' \
     <<<"$orange_options" && echo yes || echo no)"
# The whole row, so the assertions below are about Orange's option and not
# about whatever else the list happens to contain.
orange_row="$(grep -o '{"railId":"cg.orange_money"[^}]*}' <<<"$orange_options")"

check "and says the payment finishes elsewhere" "yes" \
  "$(grep -q '"hostedCheckout":true' <<<"$orange_row" && echo yes || echo no)"
# A page rail has no menu to dial. Offering one would send somebody into a
# USSD session that knows nothing about this payment.
check "and offers no USSD fallback" "yes" \
  "$(grep -q '"ussdCode"' <<<"$orange_row" && echo no || echo yes)"

orange_pay="$(curl -s -X POST "$BASE/public/v1/payments" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: smoke-orange-$$" \
  -d "{\"bookingId\":\"$orange_booking_id\",\"railId\":\"cg.orange_money\"}")"

# No payerMsisdn was sent and none was needed: the traveller types their own
# number on Orange's page, which is the whole difference from MTN.
check "an orange payment needs no number from us" "yes" \
  "$(grep -q '"state":"pending"' <<<"$orange_pay" && echo yes || echo no)"
check "and answers a page to open" "yes" \
  "$(grep -q '"redirectUrl":"https://checkout.invalid/pay/' <<<"$orange_pay" \
     && echo yes || echo no)"

# ── Waiting for a seat ──────────────────────────────────────────────────────
#
# The 06:00 sells out and somebody wants to be told when it does not. There is
# no database behind this server, so what a socket can prove here is the half
# that does not need one — and it is the half that has broken before:
#
#   * the routes are mounted, under the traveller's identity and not without;
#   * a party this product does not sell to is refused by the handler, with a
#     field name, rather than by a constraint five layers down;
#   * a deployment with no store answers "nothing to wait for" rather than a
#     stack trace, which is what a fresh clone actually is;
#   * withdrawing twice succeeds twice, because somebody tapping "no longer
#     interested" got what they wanted both times.
echo
echo "── seat alerts"

check "an alert needs a name" "401" \
  "$(status -X POST "$BASE/public/v1/departures/$DEP/alerts" \
     -H 'Content-Type: application/json' -d '{"seatsWanted":1}')"

check "and so does the list of them" "401" \
  "$(status "$BASE/public/v1/alerts")"

# Seven is not a party this product sells to, and the refusal names the field
# rather than the constraint.
alert_big="$(curl -s -X POST "$BASE/public/v1/departures/$DEP/alerts" \
  -H "$BOOK_AUTH" -H 'Content-Type: application/json' -d '{"seatsWanted":9}')"
check "a party nobody can sell to is refused by name" "yes" \
  "$(grep -q '"field":"seatsWanted"' <<<"$alert_big" && echo yes || echo no)"

# No store wired in the demo composition. 404 is the honest answer — there is
# nothing to wait for — and a 500 here would be the fresh-clone experience.
check "with no store, there is nothing to wait for" "404" \
  "$(status -X POST "$BASE/public/v1/departures/$DEP/alerts" \
     -H "$BOOK_AUTH" -H 'Content-Type: application/json' -d '{"seatsWanted":1}')"

check "withdrawing succeeds" "204" \
  "$(status -X DELETE "$BASE/public/v1/departures/$DEP/alerts" -H "$BOOK_AUTH")"
check "and withdrawing again succeeds too" "204" \
  "$(status -X DELETE "$BASE/public/v1/departures/$DEP/alerts" -H "$BOOK_AUTH")"

check "the list is empty rather than absent" "yes" \
  "$(curl -s -H "$BOOK_AUTH" "$BASE/public/v1/alerts" \
     | grep -q '"items":\[\]' && echo yes || echo no)"

# ── The storefront ──────────────────────────────────────────────────────────
#
# `blt.cg/o/ODN`, over real HTTP. The demo composition seeds one operator, so
# what can be proven here is the shape and the caching — the route listing and
# the "not selling means not found" rule are covered against real Postgres in
# `vitrine_pg_test.dart`, where the policy that decides it actually exists.
storefront="$(curl -s "$BASE/public/v1/operators/ODN")"
check "a storefront is public" "200" \
  "$(status "$BASE/public/v1/operators/ODN")"
check "the storefront carries the vitrine" "yes" \
  "$(grep -q '"accentHue"' <<<"$storefront" && echo yes || echo no)"
# A code read off an agency poster is typed however it is typed.
check "a code is matched case-insensitively" "200" \
  "$(status "$BASE/public/v1/operators/odn")"
check "an unknown operator is a 404" "404" \
  "$(status "$BASE/public/v1/operators/NOPE")"
# Five minutes: a vitrine changes a few times a year, the next departure
# changes hourly, and this is the shorter of the two clocks.
check "the storefront is cacheable" "yes" \
  "$(curl -sD - -o /dev/null "$BASE/public/v1/operators/ODN" | tr -d '\r' \
     | grep -qi '^cache-control: public, max-age=300' && echo yes || echo no)"
check "the vitrine editor is closed to anonymous" "401" \
  "$(status "$BASE/console/v1/vitrine")"

# ── Brand assets ────────────────────────────────────────────────────────────
#
# The fakes composition has no object store, so what a socket can prove here is
# the *refusals* — which is the half that matters on a public URL. The upload
# round trip runs against real Azurite in `tool/storage.sh`.
check "uploading a logo is closed to anonymous" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/console/v1/vitrine/logo" -H 'Content-Type: image/png' \
     --data-binary 'not a png')"
# A traveller who found the URL. The console surface refuses them before the
# route ever looks at the path, so they learn nothing about which asset names
# exist — the same ordering the admin surface uses below.
check "a traveller cannot upload to an operator" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/console/v1/vitrine/favicon" -H "$AUTH" \
     -H 'Content-Type: image/png' --data-binary 'x')"

# ── Seat layouts refuse what would have crashed them ────────────────────────
#
# Every input below reached a 500 before this section existed. `abreast: "abc"`
# threw a FormatException out of a capacity getter, `"9+9"` walked off the end
# of the seat-letter table, and a 100000-row section asked the server to build
# a hundred thousand seat labels in a loop nobody could interrupt. All three
# are reachable by any operator's own staff, which is why they are here rather
# than in a unit test: the refusal has to happen on the socket, before the
# request reaches anything that stores or allocates.
#
# The fakes composition has no console, so a layout that IS valid answers 503.
# That is the assertion, not a limitation — 503 means the request got past
# validation and died at the database, and 400 means it never got that far.
OP_AUTH='Authorization: Bearer fake:operator'
layout_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/console/v1/fleet/layouts" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}

check "a traveller cannot draw a layout" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/fleet/layouts" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"name":"x","preset":"bus_standard_49"}')"
check "a nameless layout is refused" "400" \
  "$(layout_post '{"preset":"bus_standard_49"}')"
check "an unknown preset is refused" "400" \
  "$(layout_post '{"name":"x","preset":"nope"}')"
check "a valid preset gets past validation" "503" \
  "$(layout_post '{"name":"x","preset":"bus_standard_49"}')"
check "a preset row count that is not a number is refused" "400" \
  "$(layout_post '{"name":"x","preset":"bus_standard_49","rows":"many"}')"
# The three that used to be 500s.
check "an unparseable abreast is refused, not thrown" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":10,"abreast":"abc"}]}')"
check "an abreast wider than the seat letters is refused" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":10,"abreast":"9+9"}]}')"
check "a hundred thousand rows is refused" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":100000,"abreast":"2+2"}]}')"
check "a layout with no sections is refused" "400" \
  "$(layout_post '{"name":"x","sections":[]}')"
check "a section that is not an object is refused" "400" \
  "$(layout_post '{"name":"x","sections":["2+2"]}')"
# Two prices for one seat is not a tie to break — it is a request nobody meant
# to send, and either answer puts a fare on a seat the operator did not choose.
check "a section priced two ways at once is refused" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":4,"abreast":"2+2","fareMultiplier":1.5,"fareSupplement":500}]}')"
check "a fare multiplier of zero is refused" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":4,"abreast":"2+2","fareMultiplier":0}]}')"
check "an unknown numbering scheme is refused" "400" \
  "$(layout_post '{"name":"x","sections":[{"rows":4,"abreast":"2+2","numbering":"spiral"}]}')"
check "a hand-drawn layout gets past validation" "503" \
  "$(layout_post '{"name":"x","sections":[{"rows":10,"abreast":"2+2"},{"rows":1,"abreast":"5","startRow":11}]}')"
# The refusal names the field, because "400" alone sends an operator back to
# guess which of six sections they mistyped.
check "the refusal names the offending field" "yes" \
  "$(curl -s -X POST "$BASE/console/v1/fleet/layouts" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"name":"x","sections":[{"rows":4,"abreast":"2+2"},{"rows":4,"abreast":"zz"}]}' \
     | grep -q 'sections\[1\].abreast' && echo yes || echo no)"

# ── Stations: where a coach actually leaves from ────────────────────────────
#
# A yard is public information — a name and directions to a gate — but only an
# operator may say what theirs are called. The fakes composition has no
# console, so a well-formed station answers 503: past validation, dead at the
# database, which is the assertion.
station_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/console/v1/stations" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}

check "stations are closed to anonymous" "401" \
  "$(status "$BASE/console/v1/stations")"
check "a traveller has no stations to manage" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/stations")"
check "a nameless station is refused" "400" \
  "$(station_post '{"cityCode":"BZV"}')"
check "a station with no city is refused" "400" \
  "$(station_post '{"name":"Gare de Mikalou"}')"
# Half a coordinate is a marker in the Gulf of Guinea, and a map that puts a
# bus station in the sea is worse than a map with no marker at all.
check "half a coordinate is refused" "400" \
  "$(station_post '{"cityCode":"BZV","name":"Mikalou","lat":-4.2}')"
check "a latitude off the planet is refused" "400" \
  "$(station_post '{"cityCode":"BZV","name":"Mikalou","lat":-95,"lng":15.2}')"
check "a well-formed station gets past validation" "503" \
  "$(station_post '{"cityCode":"BZV","name":"Gare de Mikalou","lat":-4.2,"lng":15.25,"boardingNotes":"Guichet 3"}')"
check "there is no way to delete a station" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/console/v1/stations" -H "$OP_AUTH")"

# ── A road, and the towns on it ─────────────────────────────────────────────
#
# `route_stops` had existed since the first migration with nothing writing to
# it. Now the route form does, and the half a socket can prove is the half
# above the database: an itinerary that could not be honoured never reaches
# it, and the refusal names the reason rather than the table.
#
# The fakes composition has no console, so a well-formed road answers 503 —
# past validation, dead at the database — exactly as a station does.
echo
echo "── roads"

route_post() {
  curl -s -X POST "$BASE/console/v1/routes" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}
route_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/console/v1/routes" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}

road='"code":"BZV-PNR","originCity":"BZV","destinationCity":"PNR","durationMinutes":450'

check "roads are closed to anonymous" "401" \
  "$(status "$BASE/console/v1/routes")"
check "a road with no stops gets past validation" "503" \
  "$(route_status "{$road}")"

# Two stops at the same minute cannot be ordered, and an order is exactly what
# a segment will be a pair of positions in.
check "two stops at the same minute are refused" "400" \
  "$(route_status "{$road,\"stops\":[{\"cityCode\":\"DOL\",\"offsetMinutes\":180},{\"cityCode\":\"OYO\",\"offsetMinutes\":180}]}")"

# The refusal is the domain's own reason, not a generic 400 about a field
# called "stops" — the console has to be able to say which town is wrong.
after_arrival="$(route_post "{$road,\"stops\":[{\"cityCode\":\"DOL\",\"offsetMinutes\":900}]}")"
check "a stop after the arrival names itself" "yes" \
  "$(grep -q '"code":"route.invalid_itinerary"' <<<"$after_arrival" \
     && echo yes || echo no)"
check "and says which town, and why" "yes" \
  "$(grep -q '"reason":"after_arrival"' <<<"$after_arrival" \
     && grep -q '"city":"DOL"' <<<"$after_arrival" && echo yes || echo no)"

check "a stop at one of the endpoints is refused" "400" \
  "$(route_status "{$road,\"stops\":[{\"cityCode\":\"BZV\",\"offsetMinutes\":60}]}")"
check "the same town twice is refused" "400" \
  "$(route_status "{$road,\"stops\":[{\"cityCode\":\"DOL\",\"offsetMinutes\":100},{\"cityCode\":\"DOL\",\"offsetMinutes\":300}]}")"

# A stop nobody may get on or off at is a place the coach slows down. Storing
# it would put a row on a timetable no ticket can ever name.
check "a stop serving nobody is refused" "400" \
  "$(route_status "{$road,\"stops\":[{\"cityCode\":\"DOL\",\"offsetMinutes\":315,\"allowsBoarding\":false,\"allowsAlighting\":false}]}")"

# Set down only is a legitimate road, and the one the flags exist for.
check "a set-down-only stop gets past validation" "503" \
  "$(route_status "{$road,\"stops\":[{\"cityCode\":\"DOL\",\"offsetMinutes\":315,\"allowsBoarding\":false}]}")"

check "a stops field that is not a list is refused" "400" \
  "$(route_status "{$road,\"stops\":\"DOL\"}")"

# ── Refund policies refuse what would be unenforceable ──────────────────────
#
# ADR-0015 rule 1 is the rule most systems get wrong: a booking is judged by
# the policy version it was sold under, forever. The database enforces it
# (0014 revoked UPDATE on the table), so what a socket can prove here is the
# half above it — that a policy the server could not evaluate never reaches
# storage, and that each refusal names the answer to fix.
#
# As with layouts, a policy that IS well formed answers 503 in this
# composition, which is the assertion that validation ran before storage.
policy_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/console/v1/policies" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}

check "a traveller cannot write an operator's terms" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/console/v1/policies" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"name":"x","tiers":[]}')"
check "a nameless policy is refused" "400" \
  "$(policy_post '{"tiers":[]}')"
check "a policy with no tier list at all is refused" "400" \
  "$(policy_post '{"name":"x"}')"
# An EMPTY list is not the same thing: "we refund nothing" is a real answer an
# operator is entitled to give, and refusing it would force them to lie.
check "a policy that refunds nothing gets past validation" "503" \
  "$(policy_post '{"name":"Stricte","tiers":[]}')"
check "a well-formed policy gets past validation" "503" \
  "$(policy_post '{"name":"Souple","tiers":[{"minLeadTimeMinutes":2880,"rateBps":10000},{"minLeadTimeMinutes":1440,"rateBps":5000}]}')"
# The refusal that is not about typing. Tiers are matched in order, so a list
# written shortest-first answers every request with its most generous band —
# and nobody notices until the month's refunds are counted.
check "tiers written shortest-first are refused" "400" \
  "$(policy_post '{"name":"x","tiers":[{"minLeadTimeMinutes":120,"rateBps":5000},{"minLeadTimeMinutes":2880,"rateBps":10000}]}')"
check "a refund of more than 100% is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[{"minLeadTimeMinutes":1440,"rateBps":10001}]}')"
check "a negative flat fee is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[{"minLeadTimeMinutes":1440,"rateBps":10000,"flatFeeMinor":-500}]}')"
check "an unknown refund destination is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[],"destination":"cheque"}')"
# Thirty days is the ceiling. Beyond that it is not a processing window, it is
# a way of never paying.
check "a processing window of a year is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[],"processingHours":9000}')"
# The same version's other half: what a change costs (§8.1, ADR-0012 D-08).
# An absent block is the platform's defaults rather than a refusal, because a
# console that predates these three questions still writes policies.
check "a policy with no change block gets past validation" "503" \
  "$(policy_post '{"name":"Muette","tiers":[]}')"
check "well-formed change terms get past validation" "503" \
  "$(policy_post '{"name":"Reportable","tiers":[],"change":{"freeBeforeHours":48,"feeBps":1500,"cutoffHours":6}}')"
check "a change fee of more than 100% is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[],"change":{"feeBps":10001}}')"
check "a negative free window is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[],"change":{"freeBeforeHours":-1}}')"
# The refusal that no single field could have caught: a cutoff later than the
# free window charges a fee inside a window the same policy already refused.
check "a cutoff past the free window is refused" "400" \
  "$(policy_post '{"name":"x","tiers":[],"change":{"freeBeforeHours":2,"cutoffHours":48}}')"
check "the change refusal names its own field" "yes" \
  "$(curl -s -X POST "$BASE/console/v1/policies" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"name":"x","tiers":[],"change":{"feeBps":"dix"}}' \
     | grep -q 'change.feeBps' && echo yes || echo no)"

check "the refusal names the offending tier" "yes" \
  "$(curl -s -X POST "$BASE/console/v1/policies" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"name":"x","tiers":[{"minLeadTimeMinutes":2880,"rateBps":10000},{"minLeadTimeMinutes":1440,"rateBps":"half"}]}' \
     | grep -q 'tiers\[1\].rateBps' && echo yes || echo no)"

# Setting the default is a separate act from writing a policy, because the
# blast radii differ: writing one changes nothing already sold, pointing the
# default at it changes every sale from that second on.
default_put() {
  curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "$BASE/console/v1/policies/default" \
    -H "$OP_AUTH" -H 'Content-Type: application/json' -d "$1"
}
check "half a policy reference is refused" "400" \
  "$(default_put '{"policyId":"11111111-1111-1111-1111-111111111111"}')"
check "a version of zero is refused" "400" \
  "$(default_put '{"policyId":"11111111-1111-1111-1111-111111111111","version":0}')"
check "clearing the default gets past validation" "503" \
  "$(default_put '{"policyId":null,"version":null}')"
check "a traveller cannot redirect an operator's terms" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/console/v1/policies/default" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"policyId":null,"version":null}')"

# ── Refunds refuse before they reach the money ──────────────────────────────
#
# The execution path is proven against real Postgres in `refund_pg_test.dart`,
# where a transaction, a race and a balance can actually be observed. What a
# socket proves is the ordering above it: who may quote, who may pay out, and
# that a payout without a station or a reason never reaches a drawer.
check "a traveller cannot quote somebody else's refund" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/bookings/BEL-ABC123/refund")"
check "an anonymous caller cannot either" "401" \
  "$(status "$BASE/console/v1/bookings/BEL-ABC123/refund")"
check "quoting an unknown booking is a 503, not a leak" "503" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/bookings/BEL-ABC123/refund")"
# A refund with no reason is refused before anything is read. "Why did we give
# this person money?" is the question an audit answers, and it cannot be
# reconstructed afterwards.
check "a refund without a reason is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/refund" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{}')"
check "a one-word reason is not a reason" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/refund" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"reason":"x"}')"
check "a traveller cannot refund a booking" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/refund" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"reason":"give me the money"}')"

# ── The passenger who was late ──────────────────────────────────────────────
#
# What only a socket proves here is the ordering: who may look, who may move
# somebody, and that a request naming a drawer the caller is not scoped to is
# refused before any money is quoted. The transfer itself — the lock, the
# seats and the ledger — is proven in `missed_departure_pg_test.dart`.
check "a traveller cannot look for somebody else's later coach" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/bookings/BEL-ABC123/missed")"
check "an anonymous caller cannot either" "401" \
  "$(status "$BASE/console/v1/bookings/BEL-ABC123/missed")"
# The same answer a stranger's reference gets on every other booking route:
# a counter agent learns nothing about whether a reference exists somewhere
# else in the country.
check "a booking that is not this company's is not there" "404" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/bookings/BEL-ABC123/missed")"
check "a move with no departure is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/missed" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{}')"
# A well-formed move naming a drawer gets past every guard on the way in and
# dies at the missing database, which is what "the validation is upstream of
# the desk" looks like from a socket.
check "a well-formed move gets past validation" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/missed" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"departureId":"11111111-1111-1111-1111-111111111111","stationId":"st-bzv"}')"
check "a station that is not a string is a 400, naming the field" "stationId" \
  "$(curl -s -X POST "$BASE/console/v1/bookings/BEL-ABC123/missed" \
     -H "$OP_AUTH" -H 'Content-Type: application/json' \
     -d '{"departureId":"d-1","stationId":7}' \
     | grep -o 'stationId' | head -1)"
check "a traveller cannot move themselves onto a later coach" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/bookings/BEL-ABC123/missed" -H "$AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"departureId":"11111111-1111-1111-1111-111111111111"}')"
check "the counter screen is not a public one" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/BEL-ABC123/missed")"

# Paying out a claim is cash leaving a specific drawer, so it needs the
# station as well as the code — and a vendor is scoped to their own.
check "a claim without a code is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/refunds/claim" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"stationId":"st-bzv"}')"
check "a claim without a station is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/refunds/claim" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"claimCode":"K4M2QX"}')"
check "a traveller cannot open a till" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/refunds/claim" -H "$AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"claimCode":"K4M2QX","stationId":"st-bzv"}')"
check "a well-formed claim gets past validation" "503" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/refunds/claim" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' \
     -d '{"claimCode":"K4M2QX","stationId":"st-bzv"}')"

# ── The back office refuses everybody it should ─────────────────────────────
#
# The admin surface cannot be *exercised* against the fakes composition — it
# reads across tenants and audits every read, and there are no tenants to
# cross without a database. What can be proven here is the half that matters
# most on a public URL: who it turns away, and in what order.
check "the admin surface is closed to anonymous" "401" \
  "$(status "$BASE/admin/v1/operators")"
# A traveller who found the URL. Authority is checked BEFORE the reason
# header, so they learn only that they may not be here — not that there is a
# header they could have sent.
check "a traveller is refused, not prompted" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/operators")"
check "a traveller cannot decide anything" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/admin/v1/operators/00000000-0000-0000-0000-000000000000/decision" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"decision":"approve","reason":"x"}')"
check "the admin identity endpoint is closed too" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/me")"
check "the reconciliation queue is closed too" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/payments")"
check "the payout queue is closed too" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/payouts")"
# The party being paid does not get to move the row that pays them, and the
# first line of that is the same 403 everybody else gets.
check "a traveller cannot prepare a payout" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/admin/v1/payouts" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"operatorId":"00000000-0000-0000-0000-000000000001","periodStart":"2026-08-01T00:00:00Z","periodEnd":"2026-08-08T00:00:00Z"}')"
check "a traveller cannot approve one either" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/admin/v1/payouts/00000000-0000-0000-0000-000000000001/decision" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"decision":"approve"}')"
check "an operator cannot reach the payout queue" "403" \
  "$(status -H "$OP_AUTH" "$BASE/admin/v1/payouts")"

# The funnel is aggregate — no traveller, no takings, no phone number — and it
# is still behind the same wall. Anonymous learns nothing; a traveller and an
# operator learn only that they may not be here.
check "the funnel is closed to anonymous" "401" \
  "$(status "$BASE/admin/v1/analytics/funnel")"
check "a traveller cannot read the funnel" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/analytics/funnel")"
check "an operator cannot read the funnel either" "403" \
  "$(status -H "$OP_AUTH" "$BASE/admin/v1/analytics/funnel")"
# Nothing writes a funnel — but the wall answers first, so a traveller
# posting to it is refused for being a traveller rather than for using the
# wrong verb. The 405 is there for platform staff, and the surface guard is
# what a stranger meets.
check "a write attempt meets the wall, not the verb" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/admin/v1/analytics/funnel" -H "$AUTH")"

# ── An operator reads their own statements, and nothing else ────────────────
check "statements are closed to anonymous" "401" \
  "$(status "$BASE/console/v1/statements")"
check "a traveller has no statements" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/statements")"
# Past validation and into the store, which needs a database. The route
# itself is read-only by construction: there is no POST.
check "an operator gets past the capability check" "503" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/statements")"
check "there is no way to write one from the console" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/statements" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{}')"

# ── Sharing a trip, and following one ───────────────────────────────────────
#
# ADR-0014 §2. The follower page is the only surface in this product opened by
# somebody with no account, and the only one that is HTML rather than JSON —
# so what a socket proves here is exactly the part no unit test can: that the
# page is served at a short human-readable URL, that it is anonymous, and that
# the JSON behind it refuses an unknown token without saying which tokens are
# real.
page="$(curl -s "$BASE/t/abcdefghijklmnop")"
check "the follower page is served to a stranger" "200" \
  "$(status "$BASE/t/abcdefghijklmnop")"
check "it is HTML, not JSON" "yes" \
  "$(curl -s -o /dev/null -w '%{content_type}' "$BASE/t/abc" \
     | grep -q 'text/html' && echo yes || echo no)"
# Rendered before it fetches: somebody on two bars sees a page, not a white
# screen. So the words are in the response body, not fetched by the script.
check "the words come down with the page" "yes" \
  "$(grep -q 'suit un car, pas une personne' <<<"$page" && echo yes || echo no)"
# Not a search for the word — the privacy line says "ni le siège" on purpose.
# What must not be there is a field a seat, a fare or a reference could arrive
# in, because the page renders whatever the endpoint hands it.
check "and it carries no field a seat could arrive in" "yes" \
  "$(grep -qE 'seatLabel|bookingRef|fareMinor|passenger' <<<"$page" \
     && echo no || echo yes)"
check "English renders from the same catalog" "yes" \
  "$(curl -s "$BASE/t/abc?lang=en" | grep -q 'follows a coach, not a person' \
     && echo yes || echo no)"
# The page must not be frameable: a shared link is exactly the thing somebody
# would wrap in an ad page.
check "the page refuses to be framed" "DENY" \
  "$(curl -s -D - -o /dev/null "$BASE/t/abc" \
     | tr -d '\r' | awk -F': ' 'tolower($1)=="x-frame-options"{print $2}')"

check "an unissued token resolves to nothing" "404" \
  "$(status "$BASE/public/v1/trips/shared/nobody-ever-issued-this")"
check "following needs no account" "404" \
  "$(status -H 'Authorization: Bearer ' \
     "$BASE/public/v1/trips/shared/nobody-ever-issued-this")"

# The traveller's half. Sharing is authenticated and scoped to their own
# booking; a stranger's reference is the same 404 as a nonexistent one.
check "sharing is closed to anonymous" "401" \
  "$(status -X POST "$BASE/public/v1/bookings/BEL-ABC123/share")"
check "a booking that is not theirs cannot be shared" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/BEL-ABC123/share" -H "$AUTH")"
check "nor read" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/BEL-ABC123/share")"
check "a malformed reference is refused the same way" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/not-a-ref/share")"
check "there is no way to PUT a share" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/public/v1/bookings/BEL-ABC123/share" -H "$AUTH")"

# ── Cancelling, by the traveller ────────────────────────────────────────────
#
# `01-feature-spec.md` §8.2. What a socket proves here that a unit test cannot:
# that the quote and the act live at one URL under two verbs, that neither is
# reachable without a session, and — the part worth the bytes — that somebody
# else's reference is answered exactly the way a reference that never existed
# is. A cancellation endpoint that distinguished them would let anybody test
# whether a booking reference is real, and references are six characters.
check "quoting a cancellation is closed to anonymous" "401" \
  "$(status "$BASE/public/v1/bookings/BEL-ABC123/cancellation")"
check "and so is doing it" "401" \
  "$(status -X POST "$BASE/public/v1/bookings/BEL-ABC123/cancellation")"
check "a booking that is not theirs is not there" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/BEL-ABC123/cancellation")"
check "and cancelling it is the same answer" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/BEL-ABC123/cancellation" -H "$AUTH")"
check "a malformed reference is refused the same way" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/not-a-ref/cancellation")"
# No PUT and no DELETE: cancelling is a POST that writes a receipt, not the
# removal of a resource. A DELETE that half-worked would leave nothing to show
# somebody the code they are owed.
check "there is no way to DELETE a booking" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/public/v1/bookings/BEL-ABC123/cancellation" -H "$AUTH")"
check "nor to PUT one" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/public/v1/bookings/BEL-ABC123/cancellation" -H "$AUTH")"
# The refusal carries a code and no prose (ADR-0008): the sentence a traveller
# reads is rendered by their own app in their own language.
check "the refusal is a code, not a sentence" "yes" \
  "$(curl -s "$BASE/public/v1/bookings/BEL-ABC123/cancellation" -H "$AUTH" \
     | grep -qE '"code"\s*:\s*"[a-z_.]+"' && echo yes || echo no)"

# ── Changing departure ──────────────────────────────────────────────────────
#
# `01-feature-spec.md` §8.1. Same shape as cancelling and for the same reason:
# one URL, two verbs, neither reachable without a session, and both answering
# a stranger's reference exactly the way they answer one that never existed.
check "the change screen is closed to anonymous" "401" \
  "$(status "$BASE/public/v1/bookings/BEL-ABC123/reschedule")"
check "and so is taking a departure" "401" \
  "$(status -X POST "$BASE/public/v1/bookings/BEL-ABC123/reschedule")"
check "a booking that is not theirs is not there" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/BEL-ABC123/reschedule")"
check "and moving it is the same answer" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"departureId":"dep-1"}')"
# A missing target is the one refusal here that IS the client's fault, and it
# is the only 400 on this route.
check "a request with no departure is a 400, naming the field" "departureId" \
  "$(curl -s -X POST "$BASE/public/v1/bookings/BEL-ABC123/reschedule" \
     -H "$AUTH" -H 'Content-Type: application/json' -d '{}' \
     | grep -o 'departureId' | head -1)"
check "a malformed reference is refused the same way" "404" \
  "$(status -H "$AUTH" "$BASE/public/v1/bookings/not-a-ref/reschedule")"
# Giving the seats back before the window runs out. Idempotent like
# releasing a hold, so no key — and the same 404 for a booking that is not
# theirs, because this must not become a way to free other people's seats.
check "an anonymous caller cannot cancel a change" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order")"
check "a booking that is not theirs is not there" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order" -H "$AUTH")"
check "a malformed reference is refused the same way" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/public/v1/bookings/not-a-ref/reschedule/order" -H "$AUTH")"
check "there is no way to PUT an order" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order" -H "$AUTH")"

check "there is no way to DELETE a departure" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule" -H "$AUTH")"

# ── Paying the difference ───────────────────────────────────────────────────
#
# The change that owes money (§8.1). An order holds the seats and moves
# nothing; the capture moves the booking. What a socket can prove is the
# ordering above that: who may ask for one, that a stranger's reference is a
# 404 on this verb as on every other, and that the payment endpoint takes a
# change id without ever taking an amount.
check "ordering a change is closed to anonymous" "401" \
  "$(status -X POST "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order")"
check "a booking that is not theirs cannot be ordered against" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"departureId":"dep-1"}')"
check "an order with no departure is a 400, naming the field" "departureId" \
  "$(curl -s -X POST "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order" \
     -H "$AUTH" -H 'Content-Type: application/json' -d '{}' \
     | grep -o 'departureId' | head -1)"
check "a malformed reference is refused the same way" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/bookings/not-a-ref/reschedule/order" -H "$AUTH" \
     -H 'Content-Type: application/json' -d '{"departureId":"dep-1"}')"
check "there is no GET for an order" "405" \
  "$(status -H "$AUTH" \
     "$BASE/public/v1/bookings/BEL-ABC123/reschedule/order")"
# The amount is never in the request. A client names *which* debt and the
# server reads *how much* from the order's own row.
check "a payment naming an unknown change is refused" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/public/v1/payments" \
     -H "$AUTH" -H 'Content-Type: application/json' \
     -H "Idempotency-Key: smoke-change-$$" \
     -d '{"bookingId":"11111111-1111-1111-1111-111111111111","railId":"cg.fake_money","payerMsisdn":"242061234567","changeId":"22222222-2222-2222-2222-222222222222"}')"
check "payment options for an unknown change are a 404" "404" \
  "$(status -H "$AUTH" \
     "$BASE/public/v1/bookings/bk-1/payment-options?change=22222222-2222-2222-2222-222222222222")"

# ── The statement as a document ─────────────────────────────────────────────
#
# `04-payments.md` §6.2 asks for the statement as a PDF, downloadable from the
# console and readable by the back office. What a socket proves that a unit
# test cannot: that the route dart_frog mounted is the one the console builds,
# and that an operator asking for a statement id gets past the capability
# check into the store rather than into somebody else's document.
run_id="00000000-0000-0000-0000-000000000001"

check "the document is closed to anonymous" "401" \
  "$(status "$BASE/console/v1/statements/$run_id/pdf")"
check "a traveller has no statement to download" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/statements/$run_id/pdf")"
# Past the capability check and into the store, which needs a database. The
# tenancy is the read's own scope, so another operator's id is a 404 by policy
# rather than by a check in the handler.
check "an operator gets past the capability check" "503" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/statements/$run_id/pdf")"
check "a document cannot be written" "405" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/statements/$run_id/pdf" -H "$OP_AUTH")"
check "the back office reads the same document" "403" \
  "$(status -H "$AUTH" "$BASE/admin/v1/payouts/$run_id/pdf")"
check "an operator cannot read it through the back office" "403" \
  "$(status -H "$OP_AUTH" "$BASE/admin/v1/payouts/$run_id/pdf")"

# ── The second factor ───────────────────────────────────────────────────────
#
# The arithmetic is proved in the unit suite against RFC 6238's own vectors,
# and the round trip is proved by the Dart client below, which can compute a
# code. What is proved here is the part only a socket shows: who the routes
# turn away, what they refuse to echo, and that a forged half-session is a
# typed 401 rather than a stack trace.
check "the second factor is closed to anonymous" "401" \
  "$(status "$BASE/public/v1/auth/second-factor")"

mfa_status="$(curl -s -H "Authorization: Bearer $session_token" \
  "$BASE/public/v1/auth/second-factor")"
# A traveller is never asked for one. A second factor in front of a coach
# ticket is a barrier protecting one person's own bookings (ADR-0013).
check "a traveller is not obliged to hold one" "yes" \
  "$(grep -q '"required":false' <<<"$mfa_status" && echo yes || echo no)"
check "and has none enrolled" "yes" \
  "$(grep -q '"enrolled":false' <<<"$mfa_status" && echo yes || echo no)"

mfa_enrolment="$(curl -s -X POST -H "Authorization: Bearer $session_token" \
  "$BASE/public/v1/auth/second-factor")"
check "enrolment returns a scannable secret" "yes" \
  "$(grep -q '"provisioningUri":"otpauth://totp/' <<<"$mfa_enrolment" \
     && echo yes || echo no)"
# Eight, printed once. The server keeps only their HMACs.
check "enrolment returns eight recovery codes" "8" \
  "$(grep -o '"recoveryCodes":\[[^]]*\]' <<<"$mfa_enrolment" \
     | tr ',' '\n' | grep -c '[A-Z2-9]\{5\}-[A-Z2-9]\{5\}')"

# The secret is handed over once, at enrolment. A status endpoint that echoed
# it would hand every future code to anybody holding a live session.
check "the status never echoes the secret" "yes" \
  "$(curl -s -H "Authorization: Bearer $session_token" \
     "$BASE/public/v1/auth/second-factor" \
     | grep -q 'secretBase32' && echo no || echo yes)"

check "a wrong confirmation code is 401" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/auth/second-factor/confirm" \
     -H "Authorization: Bearer $session_token" \
     -H 'Content-Type: application/json' -d '{"code":"000000"}')"

# A half-session is a signed claim about who half-signed in. Without the
# signature it is a claim typed by the caller.
forged="$(curl -s -X POST "$BASE/public/v1/auth/sessions/mfa" \
  -H 'Content-Type: application/json' \
  -d '{"mfaToken":"YS1wYXlsb2Fk.notasignature","code":"000000"}')"
check "a forged half-session is refused" "yes" \
  "$(grep -q '"code":"mfa.expired"' <<<"$forged" && echo yes || echo no)"
check "the refusal carries no prose" "yes" \
  "$(grep -q '"message"' <<<"$forged" && echo no || echo yes)"
check "a half-session cannot be sent as a bearer token" "401" \
  "$(status -H "Authorization: Bearer YS1wYXlsb2Fk.notasignature" \
     "$BASE/public/v1/me")"

curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $session_token" \
  "$BASE/public/v1/auth/second-factor"

check "the profile needs an account" "401" "$(status "$BASE/public/v1/me")"
me="$(curl -s -H "Authorization: Bearer $session_token" "$BASE/public/v1/me")"
check "the profile is the address that signed in" "yes" \
  "$(grep -q "\"email\":\"$SIGNIN_EMAIL\"" <<<"$me" && echo yes || echo no)"
# Roles here would be a claim the client could edit. What a caller may do is
# decided server-side on every request (ADR-0018).
check "the profile carries no roles" "yes" \
  "$(grep -q '"roles"' <<<"$me" && echo no || echo yes)"

# ── Self-signup (03-operator-lifecycle.md §2.2) ─────────────────────────────
#
# The one surface where a member of the public writes into `operators`. What
# a socket proves here and a unit test cannot: the route is closed to
# anonymous callers, the status the applicant lands in is the only one the
# database would accept, and the two refusals that matter — a second
# application, and a submission with gaps — are typed conflicts rather than
# 500s.
echo
echo "── self-signup"

check "an application needs an account" "401" \
  "$(status "$BASE/public/v1/operator-applications")"
check "a fresh account has none" "404" \
  "$(status -H "Authorization: Bearer $session_token" \
     "$BASE/public/v1/operator-applications")"
check "a two-letter company is refused by name" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/public/v1/operator-applications" \
     -H "Authorization: Bearer $session_token" \
     -H 'Content-Type: application/json' -d '{"legalName":"OK"}')"

started="$(curl -s -X POST "$BASE/public/v1/operator-applications" \
  -H "Authorization: Bearer $session_token" \
  -H 'Content-Type: application/json' \
  -d '{"legalName":"Sotrapo SARL"}')"
check "starting one lands in application_draft" "yes" \
  "$(grep -q '"status":"application_draft"' <<<"$started" && echo yes || echo no)"
check "the operator code is generated, not chosen" "yes" \
  "$(grep -q '"code":"SOTRAP-' <<<"$started" && echo yes || echo no)"

check "a second application is a typed conflict" "yes" \
  "$(curl -s -X POST "$BASE/public/v1/operator-applications" \
     -H "Authorization: Bearer $session_token" \
     -H 'Content-Type: application/json' \
     -d '{"legalName":"Sotrapo Deux"}' \
     | grep -q '"code":"application.already_exists"' && echo yes || echo no)"

check "submitting an empty wizard is refused, with a code" "yes" \
  "$(curl -s -X POST "$BASE/public/v1/operator-applications/submit" \
     -H "Authorization: Bearer $session_token" \
     | grep -q '"code":"application.incomplete"' && echo yes || echo no)"

saved="$(curl -s -X PUT "$BASE/public/v1/operator-applications" \
  -H "Authorization: Bearer $session_token" \
  -H 'Content-Type: application/json' \
  -d '{"legalName":"Sotrapo SARL","tradingName":"Sotrapo",
       "rccmNumber":"CG-BZV-01-2019-B12-00123","taxId":"M2019110000123",
       "legalForm":"sarl","registeredAddress":"4 rue Fulbert Youlou, Dolisie",
       "yearFounded":2019,"ownerName":"Prosper Loubaki",
       "ownerIdType":"passport","ownerIdNumber":"19CD98765",
       "ownerPhone":"+242060192286","ownerEmail":"prosper@sotrapo.cg",
       "transportLicenceNumber":"TR-2025-0044",
       "transportLicenceExpires":"2032-03-31","insurerName":"NSIA Congo",
       "fleetInsuranceExpires":"2032-01-31",
       "routesServed":"Dolisie - Pointe-Noire","fleetSize":3,
       "stationCount":2,"dailyDepartures":4,"settlementKind":"momo",
       "settlementAccountName":"Sotrapo",
       "settlementAccountRef":"+242060192286","agreementAccepted":true}')"
check "the wizard saves what it was given" "yes" \
  "$(grep -q '"ownerEmail":"prosper@sotrapo.cg"' <<<"$saved" && echo yes || echo no)"
# A date, not an instant: a certificate valid until the 30th must not read as
# expired on the 30th because somebody sent UTC midnight.
check "an expiry travels as a day" "yes" \
  "$(grep -q '"fleetInsuranceExpires":"2032-01-31"' <<<"$saved" && echo yes || echo no)"

submitted="$(curl -s -X POST "$BASE/public/v1/operator-applications/submit" \
  -H "Authorization: Bearer $session_token")"
check "a complete application reaches the queue" "yes" \
  "$(grep -q '"status":"under_review"' <<<"$submitted" && echo yes || echo no)"
check "and locks behind the review" "yes" \
  "$(curl -s -X PUT "$BASE/public/v1/operator-applications" \
     -H "Authorization: Bearer $session_token" \
     -H 'Content-Type: application/json' -d '{"legalName":"Sotrapo SARL"}' \
     | grep -q '"code":"application.locked"' && echo yes || echo no)"

# The applicant never becomes staff by applying. Only activation does that,
# and the console refuses anybody who belongs to no tenant.
check "an applicant is not yet an operator" "403" \
  "$(status -H "Authorization: Bearer $session_token" "$BASE/console/v1/me")"


# ── Declaring a disruption (08-disruption.md §2.1) ──────────────────────────
#
# What a socket can prove here is the ordering above the transaction: who may
# declare, and which declarations are refused before anything is written. The
# transaction itself — record, exempt, queue, or none of it — is proved
# against real Postgres in `disruption_pg_test.dart`, because atomicity is not
# a thing a status code can show.
echo "── declaring a disruption"

DEP="00000000-0000-0000-0000-0000000000d1"

declare_as() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/console/v1/departures/$DEP/disruptions" -H "$1" \
    -H 'Content-Type: application/json' -d "$2"
}

check "an anonymous caller cannot declare one" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/departures/$DEP/disruptions" \
     -H 'Content-Type: application/json' \
     -d '{"kind":"cancellation","cause":"noVehicle"}')"
# Cancelling a coach and telling forty-two people about it is not the same
# authority as selling a seat, and it is certainly not a traveller's.
check "a traveller cannot cancel somebody's coach" "403" \
  "$(declare_as "$AUTH" '{"kind":"cancellation","cause":"noVehicle"}')"
check "a kind nobody knows is refused, not guessed at" "400" \
  "$(declare_as "$OP_AUTH" '{"kind":"volcano","cause":"weather"}')"
# The one refusal that is a domain rule rather than a syntax check: a delay
# with no new time is an apology, and a passenger cannot decide anything with
# it.
check "a delay with no new time is refused" "400" \
  "$(declare_as "$OP_AUTH" '{"kind":"delay","cause":"checkpoint"}')"
check "a well-formed breakdown gets past validation" "503" \
  "$(declare_as "$OP_AUTH" \
     '{"kind":"breakdownEnRoute","cause":"mechanical","note":"km 180 RN1"}')"
# An unknown cause is not refused — it becomes `other`. The cause feeds
# statistics; the kind decides entitlements, and only one of those is worth
# failing a roadside request over.
check "an unknown cause is absorbed rather than refused" "503" \
  "$(declare_as "$OP_AUTH" '{"kind":"cancellation","cause":"locusts"}')"
check "GET is not a way to declare one" "405" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/departures/$DEP/disruptions")"

echo
echo "── sending a rescue coach"

rescue_as() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/console/v1/departures/$DEP/rescue" -H "$1" \
    -H 'Content-Type: application/json' -d "$2"
}

check "an anonymous caller cannot swap a coach" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/departures/$DEP/rescue" \
     -H 'Content-Type: application/json' \
     -d '{"vehicleId":"00000000-0000-0000-0000-0000000000v1"}')"
# The same authority as declaring the breakdown: a swap moves forty-two people
# onto different seats and re-signs every ticket.
check "a traveller cannot swap somebody's coach" "403" \
  "$(rescue_as "$AUTH" '{"vehicleId":"00000000-0000-0000-0000-000000000001"}')"
check "a rescue with no vehicle named is refused" "400" \
  "$(rescue_as "$OP_AUTH" '{"note":"le car de secours"}')"
check "a well-formed rescue gets past validation" "503" \
  "$(rescue_as "$OP_AUTH" \
     '{"vehicleId":"00000000-0000-0000-0000-000000000001","note":"spare"}')"
check "GET is not a way to swap a coach" "405" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/departures/$DEP/rescue")"

echo
echo "── moving the passengers onto another departure"

rebook_as() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/console/v1/departures/$DEP/rebook" -H "$1" \
    -H 'Content-Type: application/json' -d "$2"
}

check "an anonymous caller cannot move anybody" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/departures/$DEP/rebook" \
     -H 'Content-Type: application/json' \
     -d '{"replacementDepartureId":"00000000-0000-0000-0000-000000000002"}')"
check "a traveller cannot move somebody's passengers" "403" \
  "$(rebook_as "$AUTH" \
     '{"replacementDepartureId":"00000000-0000-0000-0000-000000000002"}')"
# The one field the server cannot guess. "Whichever departure has room" is a
# departure nobody has looked at.
check "a wave with no replacement named is refused" "400" \
  "$(rebook_as "$OP_AUTH" '{"note":"le 14h00"}')"
check "a well-formed wave gets past validation" "503" \
  "$(rebook_as "$OP_AUTH" \
     '{"replacementDepartureId":"00000000-0000-0000-0000-000000000002"}')"
check "GET is not a way to move passengers" "405" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/departures/$DEP/rebook")"

# ── Agreeing to protect each other ──────────────────────────────────────────
#
# `08-disruption.md` §5. The commercial half of option ③: two operators write
# the terms once, in an office, instead of negotiating a seat price at the
# roadside in the rain.
#
# The fakes composition has no protection desk — an agreement is a commercial
# arrangement between two real companies and there is nothing useful to fake —
# so a well-formed proposal reaches a refusal rather than a row. What is
# proved here is the surface: who may read, who may write, and that a
# malformed corridor is a 400 rather than a 500 from a constructor.
echo
echo "── agreeing to protect each other"

propose_as() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/console/v1/protection" -H "$1" \
    -H 'Content-Type: application/json' -d "$2"
}

check "an anonymous caller sees no agreements" "401" \
  "$(status "$BASE/console/v1/protection")"
check "a traveller cannot read an operator's agreements" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/protection")"
# Reading needs only booking.read: a dispatcher has to know option ③ exists
# before a breakdown, not after.
check "the operator reads their own" "200" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/protection")"

check "an anonymous caller cannot propose one" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/protection" -H 'Content-Type: application/json' \
     -d '{"counterpartyCode":"TBV","corridors":["BZV~PNR"]}')"
check "a traveller cannot propose one either" "403" \
  "$(propose_as "$AUTH" '{"counterpartyCode":"TBV","corridors":["BZV~PNR"]}')"
# A corridor that goes nowhere is caught at the edge, with the offending
# value named, rather than throwing out of a constructor inside a transaction.
check "a corridor that goes nowhere is refused by name" "400" \
  "$(propose_as "$OP_AUTH" '{"counterpartyCode":"TBV","corridors":["BZV~BZV"]}')"
check "and so is one that is not a pair" "400" \
  "$(propose_as "$OP_AUTH" '{"counterpartyCode":"TBV","corridors":["BZV"]}')"
corridor_error="$(curl -s -X POST "$BASE/console/v1/protection" -H "$OP_AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"counterpartyCode":"TBV","corridors":["BZV~BZV"]}')"
check "the refusal names the value, not the field alone" "yes" \
  "$(grep -q 'BZV~BZV' <<<"$corridor_error" && echo yes || echo no)"
# Well-formed, and refused by the world rather than by validation: a 409,
# which is what tells a client to say something rather than fix the payload.
check "a well-formed proposal gets past validation" "409" \
  "$(propose_as "$OP_AUTH" \
     '{"counterpartyCode":"TBV","corridors":["BZV~PNR"],"rebillDiscountBps":1500}')"
check "GET is not a way to decide one" "405" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/protection/agr-1/decision")"
check "a decision nobody defined is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/protection/agr-1/decision" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"decision":"ratify"}')"

# ── Asking for the room, and answering ──────────────────────────────────────
#
# `08-disruption.md` §2.2 option ③ and §2.3. Same fakes caveat as above — no
# protection desk, so a well-formed ask reaches a refusal rather than moving
# anybody. What is proved is the surface, and one thing that is not obvious
# from reading the routes: **asking and answering need `disruption.declare`,
# not `protection.manage`.** The terms are agreed in an office by one person;
# the 05:40 decision is taken at a roadside by another.
echo
echo "── asking another company for room"

ask_as() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE/console/v1/protection/requests" -H "$1" \
    -H 'Content-Type: application/json' -d "$2"
}

check "an anonymous caller sees no requests" "401" \
  "$(status "$BASE/console/v1/protection/requests")"
check "a traveller cannot read the queue" "403" \
  "$(status -H "$AUTH" "$BASE/console/v1/protection/requests")"
check "the operator reads their own queue" "200" \
  "$(status -H "$OP_AUTH" "$BASE/console/v1/protection/requests")"

check "an anonymous caller cannot ask" "401" \
  "$(ask_as 'X-Nothing: 1' \
     '{"departureId":"'"$DEP"'","replacementDepartureId":"'"$DEP"'"}')"
check "a traveller cannot ask either" "403" \
  "$(ask_as "$AUTH" \
     '{"departureId":"'"$DEP"'","replacementDepartureId":"'"$DEP"'"}')"
# A request with nowhere to go is caught at the edge rather than inside a
# transaction that has already locked two coaches.
check "an ask with no replacement is refused by name" "400" \
  "$(ask_as "$OP_AUTH" '{"departureId":"'"$DEP"'"}')"
check "a well-formed ask gets past validation" "409" \
  "$(ask_as "$OP_AUTH" \
     '{"departureId":"'"$DEP"'","replacementDepartureId":"'"$DEP"'"}')"

check "GET is not a way to answer one" "405" \
  "$(status -H "$OP_AUTH" \
     "$BASE/console/v1/protection/requests/req-1/decision")"
check "a decision nobody defined is refused" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/protection/requests/req-1/decision" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"decision":"maybe"}')"
# Accept and decline are the two the route knows, and a request nobody has
# made is a 409 — the world refusing, not the payload.
check "answering a request that does not exist is a 409" "409" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "$BASE/console/v1/protection/requests/req-1/decision" -H "$OP_AUTH" \
     -H 'Content-Type: application/json' -d '{"decision":"accept"}')"


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

# ── A rail is switched by pushing a file ────────────────────────────────────
#
# The claim ADR-0006 makes, over a socket: the rails an app renders come from
# `config/markets.yaml`, so switching a wallet on or off is a config push and
# a restart rather than a release — which matters in a market where a large
# share of handsets never update.
#
# Off rather than on, deliberately. Turning a rail on can wait for a release;
# **turning one off is the urgent direction** — a carrier having a bad morning
# is a tile that takes a PIN and loses it, and the fix has to be a file.
#
# A second server, on its own port, started against a different file. Nothing
# is rebuilt and no Dart changes; the only difference is the YAML.
echo
echo "── a rail is switched by pushing a file"

CONFIG_PORT=$((PORT + 1))
CONFIG_BASE="http://localhost:$CONFIG_PORT"

sed -e '/id: cg.mtn_momo/,/^$/ s/enabled: true/enabled: false/' \
    -e 's/serviceFeeMinor: 300/serviceFeeMinor: 450/' \
    "$API_DIR/../../config/markets.yaml" > /tmp/bel-smoke-markets.yaml

check "the pushed file differs from the shipped one" "yes" \
  "$(cmp -s /tmp/bel-smoke-markets.yaml "$API_DIR/../../config/markets.yaml" \
    && echo no || echo yes)"

(cd "$API_DIR" && exec env PORT="$CONFIG_PORT" \
  BEL_MARKETS_FILE=/tmp/bel-smoke-markets.yaml \
  dart build/bin/server.dart >/tmp/bel-smoke-config.log 2>&1) &
config_pid=$!

for _ in $(seq 1 40); do
  if curl -sf "$CONFIG_BASE/health" >/dev/null 2>&1; then break; fi
  sleep 0.25
done

pushed="$(curl -s "$CONFIG_BASE/public/v1/market")"
check "the pushed market is served" "200" "$(status "$CONFIG_BASE/public/v1/market")"
rail_enabled() {
  # The rail objects carry nested money, so a brace-counting grep reads the
  # wrong closing brace. Parsed rather than pattern-matched.
  python3 -c 'import json,sys
rails = json.load(sys.stdin)["rails"]
row = next(r for r in rails if r["id"] == sys.argv[1])
print("yes" if row.get("enabled") else "no")' "$1"
}

check "MTN Money is now switched off" "no" \
  "$(rail_enabled cg.mtn_momo <<<"$pushed")"
check "and the running server still offers it" "yes" \
  "$(rail_enabled cg.mtn_momo <<<"$market")"
check "the service fee moved with the file" "yes" \
  "$(grep -q '"serviceFee":{"minor":450,"currency":"XAF"}' <<<"$pushed" && echo yes || echo no)"

kill "$config_pid" 2>/dev/null || true
wait "$config_pid" 2>/dev/null || true
config_pid=""

# A file that is present and wrong must not fall back. Serving last release's
# rails under a green deploy is the failure this refuses to have.
printf 'defaultMarket: CG\nmarkets:\n  - code: CG\n    currency: ZWL\n' \
  > /tmp/bel-smoke-markets-broken.yaml
(cd "$API_DIR" && exec env PORT="$CONFIG_PORT" \
  BEL_MARKETS_FILE=/tmp/bel-smoke-markets-broken.yaml \
  dart build/bin/server.dart >/tmp/bel-smoke-broken.log 2>&1) &
config_pid=$!

broken_up="no"
for _ in $(seq 1 20); do
  if curl -sf "$CONFIG_BASE/health" >/dev/null 2>&1; then broken_up="yes"; break; fi
  sleep 0.25
done

check "a malformed file does not serve stale rails" "no" "$broken_up"
check "and says which currency it could not read" "yes" \
  "$(grep -q 'unknown currency ZWL' /tmp/bel-smoke-broken.log && echo yes || echo no)"

kill "$config_pid" 2>/dev/null || true
wait "$config_pid" 2>/dev/null || true
config_pid=""


# ── One host, many addresses ────────────────────────────────────────────────
#
# Last, and deliberately: it exhausts this host's hourly budget for codes, so
# anything below it would be answered 429. The per-destination cooldown cannot
# see this shape at all — every address here is different, so not one of these
# is a resend.
echo
echo "── one host, many addresses"

source_refusal=""
source_sent=0
for i in $(seq 1 10); do
  body="$(curl -s -X POST "$BASE/public/v1/auth/challenges" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"flood-$$-$i@example.cg\"}")"
  if grep -q '"code":"otp.source_rate_limited"' <<<"$body"; then
    source_refusal="$body"
    break
  fi
  source_sent=$((source_sent + 1))
done

check "a host asking for code after code is stopped" "yes" \
  "$([[ -n "$source_refusal" ]] && echo yes || echo no)"
# The budget is six for this run; a few were spent by the sign-in above, so
# what is proved here is that the bound exists and bites well short of ten.
check "it bites before ten fresh addresses" "yes" \
  "$([[ "$source_sent" -lt 10 ]] && echo yes || echo no)"
check "the refusal says when it lifts" "yes" \
  "$(grep -q '"seconds":' <<<"$source_refusal" && echo yes || echo no)"
check "and carries no prose" "yes" \
  "$(grep -q '"message"' <<<"$source_refusal" && echo no || echo yes)"

echo
if (( fail > 0 )); then
  printf '\033[31m── %d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
printf '\033[32m── %d smoke checks passed\033[0m\n' "$pass"
