#!/usr/bin/env bash
#
# Case 40: coexistence with stock limit_req + map-based pool routing.
#
# The /route location attaches BOTH limiters in the SAME location:
#   limit_req      zone=perip   burst=5 nodelay;        # stock, hard-rejects
#   soft_limit_req zone=perhost2 burst=10 set=$over_host; # tag-don't-reject
# and ends in `proxy_pass http://$pool;` where
#   map $over_host $pool { "~1" quarantine_l2; default main; }
#
# The two upstreams are distinct backends: main returns "served-by-main" +
# X-Pool: main; quarantine_l2 returns "served-by-quarantine_l2" + X-Pool:
# quarantine_l2 — so the test can tell which pool served each request.
#
# The per-IP key is the realip-resolved $remote_addr; the test varies it via
# the X-Forwarded-For header (set_real_ip_from 0.0.0.0/0 in the config trusts
# it — TEST ONLY).
#
# Sub-cases:
#   (a) flood a SINGLE client IP past perip burst   -> assert 503 (stock still
#       hard-rejects, proving coexistence).
#   (b) spread the same flood across MANY client IPs (each perip bucket stays
#       under budget) but hammer ONE $host past perhost2 -> assert 200 served
#       by quarantine_l2 (proves the map read $over_host lazily in the content
#       phase and rerouted the over-cap host).
#   (c) under BOTH limits (fresh IP + fresh host, single request) -> assert 200
#       served by main.
#   (d) negative phase-order check: /route-if uses `if ($over_host) return 444;`
#       in the location body (REWRITE phase, before PREACCESS). Even under a
#       flood that sets $over_host="1" by content phase, the `if` reads empty
#       and NEVER fires 444 -> assert the response is NOT 444. Documents the
#       map-not-if caveat as an executable fact.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# helper: GET path with a given Host and X-Forwarded-For (client IP), print
# "<http_code>|<X-Pool>".
get_code_pool() {
    local host="$1" xff="$2" path="$3" dump code pool
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: $host" -H "X-Forwarded-For: $xff" "$BASE_URL$path" | tr -d '\r')"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    pool="$(printf '%s\n' "$dump" | header_field x-pool:)"
    printf '%s|%s\n' "$code" "$pool"
}

# =========================================================================
# (a) flood a single client IP past perip burst -> 503 (stock hard-rejects)
# =========================================================================
# perip: rate=1r/s burst=5 nodelay. ~7 back-to-back requests from one IP trip
# it; we send 20 to be sure. Use a host nobody else floods so the soft zone
# does not interfere with the assertion (perip rejects regardless).
A_IP="203.0.113.7"
A_HOST="single-ip.example"
A_N=20
a_saw_503=0
for _ in $(seq 1 "$A_N"); do
    res="$(get_code_pool "$A_HOST" "$A_IP" /route)"
    [ "${res%%|*}" = "503" ] && a_saw_503=1
done
if [ "$a_saw_503" -eq 1 ]; then
    pass '(a) single-IP flood tripped stock limit_req -> 503'
else
    fail "$(printf '(a) single-IP flood never produced 503 (last=%s)' "$res")"
fi

# =========================================================================
# (b) spread across many IPs (perip stays under) but flood one $host past
#     perhost2 -> 200 served by quarantine_l2
# =========================================================================
# perhost2: rate=1r/s burst=10, keyed on $host. Vary the IP each request so
# every perip bucket sees a single request (well under burst=5), but keep the
# Host constant so perhost2 accumulates and goes over -> $over_host="1" ->
# map routes to quarantine_l2.
B_HOST="grey-host.example"
B_N=40
b_pool=""
b_code=""
b_saw_q=0
b_any_503=0
for i in $(seq 1 "$B_N"); do
    res="$(get_code_pool "$B_HOST" "198.51.100.$i" /route)"
    b_code="${res%%|*}"
    b_pool="${res##*|}"
    [ "$b_code" = "503" ] && b_any_503=1
    [ "$b_pool" = "quarantine_l2" ] && b_saw_q=1
done
printf '(b) host flood across IPs: final code=%s pool=%s\n' "$b_code" "$b_pool"

if [ "$b_any_503" -eq 0 ]; then
    pass '(b) spreading across IPs never tripped perip (zero 503)'
else
    fail '(b) per-IP limit fired despite varied IPs (saw 503)'
fi

if [ "$b_saw_q" -eq 1 ]; then
    pass '(b) over-cap host routed to quarantine_l2 (map read $over_host lazily)'
else
    fail "$(printf '(b) over-cap host never reached quarantine_l2 (last pool=%s)' "$b_pool")"
fi

# trailing request for the flooded host should still be 200 via quarantine_l2
if [ "$b_code" = "200" ] && [ "$b_pool" = "quarantine_l2" ]; then
    pass '(b) trailing over-cap request is 200 via quarantine_l2 (never an error)'
else
    fail "$(printf '(b) trailing request expected 200/quarantine_l2, got %s/%s' \
        "$b_code" "$b_pool")"
fi

# =========================================================================
# (c) under BOTH limits -> 200 served by main
# =========================================================================
# Fresh host + fresh IP, single request: perip under burst, perhost2 under
# rate => $over_host="" => map -> main.
res="$(get_code_pool "calm-route.example" "192.0.2.50" /route)"
c_code="${res%%|*}"
c_pool="${res##*|}"
if [ "$c_code" = "200" ] && [ "$c_pool" = "main" ]; then
    pass '(c) under-both-limits request is 200 via main'
else
    fail "$(printf '(c) expected 200/main, got %s/%s' "$c_code" "$c_pool")"
fi

# =========================================================================
# (d) negative phase-order check: `if ($over_host)` never fires 444
# =========================================================================
# Flood /route-if past perhost2 (vary IP so perip stays clear). The location
# body has `if ($over_host) return 444;`. That `if` runs in the REWRITE phase,
# BEFORE the PREACCESS handler writes $over_host, so it always reads empty and
# 444 NEVER fires. Every response must be 200 (proxied to main), never 444.
D_HOST="if-flood.example"
D_N=40
d_saw_444=0
d_code=""
for i in $(seq 1 "$D_N"); do
    res="$(get_code_pool "$D_HOST" "198.51.100.1$i" /route-if)"
    d_code="${res%%|*}"
    [ "$d_code" = "444" ] && d_saw_444=1
done
if [ "$d_saw_444" -eq 0 ]; then
    pass '(d) `if ($over_host)` never fired 444 (rewrite phase reads empty)'
else
    fail '(d) `if ($over_host)` fired 444 — phase-order assumption broken'
fi
# and confirm the flood that should have set $over_host="1" actually did, via
# /route (map path) — so (d) is meaningful (the verdict WAS over, the if just
# could not see it). Reuse the same host on the map location and flood it in a
# tight bounded loop (vary the IP so perip never hard-rejects); perhost2
# (rate=1r/s burst=10) trips within a handful of back-to-back requests, so this
# is deterministic regardless of how far the loop above drained the bucket.
d_map_q=0
for i in $(seq 1 20); do
    res="$(get_code_pool "$D_HOST" "198.51.100.20$i" /route)"
    [ "${res##*|}" = "quarantine_l2" ] && { d_map_q=1; break; }
done
if [ "$d_map_q" -eq 1 ]; then
    pass '(d) same host IS over via map (verdict set; only the if could not read it)'
else
    fail '(d) host never tripped map path — (d) inconclusive'
fi

finish
