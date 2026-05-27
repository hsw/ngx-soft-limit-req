#!/usr/bin/env bash
#
# Case 80: re-entry guard survives internal redirects (accounted exactly ONCE).
#
# The handler must account the leaky bucket exactly once per EXTERNAL request,
# even when PREACCESS re-runs after an internal redirect. The guard is a
# once-per-request marker stored in r->variables (the internal
# __soft_limit_req_seen slot): it SURVIVES the redirect because neither
# ngx_http_internal_redirect() nor ngx_http_named_location() touches
# r->variables, whereas a self-ctx marker would be wiped by the
# ngx_memzero(r->ctx, ...) those functions perform. Case 80 wires the SAME zone
# on BOTH the source location (/redir) AND the redirect target (@redir_named):
# the first pass charges the bucket and sets the marker; the re-entry pass sees
# the marker already set and returns without re-accounting — so the request is
# accounted ONCE across the internal redirect.
#
# Config (see test/conf/nginx.conf):
#   - zone svredir, rate=1r/s, keyed on the X-Redir-Key request header.
#   - location /redir:  soft_limit_req zone=svredir burst=1; does
#       `try_files /no-such-file-$request_id @redir_named;` — the probed path
#       never exists, so try_files falls back to @redir_named via
#       ngx_http_named_location(), a REAL internal redirect (r->internal = 1).
#   - location @redir_named: soft_limit_req zone=svredir burst=1 (SAME zone),
#       proxy_pass http://main, echoes `X-Over-Redir: v=$over_redir`.
#
# Accounting math (burst=1 => 1.000 excess units; back-to-back ms~=0 so the
# leak term is ~0). The leaky-bucket lookup does NOT add to a freshly CREATED
# node — the first request for a key creates the node at excess 0.000 — so we
# measure on the SECOND external request to the same key:
#
#   single-accounting (guard held): req1 creates node @ 0.000; req2 accounts
#     ONCE -> 1.000. `1.000 > 1.000` is FALSE => verdict "" (v=).
#   double-accounting (guard regressed): req1 PASS1 creates node @ 0.000, PASS2
#     accounts -> 1.000; req2 PASS1 -> 2.000, PASS2 -> 3.000. `2.000 > 1.000` is
#     TRUE => verdict "1" (v=1).
#
# So per key we send a warm-up request, then a MEASURED request, and assert the
# measured response reports v= (accounted once per external request) and is 200
# (never 503). If the re-entry guard regresses, the measured response reports
# v=1 instead -> this case FAILS (verified by reverting the guard).
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# --- sanity: the request actually traverses the internal redirect -----------
# A successful response must come from the @redir_named target (proxy_pass to
# the "main" backend, body "served-by-main"). If try_files served a file or
# 404'd instead, the redirect path was not exercised and the test would be
# vacuous — so we assert the served body proves the @named target ran.
body="$(curl -s -H "X-Redir-Key: probe-sanity-$(date +%s%N)-$$" "$BASE_URL/redir")"
if printf '%s' "$body" | grep -q 'served-by-main'; then
    pass '/redir fell through try_files to @redir_named (internal redirect taken)'
else
    fail "$(printf '/redir did not reach @redir_named (body=%q) — redirect not exercised' "$body")"
fi

# helper: GET /redir with a unique key; print "CODE <status> VERDICT <tag>"
# where <tag> is one of:
#   PRESENT_EMPTY  X-Over-Redir present with value "v="  (accounted once)
#   OVER           X-Over-Redir present with value "v=1" (double-counted)
#   MISSING        X-Over-Redir header absent            (target did not run)
# Emitting explicit sentinels (never a bare empty string) keeps the success
# case — an empty verdict "v=" — from being swallowed by a shell default.
probe() {
    local key="$1" out code raw verdict
    out="$(curl -s -D - -o /dev/null -w 'HTTPCODE:%{http_code}\n' \
        -H "X-Redir-Key: $key" "$BASE_URL/redir" | tr -d '\r')"
    code="$(printf '%s\n' "$out" | awk -F: '/^HTTPCODE:/ { print $2 }')"
    # X-Over-Redir absent -> raw is empty -> MISSING; "v=1" -> OVER; "v="/empty
    # value -> PRESENT_EMPTY; anything else -> UNEXPECTED. A present header is
    # never absent because the value always carries the "v=" prefix.
    if printf '%s\n' "$out" | awk 'tolower($1) == "x-over-redir:" { f = 1 } END { exit !f }'; then
        raw="$(printf '%s\n' "$out" | header_field x-over-redir:)"
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

# --- exercise the redirect with many unique keys ----------------------------
# Per key: one warm-up request (creates the bucket node @ 0.000), then a MEASURED
# request whose verdict reveals single- vs double-accounting (see math above).
N=30
n200=0
n503=0
n_other=0
n_over=0      # measured responses that reported v=1 (double-counted -> guard failed)
n_empty=0     # measured responses that reported v= (accounted once -> guard held)
n_missing=0   # measured responses missing the verdict header (target did not run)

# Build a per-run unique key prefix so reruns never collide with a key left
# over in the (process-lifetime) shared zone.
run_tag="$(date +%s%N)-$$"
for i in $(seq 1 "$N"); do
    key="redir-${run_tag}-$i"

    # warm-up: create the bucket node (excess 0.000); ignore its verdict
    probe "$key" >/dev/null

    # measured: the 2nd external request to the same key
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
        *)             n_other=$((n_other + 1)) ;;  # UNEXPECTED:* -> count odd
    esac
done

printf 'measured redirect requests: %s -> %s x200, %s x503, %s other; verdict: %s empty(v=), %s over(v=1), %s missing\n' \
    "$N" "$n200" "$n503" "$n_other" "$n_empty" "$n_over" "$n_missing"

# --- never 503 across the redirect ------------------------------------------
if [ "$n503" -eq 0 ]; then
    pass 'redirect path produced zero 503'
else
    fail "$(printf 'redirect path produced %s x503 (must be zero — never rejects)' "$n503")"
fi

# --- every redirected response served 200 -----------------------------------
if [ "$n200" -eq "$N" ]; then
    pass "$(printf 'every redirected response was 200 (%s/%s)' "$n200" "$N")"
else
    fail "$(printf 'not all redirected responses were 200 (%s/%s)' "$n200" "$N")"
fi

# --- the verdict header must be present (target actually ran) ----------------
if [ "$n_missing" -eq 0 ]; then
    pass 'every served response carried the verdict header (target ran)'
else
    fail "$(printf '%s served responses missing the verdict header' "$n_missing")"
fi

# --- THE KEY ASSERTION: accounted exactly once across the redirect -----------
# Under single-accounting every fresh-key request stays UNDER budget -> v=.
# If the re-entry guard regresses, the redirect pass double-accounts and these
# would all be v=1 -> this assertion fails. This is what makes the case depend
# on the fix (non-vacuous).
if [ "$n_over" -ne 0 ]; then
    fail "$(printf '%s/%s redirected requests reported v=1 — DOUBLE-COUNTED across the internal redirect (re-entry guard ineffective)' \
        "$n_over" "$N")"
elif [ "$n_empty" -eq "$N" ]; then
    pass "$(printf 'all %s redirected requests reported v= — accounted EXACTLY ONCE across the internal redirect' \
        "$N")"
else
    fail "$(printf 'expected all %s redirected requests to report v= (got %s empty, %s over, %s missing)' \
        "$N" "$n_empty" "$n_over" "$n_missing")"
fi

finish
