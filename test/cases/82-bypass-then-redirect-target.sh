#!/usr/bin/env bash
#
# Case 82: an all-bypass ENTRY location must NOT burn the once-per-request
# accounting budget, so a redirect-target limiter still accounts.
#
# The entry location has a CONFIGURED soft_limit_req (Zentry) keyed on the
# X-Bypass-Key request header. The flood below sends NO such header, so the key
# is empty (key.len == 0, the verified-bypass path) and the entry zone is
# skipped WITHOUT touching any bucket. try_files then forces an internal
# redirect to @redir_target, which owns a REAL limiter (Zreal, keyed on $host,
# burst=2).
#
# Config (see test/conf/nginx.conf):
#   location /bypassentry {
#       soft_limit_req zone=Zentry burst=5 set=$o_entry;   # keyed on absent hdr
#       try_files /no-such-file-$request_id @redir_target;
#   }
#   location @redir_target {
#       soft_limit_req zone=Zreal burst=2 set=$o_target;   # keyed on $host
#       proxy_pass http://main; add_header X-Over-Target "v=$o_target";
#   }
#
# THE REGRESSION this guards: if the handler sets the seen-marker as soon as the
# entry location has limits (limits.nelts > 0) BEFORE any key is processed, the
# all-bypass entry pass burns the once-per-request budget. The redirect to
# @redir_target then sees the marker set and SKIPS the real limiter, so
# $o_target never flips -> n_over == 0 -> this case FAILS. The fix consumes the
# marker only after a zone actually reaches lookup() (a real, non-empty key), so
# the entry bypass leaves the budget and @redir_target accounts -> $o_target
# flips to "1" under a flood.
#
# NON-VACUOUS: verified to FAIL on a marker-set-too-early build (n_over == 0,
# verdict never flips) and PASS on the fixed build.
#
# Asserts:
#   (a) the redirect target actually ran (served-by-main + verdict header)
#   (b) the entry zone genuinely bypassed (X-Over-Entry present but empty "v=")
#   (c) every response is 200 (never 503 — tag-don't-reject)
#   (d) under a flood the @redir_target verdict flips to v=1 (limiter accounted)
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# --- sanity: the request bypasses the entry zone AND reaches the target ------
# The response must come from @redir_target (body "served-by-main") and carry
# BOTH the entry verdict (X-Over-Entry, must be empty "v=" since the key was
# absent) and the target verdict (X-Over-Target). NO X-Bypass-Key is sent.
sanity="$(curl -s -D - "$BASE_URL/bypassentry" | tr -d '\r')"
if printf '%s' "$sanity" | grep -q 'served-by-main'; then
    pass '/bypassentry fell through try_files to @redir_target (internal redirect taken)'
else
    fail "$(printf '/bypassentry did not reach @redir_target (resp=%q) — redirect not exercised' "$sanity")"
fi
if printf '%s\n' "$sanity" | awk 'tolower($1) == "x-over-target:" { f = 1 } END { exit !f }'; then
    pass '@redir_target verdict header present (the limited target ran)'
else
    fail '@redir_target verdict header absent — the soft-limited redirect target did not run'
fi
entry_verdict="$(printf '%s\n' "$sanity" | header_field x-over-entry:)"
if [ "$entry_verdict" = "v=" ] || [ -z "$entry_verdict" ]; then
    pass "$(printf 'entry zone bypassed (X-Over-Entry empty: %q) — absent X-Bypass-Key gave an empty key' "$entry_verdict")"
else
    fail "$(printf 'entry zone did NOT bypass (X-Over-Entry=%q) — expected empty, the entry key was not empty' "$entry_verdict")"
fi

# helper: GET /bypassentry WITHOUT X-Bypass-Key; print "CODE <status> VERDICT <tag>"
# VERDICT reads the @redir_target verdict header (X-Over-Target):
#   PRESENT_EMPTY  v=   (under budget / NOT accounted)
#   OVER           v=1  (over budget -> target limiter ran and accounted)
#   MISSING        header absent (target did not run)
probe() {
    local out code raw verdict
    out="$(curl -s -D - -o /dev/null -w 'HTTPCODE:%{http_code}\n' \
        "$BASE_URL/bypassentry" | tr -d '\r')"
    code="$(printf '%s\n' "$out" | awk -F: '/^HTTPCODE:/ { print $2 }')"
    if printf '%s\n' "$out" | awk 'tolower($1) == "x-over-target:" { f = 1 } END { exit !f }'; then
        raw="$(printf '%s\n' "$out" | header_field x-over-target:)"
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

# --- flood (no X-Bypass-Key) and watch the @redir_target verdict flip --------
# Zreal is keyed on $host, so every request shares ONE bucket. rate=1r/s,
# burst=2 (== 2.000 excess units). Back-to-back (ms ~ 0) each accounted request
# adds +1.000: req1 creates node @0.000, req2 -> 1.000, req3 -> 2.000, req4 ->
# 3.000 > 2.000 => OVER. The target accounts ONLY if the entry bypass left the
# once-per-request budget intact.
N=20
n200=0
n503=0
n_other=0
n_over=0      # responses where @redir_target reported v=1 (it accounted)
n_empty=0     # responses where @redir_target reported v= (under budget / skipped)
n_missing=0   # responses missing the target verdict header

for i in $(seq 1 "$N"); do
    res="$(probe)"
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

printf 'flooded /bypassentry (no X-Bypass-Key): %s reqs -> %s x200, %s x503, %s other; target verdict: %s empty(v=), %s over(v=1), %s missing\n' \
    "$N" "$n200" "$n503" "$n_other" "$n_empty" "$n_over" "$n_missing"

# --- never 503 --------------------------------------------------------------
if [ "$n503" -eq 0 ]; then
    pass 'bypass-then-redirect flood produced zero 503'
else
    fail "$(printf 'bypass-then-redirect flood produced %s x503 (must be zero)' "$n503")"
fi

# --- every response 200 -----------------------------------------------------
if [ "$n200" -eq "$N" ]; then
    pass "$(printf 'every response was 200 (%s/%s)' "$n200" "$N")"
else
    fail "$(printf 'not all responses were 200 (%s/%s)' "$n200" "$N")"
fi

# --- the target verdict header was always present (target always ran) -------
if [ "$n_missing" -eq 0 ]; then
    pass 'every response carried the @redir_target verdict header (target ran every time)'
else
    fail "$(printf '%s responses missing the @redir_target verdict header' "$n_missing")"
fi

# --- THE KEY ASSERTION: the redirect-target limiter accounted ----------------
# The entry location's configured-but-bypassed soft limit must NOT consume the
# once-per-request budget. With the fix @redir_target accounts and the verdict
# flips to v=1 under flood. On the marker-too-early code the entry bypass burns
# the budget, @redir_target is skipped, the bucket never fills, and the verdict
# stays v= forever -> n_over == 0 -> this FAILS. That is what makes the case
# depend on the fix (non-vacuous).
if [ "$n_over" -gt 0 ]; then
    pass "$(printf 'redirect-target verdict flipped to v=1 on %s/%s requests — @redir_target accounted even though the entry soft limit bypassed' \
        "$n_over" "$N")"
else
    fail 'redirect-target verdict NEVER flipped to v=1 — the all-bypass entry location burned the once-per-request budget and the redirect-target limiter was skipped'
fi

finish
