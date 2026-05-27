#!/usr/bin/env bash
#
# Case 20: tag-don't-reject — the handler NEVER rejects on overflow, and the
# never-reject guarantee is tied to the handler ACTUALLY RUNNING and tagging.
#
# The test config attaches `soft_limit_req zone=svhost burst=10 set=$over_host`
# (rate=1r/s, keyed on $host) to /soft and echoes the verdict as
# `X-Over: v=$over_host`. This case floods /soft far over rate with a single
# $host and asserts that (a) EVERY response is 200 with ZERO 503s AND (b) the
# verdict flips to "1" (v=1) during the flood — proving the handler ran and
# tagged the over-budget request while still serving it. (Without the set= tag
# the all-200 assertion would hold even if the handler never ran, since
# try_files serves the static file regardless.)
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# --- flood: many requests far over rate, single $host ----------------------
# rate=1r/s, burst=10 => bucket overruns within the first ~11 requests; we send
# 200 back-to-back so the vast majority are "over". All must still be 200, and
# the verdict header must flip to "v=1" at least once.
FLOOD_N=200
codes_file="$(mktemp)"
over_file="$(mktemp)"
trap 'rm -f "$codes_file" "$over_file"' EXIT

for _ in $(seq 1 "$FLOOD_N"); do
    # capture both the status and the X-Over verdict header in one request
    out="$(curl -s -D - -o /dev/null -w 'HTTPCODE:%{http_code}\n' \
        -H 'Host: flood.example' "$BASE_URL/soft" | tr -d '\r')"
    printf '%s\n' "$out" | awk -F: '/^HTTPCODE:/ { print $2 }' >> "$codes_file"
    printf '%s\n' "$out" | header_field x-over: >> "$over_file"
done

total="$(wc -l < "$codes_file" | tr -d ' ')"
n200="$(grep -c '^200$' "$codes_file" || true)"
n503="$(grep -c '^503$' "$codes_file" || true)"
other="$((total - n200 - n503))"
n_over="$(grep -c '^v=1$' "$over_file" || true)"

printf 'flood: %s requests -> %s x200, %s x503, %s other; %s tagged v=1\n' \
    "$total" "$n200" "$n503" "$other" "$n_over"

if [ "$total" -ne "$FLOOD_N" ]; then
    fail "$(printf 'flood: sent %s but recorded %s responses' "$FLOOD_N" "$total")"
fi

if [ "$n503" -ne 0 ]; then
    fail "$(printf 'flood produced %s x503 (must be zero — never rejects)' "$n503")"
else
    pass "flood over rate produced zero 503"
fi

if [ "$n200" -eq "$total" ] && [ "$total" -gt 0 ]; then
    pass "$(printf 'every flooded response was 200 (%s/%s)' "$n200" "$total")"
else
    fail "$(printf 'not all flooded responses were 200 (%s/%s)' "$n200" "$total")"
fi

# the handler must have actually run and tagged the over-budget requests "1"
if [ "$n_over" -gt 0 ]; then
    pass "$(printf 'handler ran and tagged %s flooded responses v=1 (never-reject is real)' "$n_over")"
else
    fail "no flooded response was tagged v=1 — handler may not be running"
fi

# --- under-budget: a single request to /soft is 200 ------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: calm.example' "$BASE_URL/soft" || echo 000)"
if [ "$code" = "200" ]; then
    pass "under-budget /soft -> 200"
else
    fail "$(printf 'under-budget /soft -> %s (expected 200)' "$code")"
fi

# --- baseline: plain / (no soft_limit_req) still 200 -----------------------
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/" || echo 000)"
if [ "$code" = "200" ]; then
    pass "baseline / -> 200"
else
    fail "$(printf 'baseline / -> %s (expected 200)' "$code")"
fi

finish
