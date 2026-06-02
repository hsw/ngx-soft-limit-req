#!/usr/bin/env bash
#
# Case 90: HEADLINE — soft_limit_req_server verdict is visible in the REWRITE
# phase. The positive inverse of case 40 (d).
#
# The *.rewrite.example virtual host attaches the new server-scope directive:
#   soft_limit_req_server zone=svrewrite burst=10 set=$over_host;   # POST_READ
# and its location body consumes the verdict in the REWRITE phase:
#   if ($over_host) { return 444; }
#
# soft_limit_req_server runs in POST_READ — BEFORE the REWRITE phase — so by the
# time the `if` is evaluated, $over_host is already populated. In case 40 (d) the
# location-level soft_limit_req runs in PREACCESS (AFTER rewrite), so the same
# `if` always reads empty and 444 never fires. Here we assert the opposite: once
# the host is over budget the `if` FIRES -> 444.
#
# Sub-cases:
#   (a) flood a SINGLE $host (vary the client IP via X-Forwarded-For so any
#       per-IP limiter would stay clear; the zone is $host-keyed so only the
#       host matters) -> assert the `if` FIRES -> 444 once over budget.
#   (b) confirming sub-assertion: a FRESH host with a SINGLE request returns the
#       normal proxied 200 (NOT 444) with X-Over-Srv "v=" — proving the verdict
#       is "" when under budget. Because the same key produces "1" when flooded
#       (a) and "" when fresh (b), the $host key actually RESOLVED and was
#       ACCOUNTED in POST_READ (verdict flips ""->"1"), not merely that `if`
#       happened to fire.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# Per-run unique host suffix so a case-level rerun against a long-lived container
# (the process-lifetime shared zones persist for the whole run.sh invocation) does
# not read a bucket that an earlier run already pushed over budget. Matches the
# run_tag idiom in cases 91/92.
run_tag="$(date +%s%N)-$$"

# helper: GET / with a given Host and X-Forwarded-For (client IP), print
# "<http_code>|<X-Over-Srv>".
#
# `return 444` closes the connection WITHOUT sending any response, so there is
# no status line and no headers: curl reports http_code 000 and exits with the
# SPECIFIC code 52 ("empty reply from server"). We normalise ONLY that exact
# signature to the synthetic code "444" so the assertions detect the fired `if`
# positively — we deliberately do NOT treat any other nonzero curl rc (connect
# refused 7, reset 56, timeout 28, …) as 444, so a pure connectivity failure
# cannot masquerade as the rewrite-phase trip and false-pass sub-case (a). A real
# HTTP response (e.g. proxied 200) yields its actual status line + X-Over-Srv.
get_code_over() {
    local host="$1" xff="$2" dump code over rc
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: $host" -H "X-Forwarded-For: $xff" "$BASE_URL/" 2>/dev/null | tr -d '\r')"
    rc=$?
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-srv:)"
    # No status line + curl rc EXACTLY 52 (CURLE_GOT_NOTHING, "empty reply from
    # server") => connection closed with no response, which is precisely what
    # `return 444` produces. Any other rc is left as-is (not 444).
    if [ -z "$code" ] && [ "$rc" -eq 52 ]; then
        code="444"
    fi
    printf '%s|%s\n' "$code" "$over"
}

# =========================================================================
# (b) FRESH host, single request, BEFORE any flood -> 200, verdict "v=" (under)
# =========================================================================
# Do this first so the budget is pristine: under budget the POST_READ handler
# resolved the $host key and accounted it, but excess <= burst so $over_host=""
# -> the `if` does not fire -> proxied 200 with X-Over-Srv "v=".
res="$(get_code_over "fresh1-${run_tag}.rewrite.example" "192.0.2.50")"
b_code="${res%%|*}"
b_over="${res##*|}"
if [ "$b_code" = "200" ] && [ "$b_over" = "v=" ]; then
    pass '(b) under-budget host: 200 proxied, verdict "v=" (if did not fire)'
else
    fail "$(printf '(b) expected 200/v=, got %s/%s' "$b_code" "$b_over")"
fi

# =========================================================================
# (a) flood a SINGLE host across MANY client IPs -> `if` FIRES -> 444
# =========================================================================
# Constant Host (so svrewrite accumulates and goes over), varied client IP each
# request (so the assertion cannot be attributed to any per-IP limiter — the
# zone is $host-keyed). svrewrite is rate=1r/s burst=10; a slow header-dumping
# curl loop overruns it well within the bound below.
#
# Sub-case (b) above already proved the vhost is REACHABLE and returns a real
# 200/v= (verdict empty under budget) — so a synthetic "444" from a pure
# connectivity failure cannot account for the trip here; the only way to flip
# from that proven-reachable 200 to a 444 is the rewrite-phase `if` firing.
A_HOST="flood-${run_tag}.rewrite.example"
A_N=40
a_saw_444=0
a_code=""
for i in $(seq 1 "$A_N"); do
    res="$(get_code_over "$A_HOST" "198.51.100.$i")"
    a_code="${res%%|*}"
    [ "$a_code" = "444" ] && { a_saw_444=1; break; }
done
if [ "$a_saw_444" -eq 1 ]; then
    pass '(a) over-budget host: `if ($over_host)` FIRED -> 444 (verdict visible in REWRITE)'
else
    fail "$(printf '(a) `if` never fired 444 under flood (last code=%s)' "$a_code")"
fi

finish
