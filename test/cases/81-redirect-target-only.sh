#!/usr/bin/env bash
#
# Case 81: soft_limit_req on a REDIRECT-TARGET-ONLY location is still accounted.
#
# The common pattern is an entry location with NO limiter that falls through
# try_files to a @named location that HAS the limiter:
#
#     location /apponly { try_files /no-such-file-$request_id @app_only; }
#     location @app_only { soft_limit_req zone=svapponly burst=2 set=$over_app;
#                          proxy_pass http://main; }
#
# Because the probed file never exists, try_files always falls back to
# @app_only via ngx_http_named_location() — a genuine internal redirect that
# sets r->internal = 1. The limiter therefore ONLY ever runs on an internal
# pass.
#
# A guard that gates accounting on r->internal would SKIP this pass entirely,
# so the bucket is never accounted and the verdict $over_app stays "" no matter
# how hard the client floods. The redirect-surviving marker accounts the request
# once (on its first/only PREACCESS pass) regardless of r->internal, so a flood
# correctly flips $over_app to "1".
#
# This case is NON-VACUOUS: on the old r->internal code it FAILS (verdict never
# flips to v=1); after the marker fix it PASSES (verdict flips under flood).
#
# Asserts:
#   (a) the redirect target actually ran (served-by-main body + verdict header)
#   (b) every response is 200 (never 503 — tag-don't-reject)
#   (c) under a flood of ONE key, the verdict flips to v=1 (limiter RAN)
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# --- sanity: the request actually traverses the internal redirect -----------
# A successful response must come from the @app_only target (proxy_pass to the
# "main" backend, body "served-by-main") AND carry the X-Over-App verdict header
# (added only by @app_only). If try_files served a file or 404'd, the redirect
# target never ran and the test would be vacuous.
sanity_key="apponly-sanity-$(date +%s%N)-$$"
sanity="$(curl -s -D - -H "X-Apponly-Key: $sanity_key" "$BASE_URL/apponly" | tr -d '\r')"
if printf '%s' "$sanity" | grep -q 'served-by-main'; then
    pass '/apponly fell through try_files to @app_only (internal redirect taken)'
else
    fail "$(printf '/apponly did not reach @app_only (resp=%q) — redirect not exercised' "$sanity")"
fi
if printf '%s\n' "$sanity" | awk 'tolower($1) == "x-over-app:" { f = 1 } END { exit !f }'; then
    pass '@app_only verdict header present (the limited location ran)'
else
    fail '@app_only verdict header absent — the soft-limited target did not run'
fi

# helper: GET /apponly with a key; print "CODE <status> VERDICT <tag>"
#   PRESENT_EMPTY  X-Over-App "v="  (under budget / NOT accounted)
#   OVER           X-Over-App "v=1" (over budget -> limiter ran and accounted)
#   MISSING        header absent    (target did not run)
probe() {
    local key="$1" out code raw verdict
    out="$(curl -s -D - -o /dev/null -w 'HTTPCODE:%{http_code}\n' \
        -H "X-Apponly-Key: $key" "$BASE_URL/apponly" | tr -d '\r')"
    code="$(printf '%s\n' "$out" | awk -F: '/^HTTPCODE:/ { print $2 }')"
    if printf '%s\n' "$out" | awk 'tolower($1) == "x-over-app:" { f = 1 } END { exit !f }'; then
        raw="$(printf '%s\n' "$out" | header_field x-over-app:)"
        case "$raw" in
            v=1)    verdict="OVER" ;;
            v=|"")  verdict="PRESENT_EMPTY" ;;
            *)      verdict="UNEXPECTED:$raw" ;;
        esac
    else
        verdict="MISSING"
    fi
    printf 'CODE %s VERDICT %s\n' "${code:-000}" "${verdict:-MISSING}"
}

# --- flood ONE key and watch the verdict flip -------------------------------
# rate=1r/s, burst=2 (== 2.000 excess units). A back-to-back flood (ms ~ 0 so the
# leak term is ~0) pushes excess +1.000 per accounted request: req1 creates the
# node @ 0.000, req2 -> 1.000, req3 -> 2.000, req4 -> 3.000 > 2.000 => OVER. So
# within a handful of requests the verdict must flip to v=1 — IF the limiter ran.
N=20
n200=0
n503=0
n_other=0
n_over=0      # responses that reported v=1 (limiter ran and accounted)
n_empty=0     # responses that reported v= (under budget or not accounted)
n_missing=0   # responses missing the verdict header (target did not run)

key="apponly-flood-$(date +%s%N)-$$"
for i in $(seq 1 "$N"); do
    res="$(probe "$key")"
    code="$(printf '%s' "$res" | awk '{ print $2 }')"
    verdict="$(printf '%s' "$res" | awk '{ print $4 }')"

    case "$code" in
        200) n200=$((n200 + 1)) ;;
        503) n503=$((n503 + 1)) ;;
        *)   n_other=$((n_other + 1)) ;;
    esac

    case "$verdict" in
        PRESENT_EMPTY) n_empty=$((n_empty + 1)) ;;
        OVER)          n_over=$((n_over + 1)) ;;
        MISSING)       n_missing=$((n_missing + 1)) ;;
        *)             n_other=$((n_other + 1)) ;;
    esac
done

printf 'flooded redirect-target-only key: %s reqs -> %s x200, %s x503, %s other; verdict: %s empty(v=), %s over(v=1), %s missing\n' \
    "$N" "$n200" "$n503" "$n_other" "$n_empty" "$n_over" "$n_missing"

# --- never 503 --------------------------------------------------------------
if [ "$n503" -eq 0 ]; then
    pass 'redirect-target-only flood produced zero 503'
else
    fail "$(printf 'redirect-target-only flood produced %s x503 (must be zero)' "$n503")"
fi

# --- every response 200 -----------------------------------------------------
if [ "$n200" -eq "$N" ]; then
    pass "$(printf 'every response was 200 (%s/%s)' "$n200" "$N")"
else
    fail "$(printf 'not all responses were 200 (%s/%s)' "$n200" "$N")"
fi

# --- the verdict header was always present (target always ran) --------------
if [ "$n_missing" -eq 0 ]; then
    pass 'every response carried the verdict header (target ran every time)'
else
    fail "$(printf '%s responses missing the verdict header' "$n_missing")"
fi

# --- THE KEY ASSERTION: the limiter RAN for the redirect-target-only location.
# Under the marker fix the bucket is accounted, so a flood of one key flips the
# verdict to v=1. On the old r->internal guard the limiter is skipped (the pass
# is always internal), the bucket is never accounted, and the verdict stays v=
# forever -> n_over == 0 -> this assertion FAILS. That is what makes the case
# depend on the fix (non-vacuous).
if [ "$n_over" -gt 0 ]; then
    pass "$(printf 'verdict flipped to v=1 on %s/%s requests — limiter RAN for the redirect-target-only location' \
        "$n_over" "$N")"
else
    fail 'verdict NEVER flipped to v=1 — the soft-limited redirect-target-only location was never accounted (r->internal guard would skip it)'
fi

finish
