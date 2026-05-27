#!/usr/bin/env bash
#
# Case 60: empty-key / verified-bypass — an empty soft-zone key skips the zone
# so the verdict stays "" and the request bypasses the soft limit entirely,
# while a present (non-empty) key over budget is tagged "1" and rerouted.
#
# The /emptykey location attaches:
#   soft_limit_req zone=svkey burst=10 set=$over_key;   # keyed on $http_x_soft_key
#   proxy_pass http://$pool_key;                        # map $over_key -> pool
# and echoes X-Over-Key. The zone is keyed on the X-Soft-Key REQUEST HEADER:
#   - header ABSENT  => complex value empty => handler skips (key.len == 0) =>
#     $over_key stays "" => map routes to main. This is the verified-bypass
#     path: trusted traffic (HMAC cookie -> empty key in production) is never
#     tagged or rerouted, NO MATTER how hard it floods.
#   - header PRESENT => bucket accounted => over budget flips $over_key="1" =>
#     map routes to quarantine_l2.
#
# This closes the Task 7 gap: empty-key bypass had no executable assertion.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# awk extractor shared by both header/no-header paths. X-Over-Key is emitted as
# "v=$over_key"; the "v=" prefix is KEPT here so the caller can tell a present
# empty verdict ("v=") from an absent header ("").
_parse_emptykey() {
    local dump="$1" code over pool
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-key:)"
    pool="$(printf '%s\n' "$dump" | header_field x-pool:)"
    printf '%s|%s|%s\n' "$code" "$over" "$pool"
}

# helper: GET /emptykey, optionally with an X-Soft-Key header, print
# "<http_code>|<X-Over-Key>|<X-Pool>". Pass "" as the key to OMIT the header.
# Two distinct curl invocations avoid empty-array expansion under `set -u`.
get_key() {
    local key="$1" dump
    if [ -n "$key" ]; then
        dump="$(curl -s -D - -o /dev/null -H "X-Soft-Key: $key" "$BASE_URL/emptykey")"
    else
        dump="$(curl -s -D - -o /dev/null "$BASE_URL/emptykey")"
    fi
    _parse_emptykey "$dump"
}

# =========================================================================
# (a) empty key under FLOOD never tags and always routes to main (bypass)
# =========================================================================
# Omit X-Soft-Key entirely. The zone key is empty => the handler skips svkey
# every request, so even a hard flood leaves $over_key="" and routes to main.
A_N=40
a_over_seen=0
a_non_main=0
a_any_5xx=0
last=""
for _ in $(seq 1 "$A_N"); do
    last="$(get_key "")"
    code="${last%%|*}"
    rest="${last#*|}"
    over="${rest%%|*}"
    pool="${rest##*|}"
    [ "$over" = "v=1" ] && a_over_seen=1
    [ "$pool" != "main" ] && a_non_main=1
    case "$code" in 5*) a_any_5xx=1 ;; esac
done
printf '(a) empty-key flood: final %s\n' "$last"

if [ "$a_over_seen" -eq 0 ]; then
    pass '(a) empty key never tagged "1" under flood (zone skipped)'
else
    fail '(a) empty key was tagged "1" — bypass broken'
fi

if [ "$a_non_main" -eq 0 ]; then
    pass '(a) empty key always routed to main (verified-bypass)'
else
    fail '(a) empty key routed away from main — bypass broken'
fi

if [ "$a_any_5xx" -eq 0 ]; then
    pass '(a) empty-key flood never produced a 5xx'
else
    fail '(a) empty-key flood produced a 5xx'
fi

# =========================================================================
# (b) a single empty-key request reports X-Over-Key="" (handler init "")
# =========================================================================
# Even with the zone skipped, the handler initializes the verdict variable to
# "" up front, so it must read PRESENT-but-empty ("v="), proving the handler
# ran and tagged it empty — not header-absent / not-found-stale.
res="$(get_key "")"
b_over="${res#*|}"; b_over="${b_over%%|*}"
if [ "$b_over" = "v=" ]; then
    pass "$(printf '(b) bypass request X-Over-Key present and empty (got "%s")' "$b_over")"
else
    fail "$(printf '(b) bypass X-Over-Key expected literal "v=", got "%s"' "$b_over")"
fi

# =========================================================================
# (c) a PRESENT, non-empty key over budget IS tagged "1" and rerouted
# =========================================================================
# Same location, but now send a concrete X-Soft-Key so the zone is accounted.
# rate=1r/s burst=10 => a tight back-to-back loop overruns and flips "1".
C_KEY="present-flooded-key"
c_over_seen=0
c_q_seen=0
last=""
for _ in $(seq 1 40); do
    last="$(get_key "$C_KEY")"
    rest="${last#*|}"
    over="${rest%%|*}"
    pool="${rest##*|}"
    [ "$over" = "v=1" ] && c_over_seen=1
    [ "$pool" = "quarantine_l2" ] && c_q_seen=1
done
printf '(c) present-key flood: final %s\n' "$last"

if [ "$c_over_seen" -eq 1 ]; then
    pass '(c) present non-empty key over budget tagged "1"'
else
    fail '(c) present key never tagged "1" — accounting broken'
fi

if [ "$c_q_seen" -eq 1 ]; then
    pass '(c) over-budget present key routed to quarantine_l2'
else
    fail '(c) over-budget present key never reached quarantine_l2'
fi

# =========================================================================
# (d) after flooding a present key, the empty key STILL bypasses (independent)
# =========================================================================
# Proves the empty-key skip is per-request and not poisoned by another key's
# over-budget state: omit the header again and confirm "" + main.
res="$(get_key "")"
d_over="${res#*|}"; d_over="${d_over%%|*}"
d_pool="${res##*|}"
if [ "$d_over" = "v=" ] && [ "$d_pool" = "main" ]; then
    pass '(d) empty key still bypasses after another key went over'
else
    fail "$(printf '(d) empty key not bypassing (over="%s" pool="%s")' \
        "$d_over" "$d_pool")"
fi

finish
