#!/usr/bin/env bash
#
# Case 95: GROUND TRUTH — soft_limit_req_server (POST_READ) runs BEFORE the
# built-in ngx_http_realip_module's POST_READ handler, so a $remote_addr-keyed
# server zone sees the RAW TCP peer at POST_READ, not the realip-rewritten
# client IP.
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
# (a) the vhost is reachable and the real TCP peer is CONSTANT across requests
# =========================================================================
# Reachability control for (b): a varied-XFF request returns a real proxied 200.
# X-Remote surfaces $remote_addr in the content phase; we only require that two
# requests carrying DIFFERENT XFF IPs report the SAME $remote_addr (the constant
# docker bridge peer). That constancy is the whole premise of (b): because the
# real peer never changes, the ONLY way svrealip could bucket distinctly per XFF
# is if realip had rewritten $remote_addr before our POST_READ handler ran. (b)
# shows it does not.
r1="$(get_over_remote "203.0.113.7")"
r2="$(get_over_remote "203.0.113.8")"
a_code="${r1%%|*}"
rem1="${r1##*|}"
rem2="${r2##*|}"
if [ "$a_code" = "200" ] && [ -n "$rem1" ] && [ "$rem1" = "$rem2" ]; then
    pass "(a) vhost reachable (200), real TCP peer constant across XFF variation ($rem1)"
else
    fail "$(printf '(a) expected 200 + constant peer, got code=%s peer1=%s peer2=%s' "$a_code" "$rem1" "$rem2")"
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
