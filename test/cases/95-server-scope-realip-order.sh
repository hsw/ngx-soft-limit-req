#!/usr/bin/env bash
#
# Case 95: GROUND TRUTH + FOOTGUN — soft_limit_req_server (POST_READ) runs
# BEFORE the built-in ngx_http_realip_module's POST_READ handler, so a
# $remote_addr-keyed server zone sees the RAW TCP peer at POST_READ, not the
# realip-rewritten client IP.
#
# This case ALSO demonstrates the cache-poisoning side effect, which is the
# DANGEROUS part: $remote_addr is a CACHEABLE variable (its get_handler sets
# no_cacheable=0). Our key is a compiled complex value evaluated via the indexed
# (caching) variable path, so the POST_READ eval populates and caches
# r->variables[$remote_addr] with the RAW peer. realip later rewrites only
# r->connection->addr_text/sockaddr -- it does NOT invalidate that variable
# cache. So EVERY later $remote_addr read in the same request (proxy_set_header,
# access logs, maps, the PREACCESS limiter, and X-Remote here) returns the SAME
# stale raw peer. (a) below asserts exactly that constancy: it is the poisoning,
# not a benign coincidence. DO NOT key soft_limit_req_server on $remote_addr in
# production; use $host/$http_* (server scope) or location-level soft_limit_req
# (PREACCESS) for per-real-client limiting. See README key-readiness section.
#
# Why (verified against pinned nginx 1.31.1):
#   - Both realip and this module register their handler in NGX_HTTP_POST_READ_PHASE
#     (realip: src/http/modules/ngx_http_realip_module.c:526; ours: the second
#     ngx_array_push in ngx_http_soft_limit_req_init).
#   - postconfiguration runs in FORWARD module order (ngx_http.c: for m=0..).
#     A --add-dynamic-module module is appended LAST in the module array
#     (ngx_add_module, ngx_module.c: before = cycle->modules_n when no order),
#     so OUR postconfiguration runs AFTER realip's -> we push our POST_READ
#     handler AFTER realip's.
#   - ngx_http_init_phase_handlers (ngx_http.c) flattens each phase's handlers in
#     REVERSE push order: `for (j = nelts-1; j >= 0; j--)`. The LAST-pushed handler
#     becomes phase_engine[FIRST] and executes FIRST.
#   => OUR handler runs BEFORE realip rewrites $remote_addr.
#
# The *.realip.example vhost trusts X-Forwarded-For globally and keys svrealip
# (burst defaulted to 0) on $remote_addr. This case floods it varying ONLY the XFF client IP
# (the real TCP peer is constant). If realip ran first, each XFF IP would be a
# distinct bucket and the flood would NEVER trip. It DOES trip -> proves our
# handler ran first on the raw (constant) peer.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# Per-run unique host so a case-level rerun against the long-lived container does
# not read a bucket an earlier run already pushed over budget (run_tag idiom).
run_tag="$(date +%s%N)-$$"
HOST="r1-${run_tag}.realip.example"

# GET / with a given XFF client IP; print "<code>|<X-Over-Srv>|<X-Remote>".
get_over_remote() {
    local xff="$1" dump code over remote
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: $HOST" -H "X-Forwarded-For: $xff" "$BASE_URL/" 2>/dev/null | tr -d '\r')"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-srv:)"
    remote="$(printf '%s\n' "$dump" | header_field x-remote:)"
    printf '%s|%s|%s\n' "$code" "$over" "$remote"
}

# =========================================================================
# (a) CACHE POISONING: content-phase $remote_addr stays the CONSTANT raw peer
#     across varied XFF (proves our POST_READ key eval poisoned the cache)
# =========================================================================
# X-Remote surfaces $remote_addr in the content phase. Two requests carrying
# DIFFERENT XFF IPs report the SAME $remote_addr. If realip had run first (and
# nothing poisoned the cache), the content-phase $remote_addr would be the
# realip-rewritten, per-request-distinct XFF IP. Instead it is the constant
# docker-bridge raw peer for BOTH requests: our POST_READ key eval read the
# cacheable $remote_addr and cached the raw peer in r->variables, and realip's
# later rewrite of c->addr_text does NOT invalidate that cache -- so the
# content-phase read returns the stale raw peer. This is the action-at-a-distance
# footgun: any other $remote_addr consumer (logs/headers/maps/limiters) would be
# corrupted the same way. It also serves as the reachability control for (b).
r1="$(get_over_remote "203.0.113.7")"
r2="$(get_over_remote "203.0.113.8")"
a_code="${r1%%|*}"
rem1="${r1##*|}"
rem2="${r2##*|}"
if [ "$a_code" = "200" ] && [ -n "$rem1" ] && [ "$rem1" = "$rem2" ]; then
    pass "(a) content-phase \$remote_addr is the CONSTANT raw peer across XFF variation ($rem1) -> POST_READ key eval poisoned the cache (footgun)"
else
    fail "$(printf '(a) expected 200 + constant poisoned peer, got code=%s peer1=%s peer2=%s' "$a_code" "$rem1" "$rem2")"
fi

# =========================================================================
# (b) flood ONE host varying ONLY the XFF client IP -> verdict flips "" -> "1"
# =========================================================================
# Constant Host + constant real TCP peer, but a DISTINCT XFF IP every request.
# If realip ran before our handler, $remote_addr at POST_READ would be the (per
# request distinct) XFF IP -> each its own burst=0 bucket -> NEVER trips. It
# trips because our POST_READ handler keys on the raw, constant peer BEFORE
# realip rewrites it. Non-vacuous: burst 0 makes the 2nd same-key request flip.
B_N=20
b_saw_over=0
b_last=""
for i in $(seq 1 "$B_N"); do
    res="$(get_over_remote "198.51.100.$i")"
    b_last="$res"
    over="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
    if [ "$over" = "v=1" ]; then
        b_saw_over=1
        break
    fi
done
if [ "$b_saw_over" -eq 1 ]; then
    pass '(b) varied-XFF flood tripped svrealip -> v=1 (POST_READ saw the raw peer, BEFORE realip)'
else
    fail "$(printf '(b) verdict never flipped to v=1 under varied-XFF flood (last=%s) -- would mean realip ran first' "$b_last")"
fi

finish
