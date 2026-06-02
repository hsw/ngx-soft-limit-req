#!/usr/bin/env bash
#
# Case 91: soft_limit_req_server accounts EXACTLY ONCE per external request across
# every internal-redirect vector — the headline correctness guarantee of the
# marker-less POST_READ handler.
#
# The new server-scope directive runs in POST_READ, which executes once per
# EXTERNAL request. Internal redirects re-enter the phase engine at/after
# SERVER_REWRITE (which is AFTER POST_READ in the phase order), so the POST_READ
# handler is NOT re-run on the redirect and the bucket is charged once — WITHOUT
# the 70-line once-per-request marker the PREACCESS path needs. This case proves
# that invariant for all three internal-redirect vectors:
#
#   /tf  -> try_files $uri @once_named   (ngx_http_named_location)
#   /ep  -> return 418 + error_page 418 = @once_named  (ngx_http_internal_redirect)
#   /rw  -> rewrite ^ /once-target last; (ngx_http_core_post_rewrite_phase)
#
# All three are served by the *.once.example vhost which attaches
#   soft_limit_req_server zone=svonce burst=1 set=$over_once;   # $host-keyed
# and echoes the verdict $over_once on the FINAL (post-redirect) response.
#
# Accounting math (burst=1 => 1.000 excess units; back-to-back ms ~ 0 so the leak
# term is ~0; svonce is keyed on $host so a vector's two requests share one node):
#
#   single-charge (POST_READ ran once): req1 (warm-up) creates node @ 0.000;
#     req2 (measured) charges ONCE -> 1.000. `1.000 > 1.000` is FALSE => verdict
#     "" (v=).
#   double-charge (POST_READ re-ran on the redirect): req1 PASS1 @ 0.000, PASS2
#     -> 1.000; req2 PASS1 -> 2.000, PASS2 -> 3.000. `2.000 > 1.000` is TRUE =>
#     verdict "1" (v=1).
#
# So per vector we send a warm-up request, then a MEASURED request, and assert the
# measured response reports v= (charged once across the redirect) and is 200
# (never rejects). A double-charge on re-entry would report v=1 -> this case FAILS.
# A DISTINCT $host per vector keeps the three buckets independent, and a fresh
# $host per RUN (timestamp+pid) keeps reruns from colliding in the process-lifetime
# shared zone.
#
# NON-VACUOUS: a sanity probe first proves each request actually traverses its
# redirect (body "served-by-main" from the target proxy_pass + the X-Over-Once
# verdict header that only the redirect target adds). If a vector did not redirect,
# the sanity check fails rather than the test passing trivially.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

run_tag="$(date +%s%N)-$$"

# probe <path> <host>: GET $path with the given Host (varied client IP so any
# hypothetical per-IP limiter stays clear), print "CODE <status> VERDICT <tag>".
#   PRESENT_EMPTY  X-Over-Once "v="  (charged once across the redirect)
#   OVER           X-Over-Once "v=1" (DOUBLE-charged on re-entry)
#   MISSING        header absent     (redirect target did not run)
probe() {
    local path="$1" host="$2" out code raw verdict
    out="$(curl -s -D - -o /dev/null -w 'HTTPCODE:%{http_code}\n' \
        -H "Host: $host" -H "X-Forwarded-For: 198.51.100.$((RANDOM % 254 + 1))" \
        "$BASE_URL$path" | tr -d '\r')"
    code="$(printf '%s\n' "$out" | awk -F: '/^HTTPCODE:/ { print $2 }')"
    if printf '%s\n' "$out" | awk 'tolower($1) == "x-over-once:" { f = 1 } END { exit !f }'; then
        raw="$(printf '%s\n' "$out" | header_field x-over-once:)"
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

# check_vector <label> <path>: prove the redirect is taken, then assert single-
# charge across it. Uses a $host unique to this vector AND this run so the bucket
# is pristine. Returns nonzero sub-checks via the shared fail() counter.
check_vector() {
    local label="$1" path="$2"
    local host="${label}-${run_tag}.once.example"

    # --- sanity: the request actually traverses the internal redirect --------
    # The served body must come from the redirect TARGET (proxy_pass to "main",
    # body "served-by-main") AND carry the X-Over-Once verdict header that ONLY
    # the redirect target adds. If the vector did not redirect, this fails rather
    # than letting the single-charge assertion pass vacuously.
    local sbody sdump
    sbody="$(curl -s -H "Host: sanity-$host" \
        -H "X-Forwarded-For: 198.51.100.7" "$BASE_URL$path")"
    if printf '%s' "$sbody" | grep -q 'served-by-main'; then
        pass "$(printf '[%s] %s reached the redirect target (internal redirect taken)' "$label" "$path")"
    else
        fail "$(printf '[%s] %s did not reach the redirect target (body=%q) — redirect not exercised' "$label" "$path" "$sbody")"
    fi
    sdump="$(curl -s -D - -o /dev/null -H "Host: sanity-$host" \
        -H "X-Forwarded-For: 198.51.100.7" "$BASE_URL$path" | tr -d '\r')"
    if printf '%s\n' "$sdump" | awk 'tolower($1) == "x-over-once:" { f = 1 } END { exit !f }'; then
        pass "$(printf '[%s] verdict header present on the served response (target ran)' "$label")"
    else
        fail "$(printf '[%s] verdict header absent — the redirect target did not run' "$label")"
    fi

    # --- warm-up: create the bucket node @ 0.000 (ignore its verdict) --------
    probe "$path" "$host" >/dev/null

    # --- measured: the 2nd external request to the same $host ----------------
    local res code verdict
    res="$(probe "$path" "$host")"
    code="$(printf '%s' "$res" | awk '{ print $2 }')"
    verdict="$(printf '%s' "$res" | awk '{ print $4 }')"

    printf '[%s] measured request: code=%s verdict=%s\n' "$label" "$code" "$verdict"

    # never rejects (tag-don't-reject; the redirect target proxies 200)
    if [ "$code" = "200" ]; then
        pass "$(printf '[%s] measured response was 200 (never rejects)' "$label")"
    else
        fail "$(printf '[%s] measured response was %s (expected 200)' "$label" "$code")"
    fi

    # THE KEY ASSERTION: charged EXACTLY ONCE across the redirect.
    # Single-charge -> excess 1.000, `1.000 > 1.000` false -> v=. A double-charge
    # on re-entry -> excess 2.000 > 1.000 -> v=1 -> this FAILS. That is what makes
    # the case depend on the marker-less POST_READ-runs-once invariant (non-vacuous).
    case "$verdict" in
        PRESENT_EMPTY)
            pass "$(printf '[%s] verdict v= — POST_READ charged EXACTLY ONCE across the %s redirect' "$label" "$label")"
            ;;
        OVER)
            fail "$(printf '[%s] verdict v=1 — POST_READ DOUBLE-CHARGED on re-entry across the %s redirect (marker-less handler re-ran)' "$label" "$label")"
            ;;
        MISSING)
            fail "$(printf '[%s] verdict header missing on the measured response — redirect target did not run' "$label")"
            ;;
        *)
            fail "$(printf '[%s] unexpected verdict %q on the measured response' "$label" "$verdict")"
            ;;
    esac
}

# Exercise every internal-redirect re-entry vector.
check_vector "tf" "/tf"   # try_files -> @named
check_vector "ep" "/ep"   # error_page -> @named
check_vector "rw" "/rw"   # rewrite ... last -> = /once-target

finish
