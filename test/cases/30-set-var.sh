#!/usr/bin/env bash
#
# Case 30: set=$var — the per-directive overflow verdict is exported as a
# variable and echoed in a response header (X-Over).
#
# The /setvar location attaches `soft_limit_req zone=perhost burst=10
# set=$over_host` (rate=5r/s, keyed on $host) and `add_header X-Over $over_host`.
# This case:
#   1. floods /setvar over budget with a single $host -> X-Over flips ""->"1"
#   2. lets a DIFFERENT (fresh) $host hit /setvar once -> X-Over is "" (empty)
#      (under budget reads not-over)
#
# Note: the verdict saturates per-key, so once a host is flooded its bucket
# stays over for a while; the under-budget assertion uses a distinct, unflooded
# host to prove the un-flooded path reads "".
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# helper: print the X-Over verdict for a single GET /setvar with the given Host.
# The header is emitted as "X-Over: v=$over_host" so an EMPTY verdict yields the
# literal "v=" (header present) — distinguishable from an absent header (nginx
# drops empty-value headers). This strips the "v=" prefix and prints the verdict
# ("" for empty, "1" for over).
over_header() {
    local host="$1"
    curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL/setvar" \
        | header_field x-over: | sed 's/^v=//'
}

# helper: assert the X-Over header is PRESENT with an empty verdict (literal
# "v=") for a fresh host — proves present-but-empty, not header-absent.
assert_present_empty() {
    local host="$1" desc="$2" raw
    raw="$(curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL/setvar" \
        | header_field x-over:)"
    if [ "$raw" = "v=" ]; then
        pass "$(printf '%s X-Over present and empty (raw "%s")' "$desc" "$raw")"
    else
        fail "$(printf '%s X-Over expected literal "v=", got "%s"' "$desc" "$raw")"
    fi
}

# --- under budget: a fresh host's first request reads present-but-empty -----
assert_present_empty calm-setvar.example "under-budget /setvar"

# --- flood: push one host far over budget -----------------------------------
# /setvar uses zone=svhost (rate=1r/s, burst=10) => overruns within ~11 requests.
FLOOD_N=60
saw_over=0
last=""
for _ in $(seq 1 "$FLOOD_N"); do
    last="$(over_header flood-setvar.example)"
    if [ "$last" = "1" ]; then
        saw_over=1
    fi
done

if [ "$saw_over" -eq 1 ]; then
    pass 'flood /setvar flipped X-Over to "1"'
else
    fail "$(printf 'flood /setvar never produced X-Over "1" (last="%s")' "$last")"
fi

# NOTE: we deliberately do NOT assert the TRAILING request is still "1". At
# rate=1r/s the leaky bucket can drain back under burst between the over-budget
# peak and the last (slow curl -D -) request, which is runner-timing-dependent.
# "saw_over" above already proves the verdict flips under flood (the meaningful
# property), so a trailing-value check would only add flakiness.

# --- a never-flooded host still reads present-but-empty while another over --
assert_present_empty pristine-setvar.example \
    "independent fresh host (while another is over)"

finish
