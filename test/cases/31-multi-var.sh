#!/usr/bin/env bash
#
# Case 31: multiple zones, independent per-directive variables.
#
# The /multi location (prefix match) attaches TWO soft_limit_req directives:
#   soft_limit_req zone=svhost burst=10 set=$over_host;  # keyed on $host
#   soft_limit_req zone=svuri  burst=10 set=$over_uri;   # keyed on $uri
# and echoes both verdicts: X-Over-Host / X-Over-Uri.
#
# This proves (a) each directive writes its OWN variable and (b) the no-break
# loop evaluates EVERY zone on every request (if it broke after the first
# overflow the second variable would never be set).
#
# Scenario A — flood the HOST dimension only:
#   same Host, but VARYING paths under /multi/... => perhost[host] goes over
#   while each peruri[/multi/aN] stays under. Expect over_host=1, over_uri="".
#
# Scenario B — flood the URI dimension only:
#   same path /multi/fixed, but VARYING Host headers => peruri[/multi/fixed]
#   goes over while each perhost[hN] stays under. Expect over_uri=1, over_host="".
#
# Drives the already-running container booted by run.sh.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${BASE_URL:?BASE_URL must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

# helper: GET the given path+host, print "<X-Over-Host>|<X-Over-Uri>".
# Both headers are emitted as "v=$var" so an empty verdict reads "v=" (present)
# rather than vanishing (nginx drops empty-value headers). The "v=" prefix is
# stripped here so the verdict is "" (empty) or "1" (over). A header that is
# genuinely absent leaves the field unset -> prints as empty too, but the
# present-vs-absent distinction is asserted separately in over_pair_raw below.
over_pair() {
    local host="$1" path="$2" dump h u
    dump="$(curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL$path")"
    h="$(printf '%s' "$dump" | header_field x-over-host: | sed 's/^v=//')"
    u="$(printf '%s' "$dump" | header_field x-over-uri:  | sed 's/^v=//')"
    printf '%s|%s\n' "$h" "$u"
}

# helper: like over_pair but prints the RAW header values (with the "v=" prefix
# intact) so a present-but-empty verdict ("v=") is distinguishable from an
# absent header (""). Used for the load-bearing empty-side assertions.
over_pair_raw() {
    local host="$1" path="$2" dump h u
    dump="$(curl -s -D - -o /dev/null -H "Host: $host" "$BASE_URL$path")"
    h="$(printf '%s' "$dump" | header_field x-over-host:)"
    u="$(printf '%s' "$dump" | header_field x-over-uri:)"
    printf '%s|%s\n' "$h" "$u"
}

# =========================================================================
# Scenario A: flood HOST only (fixed host, varying paths)
# =========================================================================
HOST_A="flood-host-a.example"
N=60
pair=""
saw_host_over=0
for i in $(seq 1 "$N"); do
    # each request a distinct path so peruri buckets stay sparse/under
    pair="$(over_pair "$HOST_A" "/multi/a$i")"
    [ "${pair%%|*}" = "1" ] && saw_host_over=1
done
oh="${pair%%|*}"
ou="${pair##*|}"

printf 'scenario A (flood host): final over_host="%s" over_uri="%s"\n' "$oh" "$ou"

if [ "$saw_host_over" -eq 1 ] && [ "$oh" = "1" ]; then
    pass 'A: $over_host flipped to "1" under host flood'
else
    fail "$(printf 'A: expected $over_host="1" (saw_over=%s final="%s")' \
        "$saw_host_over" "$oh")"
fi

# assert the URI verdict is PRESENT-but-empty ("v="), not just falsy/absent.
raw_a="$(over_pair_raw "$HOST_A" "/multi/a-empty-probe")"
ou_raw="${raw_a##*|}"
if [ "$ou_raw" = "v=" ]; then
    pass 'A: $over_uri present and empty (uri dimension under budget)'
else
    fail "$(printf 'A: expected $over_uri literal "v=", got "%s"' "$ou_raw")"
fi

# =========================================================================
# Scenario B: flood URI only (fixed path, varying hosts)
# =========================================================================
PATH_B="/multi/fixed-b"
saw_uri_over=0
pair=""
for i in $(seq 1 "$N"); do
    # each request a distinct host so perhost buckets stay sparse/under
    pair="$(over_pair "flood-uri-b-$i.example" "$PATH_B")"
    [ "${pair##*|}" = "1" ] && saw_uri_over=1
done
oh="${pair%%|*}"
ou="${pair##*|}"

printf 'scenario B (flood uri): final over_host="%s" over_uri="%s"\n' "$oh" "$ou"

if [ "$saw_uri_over" -eq 1 ] && [ "$ou" = "1" ]; then
    pass 'B: $over_uri flipped to "1" under uri flood'
else
    fail "$(printf 'B: expected $over_uri="1" (saw_over=%s final="%s")' \
        "$saw_uri_over" "$ou")"
fi

# assert the HOST verdict is PRESENT-but-empty ("v="), not just falsy/absent.
raw_b="$(over_pair_raw "fresh-host-b-probe.example" "$PATH_B")"
oh_raw="${raw_b%%|*}"
if [ "$oh_raw" = "v=" ]; then
    pass 'B: $over_host present and empty (host dimension under budget)'
else
    fail "$(printf 'B: expected $over_host literal "v=", got "%s"' "$oh_raw")"
fi

finish
