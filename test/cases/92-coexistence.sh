#!/usr/bin/env bash
#
# Case 92: both directives coexist on SEPARATE zones with INDEPENDENT budgets.
#
# The *.coexist.example virtual host attaches BOTH soft-limit directives, each on
# its own distinct zone, key, and verdict variable:
#
#   server scope: soft_limit_req_server zone=svcoroute burst=1 set=$over_route;
#                 (POST_READ, keyed on $host  -> X-Over-Route "v=$over_route")
#   location /co: soft_limit_req        zone=svcorate  burst=1 set=$over_rate;
#                 (PREACCESS, keyed on the X-Rate-Key header -> X-Over-Rate ...)
#
# The early POST_READ routing verdict and the later PREACCESS rate-limit verdict
# must NOT interfere: tripping the routing zone must not consume/trip the rate
# zone, and tripping the rate zone must not consume/trip the routing zone. Because
# the two zones are keyed on DIFFERENT inputs ($host vs a request header), the test
# can flood exactly one axis while holding the other pristine and assert the other
# verdict stays "v=".
#
# Accounting math (burst=1 => 1.000 excess units, rate=1r/s so a slow header-
# dumping curl loop overruns the flooded bucket with a wide margin):
#   fresh bucket  -> excess <= burst -> verdict ""  (header "v=")
#   flooded bucket -> excess > burst -> verdict "1" (header "v=1")
#
# Sub-cases (each uses a $host / rate-key unique to this RUN so reruns do not
# collide in the process-lifetime shared zones; the client IP is varied so neither
# bucket — neither is IP-keyed — can be blamed):
#
#   (A) trip ONLY the routing zone: flood ONE $host while sending a FRESH, unique
#       X-Rate-Key on every request. Assert the served response shows
#       X-Over-Route "v=1" (routing tripped) AND X-Over-Rate "v=" (rate untouched).
#       If tripping the routing zone leaked into the rate zone, X-Over-Rate would
#       read "v=1" and this FAILS.
#
#   (B) trip ONLY the rate zone: flood ONE X-Rate-Key while sending a FRESH, unique
#       $host on every request. Assert the served response shows X-Over-Rate "v=1"
#       (rate tripped) AND X-Over-Route "v=" (routing untouched). If tripping the
#       rate zone leaked into the routing zone, X-Over-Route would read "v=1" and
#       this FAILS.
#
# (A) and (B) are mirror images: between them they prove independence in BOTH
# directions. Every response stays 200 (tag-don't-reject), never an error.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

run_tag="$(date +%s%N)-$$"

# get_co <host> <rate_key>: GET /co on the coexist vhost with the given Host and
# X-Rate-Key (and a random client IP), print "<code>|<route_verdict>|<rate_verdict>"
# where each verdict is the bare X-Over-* header value (e.g. "v=" or "v=1").
get_co() {
    local host="$1" rate_key="$2" dump code route rate
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: $host" \
        -H "X-Rate-Key: $rate_key" \
        -H "X-Forwarded-For: 198.51.100.$((RANDOM % 254 + 1))" \
        "$BASE_URL/co" | tr -d '\r')"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    route="$(printf '%s\n' "$dump" | header_field x-over-route:)"
    rate="$(printf '%s\n' "$dump"  | header_field x-over-rate:)"
    printf '%s|%s|%s\n' "$code" "$route" "$rate"
}

# =========================================================================
# (A) trip ONLY the routing zone (flood one $host, fresh rate key each time)
# =========================================================================
# Constant Host so svcoroute (POST_READ, $host-keyed) accumulates and goes over;
# a UNIQUE X-Rate-Key per request so svcorate (PREACCESS) never accumulates and
# stays under budget. Once the routing verdict flips to "1" we capture the served
# response and assert the rate verdict on that SAME response is still "v=".
A_HOST="route-flood-${run_tag}.coexist.example"
A_N=40
a_code=""
a_route=""
a_rate=""
a_done=0
for i in $(seq 1 "$A_N"); do
    res="$(get_co "$A_HOST" "fresh-rate-${run_tag}-${i}")"
    a_code="${res%%|*}"
    rest="${res#*|}"
    a_route="${rest%%|*}"
    a_rate="${rest##*|}"
    if [ "$a_route" = "v=1" ]; then
        a_done=1
        break
    fi
done

printf '(A) route-flood: code=%s route=%s rate=%s\n' "$a_code" "$a_route" "$a_rate"

if [ "$a_done" -eq 1 ]; then
    pass '(A) routing zone tripped under $host flood -> X-Over-Route "v=1"'
else
    fail "$(printf '(A) routing zone never tripped (last route=%s)' "$a_route")"
fi

# THE KEY ASSERTION for (A): tripping the routing zone did NOT charge the rate
# zone. On the very response where the routing verdict is "v=1", the rate verdict
# must still be "v=" (each request carried a fresh rate key, so svcorate never
# accumulated). If the budgets interfered, this reads "v=1" -> FAIL.
if [ "$a_rate" = "v=" ]; then
    pass '(A) rate zone stayed under budget while routing tripped -> "v=" (independent)'
else
    fail "$(printf '(A) rate verdict was %s on the route-tripped response (expected v=) — budgets interfered' "$a_rate")"
fi

# never rejects
if [ "$a_code" = "200" ]; then
    pass '(A) response stayed 200 (tag-don'\''t-reject)'
else
    fail "$(printf '(A) response was %s (expected 200)' "$a_code")"
fi

# =========================================================================
# (B) trip ONLY the rate zone (flood one rate key, fresh $host each time)
# =========================================================================
# Constant X-Rate-Key so svcorate (PREACCESS) accumulates and goes over; a UNIQUE
# $host per request so svcoroute (POST_READ) never accumulates and stays under
# budget. Once the rate verdict flips to "1" we capture the served response and
# assert the routing verdict on that SAME response is still "v=".
B_RATE_KEY="rate-flood-${run_tag}"
B_N=40
b_code=""
b_route=""
b_rate=""
b_done=0
for i in $(seq 1 "$B_N"); do
    res="$(get_co "fresh-host-${run_tag}-${i}.coexist.example" "$B_RATE_KEY")"
    b_code="${res%%|*}"
    rest="${res#*|}"
    b_route="${rest%%|*}"
    b_rate="${rest##*|}"
    if [ "$b_rate" = "v=1" ]; then
        b_done=1
        break
    fi
done

printf '(B) rate-flood: code=%s route=%s rate=%s\n' "$b_code" "$b_route" "$b_rate"

if [ "$b_done" -eq 1 ]; then
    pass '(B) rate zone tripped under rate-key flood -> X-Over-Rate "v=1"'
else
    fail "$(printf '(B) rate zone never tripped (last rate=%s)' "$b_rate")"
fi

# THE KEY ASSERTION for (B): tripping the rate zone did NOT charge the routing
# zone. On the very response where the rate verdict is "v=1", the routing verdict
# must still be "v=" (each request carried a fresh $host, so svcoroute never
# accumulated). If the budgets interfered, this reads "v=1" -> FAIL.
if [ "$b_route" = "v=" ]; then
    pass '(B) routing zone stayed under budget while rate tripped -> "v=" (independent)'
else
    fail "$(printf '(B) route verdict was %s on the rate-tripped response (expected v=) — budgets interfered' "$b_route")"
fi

# never rejects (tag-don't-reject; soft_limit_req does not 503)
if [ "$b_code" = "200" ]; then
    pass '(B) response stayed 200 (tag-don'\''t-reject)'
else
    fail "$(printf '(B) response was %s (expected 200)' "$b_code")"
fi

finish
