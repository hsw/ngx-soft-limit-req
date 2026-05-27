#!/usr/bin/env bash
#
# Case 70: zone-full / alloc-failure graceful degradation (Task F3).
#
# The /zonefull location attaches `soft_limit_req zone=svfull burst=10
# set=$over_full` where svfull is a MINIMUM-size zone (32k = 8*pagesize, the
# parser floor) keyed on the high-cardinality X-Full-Key request header.
#
# Goal: exercise the NGX_ERROR branch in *_lookup (slab allocation failure ->
# the handler does NOT tag, verdict stays "", request is STILL served, never a
# 5xx) AND PROVE it actually executed — not merely that a flood degraded
# gracefully.
#
# Why two phases. *_expire is stock-faithful: expire(ctx,1) (run BEFORE the
# alloc) only frees nodes that are BOTH >=60s old AND drained, so during a short
# flood it frees NOTHING; on alloc failure expire(ctx,0) force-frees exactly ONE
# (the oldest) node and the alloc is retried once. With UNIFORM small keys,
# force-freeing one small node always makes room for the next small node, so the
# zone settles into 1-in-1-out eviction and NGX_ERROR is essentially never hit
# (this is why a uniform-key flood proves graceful behavior but NOT the
# allocation-failure path). To force a real NGX_ERROR:
#   Phase A — flood many SMALL distinct keys, packing every slab page full of
#             small nodes so no free pages remain.
#   Phase B — send LARGE distinct keys (~6000 bytes => a 2-page slab alloc).
#             expire(0) can free at most one small node (<= one page) and the
#             slab needs two CONTIGUOUS pages, so the allocation cannot be
#             satisfied -> *_lookup returns NGX_ERROR -> "could not allocate
#             node" alert -> verdict stays "".
#
# Asserts: (a) no 5xx in either phase (served regardless), (b) the verdict stays
# present-but-empty ("v=") on the degraded path, and (c) the slab-exhaustion
# alert count in the error log strictly INCREASED across the run — direct proof
# the NGX_ERROR branch ran.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"
: "${CONTAINER:?CONTAINER must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# helper: GET /zonefull with a distinct X-Full-Key; print "<code>|<X-Over-Full>".
# X-Over-Full is emitted as "v=$over_full" so present-but-empty ("v=") is
# distinguishable from an absent header.
probe() {
    local key="$1" dump code over
    dump="$(curl -s -D - -o /dev/null -H "X-Full-Key: $key" "$BASE_URL/zonefull")"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-full:)"
    printf '%s|%s\n' "$code" "$over"
}

# helper: count of slab-exhaustion alerts in the container error log (integer).
alert_count() {
    docker exec "$CONTAINER" sh -c \
        'grep -c "could not allocate node" /var/log/nginx/error.log 2>/dev/null || true' \
        2>/dev/null | head -n1 | tr -dc '0-9'
}

# ~6000-byte key body: node size = ~72B overhead + key.len > 4096, so the slab
# must allocate 2 pages. Stays well under the 8k single-header-line limit so the
# request is accepted (not a 400). Each key is made distinct with a suffix.
BIG="$(head -c 6000 /dev/zero | tr '\0' x)"

alerts_before="$(alert_count)"; alerts_before="${alerts_before:-0}"

# --- Phase A: pack the zone with many SMALL distinct keys ---------------------
N=4000
any_5xx=0
non_empty_over=0
last=""
for k in $(seq 1 "$N"); do
    last="$(probe "fullkey-${k}-$RANDOM")"
    code="${last%%|*}"
    over="${last##*|}"
    case "$code" in 5*) any_5xx=1 ;; esac
    # distinct keys are always first-seen / under budget; the only way over!=v=
    # would be a stale/garbage verdict. NGX_ERROR (zone full) leaves it "v=".
    [ "$over" != "v=" ] && [ -n "$over" ] && non_empty_over=1
done
printf 'phase A: %s small distinct keys, final %s\n' "$N" "$last"

# --- Phase B: hammer LARGE distinct keys to force the NGX_ERROR branch --------
M=40
for k in $(seq 1 "$M"); do
    last="$(probe "big-${k}-${RANDOM}-${BIG}")"
    code="${last%%|*}"
    over="${last##*|}"
    case "$code" in 5*) any_5xx=1 ;; esac
    [ "$over" != "v=" ] && [ -n "$over" ] && non_empty_over=1
done
printf 'phase B: %s large (~6k) distinct keys, final %s\n' "$M" "$last"

alerts_after="$(alert_count)"; alerts_after="${alerts_after:-0}"
printf 'slab alloc-failure alerts: before=%s after=%s\n' "$alerts_before" "$alerts_after"

# --- assertions ---------------------------------------------------------------
if [ "$any_5xx" -eq 0 ]; then
    pass 'zone-full flood never produced a 5xx (degrades gracefully)'
else
    fail 'zone-full flood produced a 5xx — alloc failure not degrading'
fi

if [ "$non_empty_over" -eq 0 ]; then
    pass 'verdict stayed present-but-empty ("v=") on the degraded path'
else
    fail 'verdict was non-empty under zone-full flood — NGX_ERROR not staying empty'
fi

if [ "$alerts_after" -gt "$alerts_before" ]; then
    pass "$(printf 'slab alloc-failure alert fired (%s -> %s) — NGX_ERROR branch proven' \
        "$alerts_before" "$alerts_after")"
else
    fail "$(printf 'no new slab alloc-failure alert (%s -> %s) — NGX_ERROR branch NOT exercised' \
        "$alerts_before" "$alerts_after")"
fi

finish
