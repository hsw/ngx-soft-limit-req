#!/usr/bin/env bash
#
# Case 94: http{}-level soft_limit_req_server is inherited and FIRES AT RUNTIME on
# a server that declares none of its own.
#
# A soft_limit_req_server declared at http{} scope is merged into every server's
# srv conf (merge_srv_conf, elts==NULL idiom) — a server that defines none of its
# own inherits it. Case 11 proves this PARSES; this case proves it actually RUNS:
# the *.inherit.example vhost has NO soft_limit_req_server of its own, yet the
# inherited POST_READ handler must charge the svinherit bucket and flip the
# verdict ""->"1" under flood.
#
# The inherited zone (svinherit, burst=1, rate=1r/s) is keyed on the X-Inherit-Key
# REQUEST HEADER — a key ONLY this case sends — so the http-level directive never
# perturbs any other vhost (their empty key hits the key.len==0 skip). We flood a
# single constant key value (varying the client IP, since the zone is not IP-keyed)
# and assert X-Over-Inherit flips to "v=1" — which can ONLY happen if the inherited
# directive ran in POST_READ on this server.
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# Per-run unique key so a case-level rerun against the long-lived container does
# not read a bucket an earlier run already pushed over (matches cases 90/91/92/93).
run_tag="$(date +%s%N)-$$"

# get_inherit <key>: GET / on the inherit vhost with the given X-Inherit-Key (and
# a random client IP), print "<code>|<X-Over-Inherit>".
get_inherit() {
    local key="$1" dump code over
    dump="$(curl -s -D - -o /dev/null \
        -H "Host: app.inherit.example" \
        -H "X-Inherit-Key: $key" \
        -H "X-Forwarded-For: 198.51.100.$((RANDOM % 254 + 1))" \
        "$BASE_URL/" | tr -d '\r')"
    code="$(printf '%s\n' "$dump" | awk 'NR == 1 { print $2 }')"
    over="$(printf '%s\n' "$dump" | header_field x-over-inherit:)"
    printf '%s|%s\n' "$code" "$over"
}

# =========================================================================
# fresh key: single request before any flood -> 200, verdict present-but-empty
# =========================================================================
# Proves the inherited handler RAN (initialised the verdict to "") and that the
# vhost is reachable + proxied, before the flood — so the flip below cannot be a
# connectivity artefact.
res="$(get_inherit "fresh-${run_tag}")"
f_code="${res%%|*}"
f_over="${res##*|}"
if [ "$f_code" = "200" ] && [ "$f_over" = "v=" ]; then
    pass 'fresh key: 200 proxied, inherited verdict present-but-empty "v=" (handler ran, under budget)'
else
    fail "$(printf 'fresh key: expected 200/v=, got %s/%s' "$f_code" "$f_over")"
fi

# =========================================================================
# flood one key -> inherited verdict flips to "v=1"
# =========================================================================
# Constant X-Inherit-Key (burst=1, rate=1r/s) accumulates over budget within a
# few requests; varied client IP proves the zone is the header-keyed inherited
# one, not any per-IP limiter. The verdict can only flip if the http-level
# directive was inherited AND its POST_READ handler ran on this vhost.
F_KEY="flood-${run_tag}"
F_N=40
saw_over=0
last=""
for i in $(seq 1 "$F_N"); do
    last="$(get_inherit "$F_KEY")"
    over="${last##*|}"
    [ "$over" = "v=1" ] && { saw_over=1; break; }
done
printf 'flood: final %s\n' "$last"

if [ "$saw_over" -eq 1 ]; then
    pass 'http-level soft_limit_req_server inherited and FIRED at runtime -> verdict "v=1" (no per-server directive)'
else
    fail "$(printf 'inherited verdict never flipped to v=1 under flood (last=%s) — http-level directive did not fire' "$last")"
fi

finish
