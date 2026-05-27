#!/usr/bin/env bash
#
# Case 50: soak / sustained-load — single-pass account leaves no leaked nodes
# and the shared-memory zone usage stabilizes (does not grow unbounded).
#
# Task 6 hardening evidence. The simplified handler dropped the stock two-phase
# count++/account/unlock reservation and always calls *_lookup(..., account=1),
# so every node is either reused (found) or freshly allocated+inserted, and the
# LRU *_expire reclaims stale ones. If that invariant were broken (leaked nodes,
# a count++ reservation that *_expire refuses to evict, or a use-after-free on
# eviction) sustained distinct-key load would either:
#   - crash the worker (PID changes / 5xx), or
#   - exhaust the slab and spam "could not allocate node" ALERTs.
#
# This case drives sustained load with MANY distinct keys (distinct Host values
# => distinct rbtree nodes in the perhost zone keyed on $host), then RE-floods to
# confirm steady state. It asserts:
#   (a) the module still tags correctly and never 503s on soft overflow,
#   (b) the worker process is unchanged across the soak (no crash/restart),
#   (c) no "could not allocate node" slab-exhaustion ALERTs appear, and
#   (d) a flooded key still reads over ("1") after the soak (state still works).
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"
: "${CONTAINER:?CONTAINER must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# Number of distinct keys per flood wave and number of waves. Each distinct Host
# allocates a node in the perhost zone; re-using the same keys in a later wave
# must hit the existing nodes (no growth) rather than allocate anew.
KEYS=400
WAVES=3

# helper: HTTP status for a GET /setvar with the given Host. /setvar carries
# soft_limit_req zone=svhost set=$over_host and serves the static ok.txt via the
# content phase, so the PREACCESS handler runs and the bucket is accounted.
status_for() {
    local host="$1" path="${2:-/setvar}"
    curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "$BASE_URL$path"
}

# helper: X-Over verdict for a GET /setvar with the given Host. The header is
# "X-Over: v=$over_host"; strip the "v=" so the verdict is "" or "1".
over_for() {
    local host="$1"
    curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL/setvar" \
        | header_field x-over: | sed 's/^v=//'
}

# helper: RAW X-Over header value (keeps the "v=" prefix) so present-but-empty
# ("v=") is distinguishable from an absent header ("").
over_for_raw() {
    local host="$1"
    curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL/setvar" \
        | header_field x-over:
}

# helper: current worker process id(s) inside the container, sorted+joined.
# The slim image has no `ps`, so read /proc directly: a worker's cmdline is
# "nginx: worker process ...". Returns e.g. "7," (comma-terminated, sorted).
worker_pids() {
    docker exec "$CONTAINER" sh -c '
        for d in /proc/[0-9]*; do
            cl=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
            case "$cl" in
                "nginx: worker process"*) echo "${d#/proc/}" ;;
            esac
        done | sort -n | tr "\n" ","
    ' 2>/dev/null
}

# helper: count of slab-exhaustion alerts in the error log (single integer).
alert_count() {
    docker exec "$CONTAINER" sh -c \
        'grep -c "could not allocate node" /var/log/nginx/error.log 2>/dev/null || true' \
        2>/dev/null | head -n1 | tr -dc '0-9'
}

# --- baseline: capture worker pid + error-log alert count before the soak -----
pids_before="$(worker_pids)"
alerts_before="$(alert_count)"
alerts_before="${alerts_before:-0}"

if [ -n "$pids_before" ]; then
    pass "$(printf 'captured worker pid(s) before soak: %s' "$pids_before")"
else
    fail "could not read worker pid before soak"
fi

# --- soak: WAVES x KEYS distinct-key requests; assert never 503 ---------------
non200=0
total=0
for wave in $(seq 1 "$WAVES"); do
    for k in $(seq 1 "$KEYS"); do
        # distinct Host per key; identical set re-used each wave => steady state
        code="$(status_for "soak-key-${k}.example")"
        total=$((total + 1))
        if [ "$code" != "200" ]; then
            non200=$((non200 + 1))
            if [ "$non200" -le 3 ]; then
                printf '      wave %s key %s -> HTTP %s (expected 200)\n' \
                    "$wave" "$k" "$code"
            fi
        fi
    done
done

if [ "$non200" -eq 0 ]; then
    pass "$(printf 'soak served 200 for all %s requests (%s distinct keys x %s waves)' \
        "$total" "$KEYS" "$WAVES")"
else
    fail "$(printf 'soak saw %s non-200 of %s requests (soft overflow must never 503)' \
        "$non200" "$total")"
fi

# --- worker still alive and unchanged (no crash/restart during soak) ----------
pids_after="$(worker_pids)"
if [ -n "$pids_after" ] && [ "$pids_after" = "$pids_before" ]; then
    pass "$(printf 'worker pid(s) unchanged across soak: %s (no crash/restart)' \
        "$pids_after")"
else
    fail "$(printf 'worker pid changed (before="%s" after="%s") — possible crash' \
        "$pids_before" "$pids_after")"
fi

# --- no slab-exhaustion alerts: zone usage did not grow unbounded -------------
alerts_after="$(alert_count)"
alerts_after="${alerts_after:-0}"
if [ "$alerts_after" = "$alerts_before" ]; then
    pass "$(printf 'no new "could not allocate node" alerts (shm stable: %s)' \
        "$alerts_after")"
else
    fail "$(printf 'new slab-exhaustion alerts (before=%s after=%s) — zone grew unbounded' \
        "$alerts_before" "$alerts_after")"
fi

# --- state still works after the soak: a flooded key reads over ("1") ---------
# rate=1r/s burst=10 on svhost; a tight back-to-back loop overruns quickly.
saw_over=0
last=""
for _ in $(seq 1 40); do
    last="$(over_for soak-flood.example)"
    if [ "$last" = "1" ]; then
        saw_over=1
        break
    fi
done
if [ "$saw_over" -eq 1 ]; then
    pass 'post-soak flood still tags over ("1") — accounting intact'
else
    fail "$(printf 'post-soak flood never produced "1" (last="%s") — accounting broken' \
        "$last")"
fi

# --- a fresh, never-flooded key still reads present-but-empty after soak ------
v_raw="$(over_for_raw soak-pristine.example)"
if [ "$v_raw" = "v=" ]; then
    pass 'fresh key reads present-but-empty ("v=") after soak — verdict still correct'
else
    fail "$(printf 'fresh key expected literal "v=" after soak, got "%s"' "$v_raw")"
fi

finish
