#!/usr/bin/env bash
#
# Case 93: key-readiness CAVEAT as an executable fact (documents a FOOTGUN).
#
# soft_limit_req_server runs in POST_READ. Its zone key MUST be a variable that
# is already resolvable that early ($host / $http_* are the safe choices).
# NOTE: $remote_addr is NOT safe for server scope — at POST_READ it reads the raw
# TCP peer (realip has not rewritten it yet) and the read poisons its variable
# cache for the whole request (see README key-readiness section + case 95). This case
# pins the FAILURE mode of choosing a key that is NOT POST_READ-ready, so the
# footgun is encoded as a test rather than left as prose — in-convention with
# case 40 (d), which encodes the PREACCESS phase-order caveat the same way.
#
# The *.notready.example vhost attaches the server-scope directive on a zone
# keyed on $upstream_addr:
#   soft_limit_req_server zone=svnotready set=$over_host;   # POST_READ
# $upstream_addr is GENUINELY UNREADY (empty) at POST_READ: no upstream has been
# chosen yet — proxy_pass selects an upstream and populates $upstream_addr only
# in the CONTENT phase, long after POST_READ. So the complex value evaluates to
# an EMPTY string, the POST_READ handler hits its empty-key skip (key.len == 0),
# the bucket is NEVER accounted, and the verdict $over_host stays "".
#
# THIS IS A CAVEAT, NOT A FEATURE: a key that is unready at POST_READ silently
# disables the limiter (it degrades to permanent bypass). Case 90 proves the
# CORRECT shape — a $host-keyed zone whose verdict flips ""->"1" under flood;
# this case proves the negative — an $upstream_addr-keyed zone whose verdict
# NEVER flips, no matter how hard you flood, because the key is empty.
#
# CAVEAT ON RIGOR: with an always-empty key the zone node is never created, so the
# "verdict never flips" assertion (a) is structurally incapable of failing for the
# intended reason — it cannot, by construction, prove the flood is "strong enough".
# The POSITIVE CONTROL for that lives in case 90: it floods an identically-shaped
# $host-keyed zone with the SAME loop bound (A_N=40, same rate/burst class) and DOES
# flip the verdict, proving the flood is sufficient when the key IS ready. This case
# is therefore a DOCUMENTING counterpart to case 90, not an independently non-vacuous
# trip test — read the two together.
#
# Sub-cases:
#   (a) flood a single $host hard (vary client IP via X-Forwarded-For so no
#       hypothetical per-IP limiter is implicated) and assert the verdict NEVER
#       flips to "1" — the empty key bypasses the zone every request.
#   (b) every flooded request is still served 200 (the empty-key skip degrades
#       gracefully; the request is proxied to main, never rejected).
#   (c) a single fresh request reports X-Over-Srv "v=" — present (handler ran
#       and initialised the verdict to "") but empty (zone skipped), proving the
#       limiter is effectively a no-op, not merely that "1" was not observed.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# Per-run unique host suffix for rerun-safety against the long-lived container
# (matches cases 90/91/92). The zone is never charged here, but keeping fresh
# hosts avoids any cross-run coupling and stays consistent with the other cases.
run_tag="$(date +%s%N)-$$"

# helper: GET / with a given Host and X-Forwarded-For (client IP), print
# "<http_code>|<X-Over-Srv>". The verdict is echoed as "v=$over_host" so a
# present-but-empty verdict ("v=") is distinguishable from an absent header.
get_code_over() {
    local host="$1" xff="$2" dump code over
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: $host" -H "X-Forwarded-For: $xff" "$BASE_URL/" 2>/dev/null | tr -d '\r')"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-srv:)"
    printf '%s|%s\n' "$code" "$over"
}

# =========================================================================
# (c) FRESH request, before any flood -> 200, verdict present-but-empty "v="
# =========================================================================
# The empty $upstream_addr key makes the POST_READ handler skip the zone, but it
# still initialises the verdict to "" first, so X-Over-Srv must read "v=" — the
# limiter ran and tagged nothing (effective no-op), not header-absent.
res="$(get_code_over "fresh1-${run_tag}.notready.example" "192.0.2.50")"
c_code="${res%%|*}"
c_over="${res##*|}"
if [ "$c_code" = "200" ] && [ "$c_over" = "v=" ]; then
    pass '(c) unready-key request: 200, verdict present-but-empty "v=" (zone skipped)'
else
    fail "$(printf '(c) expected 200/v=, got %s/%s' "$c_code" "$c_over")"
fi

# =========================================================================
# (a) flood a single $host HARD -> verdict NEVER flips to "1" (footgun)
# =========================================================================
# Constant Host, varied client IP each request. If the key were POST_READ-ready
# this would flip the verdict to "1" within a handful of requests (cf. case 90).
# Because $upstream_addr is empty at POST_READ the zone is skipped every request,
# so the verdict stays "" for ALL of them. We send the full bound and assert "1"
# is NEVER observed (and every request is 200).
A_HOST="flood-${run_tag}.notready.example"
A_N=40
a_over_seen=0
a_any_non200=0
last=""
for i in $(seq 1 "$A_N"); do
    last="$(get_code_over "$A_HOST" "198.51.100.$i")"
    code="${last%%|*}"
    over="${last##*|}"
    [ "$over" = "v=1" ] && a_over_seen=1
    [ "$code" != "200" ] && a_any_non200=1
done
printf '(a) unready-key flood: final %s\n' "$last"

if [ "$a_over_seen" -eq 0 ]; then
    pass '(a) unready ($upstream_addr) key NEVER flipped verdict to "1" under flood (zone skipped — documented footgun)'
else
    fail '(a) verdict flipped to "1" — $upstream_addr was unexpectedly non-empty at POST_READ'
fi

# =========================================================================
# (b) every flooded request was still served 200 (graceful empty-key bypass)
# =========================================================================
if [ "$a_any_non200" -eq 0 ]; then
    pass '(b) every unready-key request served 200 (empty-key skip degrades gracefully)'
else
    fail "$(printf '(b) flood produced a non-200 (last=%s)' "$last")"
fi

finish
