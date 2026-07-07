#!/usr/bin/env bash
#
# Case 10: soft_limit_req_zone directive parsing.
#
# Asserts that a valid `soft_limit_req_zone` config passes `nginx -t`, and that
# malformed variants (bad rate, missing/too-small zone size, unknown param,
# duplicate binding) are rejected with the expected error.
#
# Runs each config in a fresh, ephemeral container off $IMAGE via `nginx -t -c`.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${IMAGE:?IMAGE must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# header shared by every test config: load the module + minimal scaffolding.
HEADER='load_module /usr/lib/nginx/modules/ngx_http_soft_limit_req_module.so;
worker_processes 1;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {'
FOOTER='}'

write_conf() {
    # $1 = file, $2 = http-body lines
    printf '%s\n%s\n%s\n' "$HEADER" "$2" "$FOOTER" > "$1"
}

# run `nginx -t` on a host config file mounted into a fresh container.
# echoes combined output; return code is nginx's.
nginx_t() {
    local conf="$1"
    docker run --rm -v "$conf:/etc/nginx/nginx.conf:ro" "$IMAGE" \
        nginx -t 2>&1
}

# expect_ok <name> <conf-file>
expect_ok() {
    local name="$1" conf="$2" out
    out="$(nginx_t "$conf")"; local rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "test is successful"; then
        pass "$name"
    else
        fail "$(printf '%s (expected -t OK)' "$name")"
        printf '%s\n' "$out"
    fi
}

# expect_fail <name> <conf-file> <regex>
expect_fail() {
    local name="$1" conf="$2" re="$3" out
    out="$(nginx_t "$conf")"; local rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -Eq "$re"; then
        pass "$name"
    else
        fail "$(printf '%s (expected -t failure matching /%s/)' "$name" "$re")"
        printf '%s\n' "$out"
    fi
}

# --- valid -----------------------------------------------------------------
write_conf "$WORK/ok.conf" \
    'soft_limit_req_zone $host zone=h:10m rate=100r/s;'
expect_ok "valid zone (\$host, 10m, 100r/s)" "$WORK/ok.conf"

write_conf "$WORK/ok-rpm.conf" \
    'soft_limit_req_zone $binary_remote_addr zone=perip:1m rate=30r/m;'
expect_ok "valid zone (r/m scale)" "$WORK/ok-rpm.conf"

# --- invalid: bad rate -----------------------------------------------------
write_conf "$WORK/bad-rate.conf" \
    'soft_limit_req_zone $host zone=h:10m rate=0r/s;'
expect_fail "invalid rate (0r/s)" "$WORK/bad-rate.conf" 'invalid rate'

# --- invalid: wrong argument count (directive is TAKE3) --------------------
# Caught by the directive arg-count guard before the body parser runs.
write_conf "$WORK/few-args.conf" \
    'soft_limit_req_zone $host rate=100r/s;'
expect_fail "too few arguments" "$WORK/few-args.conf" \
    'invalid number of arguments'

# --- invalid: missing zone= parameter (3 args, none is zone=) --------------
# Two rate= params keep the arg count at 3 so the body parser reaches the
# "must have zone parameter" branch.
write_conf "$WORK/no-zone.conf" \
    'soft_limit_req_zone $host rate=100r/s rate=50r/s;'
expect_fail "missing zone= parameter" "$WORK/no-zone.conf" 'must have .*zone'

# --- invalid: zone size too small ------------------------------------------
write_conf "$WORK/small.conf" \
    'soft_limit_req_zone $host zone=h:4k rate=100r/s;'
expect_fail "zone too small (4k)" "$WORK/small.conf" 'too small'

# --- invalid: malformed zone= (no :size) -----------------------------------
write_conf "$WORK/no-size.conf" \
    'soft_limit_req_zone $host zone=h rate=100r/s;'
expect_fail "zone missing :size" "$WORK/no-size.conf" 'invalid zone size'

# --- invalid: unknown parameter (3 args, one unrecognized) -----------------
write_conf "$WORK/bad-param.conf" \
    'soft_limit_req_zone $host zone=h:10m bogus=1;'
expect_fail "unknown parameter" "$WORK/bad-param.conf" 'invalid parameter'

# --- invalid: same zone name bound to two different keys -------------------
write_conf "$WORK/dup.conf" \
    'soft_limit_req_zone $host zone=h:10m rate=100r/s;
     soft_limit_req_zone $uri  zone=h:10m rate=100r/s;'
expect_fail "duplicate zone name, different key" "$WORK/dup.conf" \
    'already bound to key'

# ===========================================================================
# soft_limit_req (location/server directive) parser — Task F2
# Each variant defines a valid zone, then attaches a soft_limit_req directive
# in a location and runs `nginx -t`. A valid attach must pass; malformed ones
# (burst=0/negative, bad set=, missing zone=, duplicate, unknown param) fail
# with the expected error.
# ===========================================================================

# shared valid zone + a server scaffold whose location body is $2.
write_loc_conf() {
    # $1 = file, $2 = location body
    write_conf "$1" \
"soft_limit_req_zone \$host zone=h:10m rate=100r/s;
server {
    listen 80;
    location / {
        $2
    }
}"
}

# --- valid: zone + burst + set= --------------------------------------------
write_loc_conf "$WORK/loc-ok.conf" \
    'soft_limit_req zone=h burst=10 set=$over;'
expect_ok "soft_limit_req valid (zone+burst+set)" "$WORK/loc-ok.conf"

# --- valid: zone only (burst/set optional) ---------------------------------
write_loc_conf "$WORK/loc-zone-only.conf" \
    'soft_limit_req zone=h;'
expect_ok "soft_limit_req valid (zone only)" "$WORK/loc-zone-only.conf"

# --- invalid: burst=0 ------------------------------------------------------
write_loc_conf "$WORK/loc-burst0.conf" \
    'soft_limit_req zone=h burst=0;'
expect_fail "soft_limit_req burst=0" "$WORK/loc-burst0.conf" \
    'invalid burst value'

# --- invalid: negative burst -----------------------------------------------
write_loc_conf "$WORK/loc-burstneg.conf" \
    'soft_limit_req zone=h burst=-5;'
expect_fail "soft_limit_req burst=-5" "$WORK/loc-burstneg.conf" \
    'invalid burst value'

# --- invalid: set= without a leading $ -------------------------------------
write_loc_conf "$WORK/loc-set-nodollar.conf" \
    'soft_limit_req zone=h burst=5 set=over;'
expect_fail "soft_limit_req set= without \$" "$WORK/loc-set-nodollar.conf" \
    'invalid variable name'

# --- invalid: set= with a 1-char name ($ + nothing) ------------------------
write_loc_conf "$WORK/loc-set-short.conf" \
    'soft_limit_req zone=h burst=5 set=$;'
expect_fail "soft_limit_req set=\$ (too short)" "$WORK/loc-set-short.conf" \
    'invalid variable name'

# --- invalid: missing zone= parameter --------------------------------------
write_loc_conf "$WORK/loc-no-zone.conf" \
    'soft_limit_req burst=5;'
expect_fail "soft_limit_req missing zone=" "$WORK/loc-no-zone.conf" \
    'must have .*zone'

# --- invalid: duplicate zone in one location -------------------------------
write_loc_conf "$WORK/loc-dup.conf" \
    'soft_limit_req zone=h burst=5;
        soft_limit_req zone=h burst=5;'
expect_fail "soft_limit_req duplicate zone" "$WORK/loc-dup.conf" \
    'is duplicate'

# --- invalid: unknown parameter --------------------------------------------
write_loc_conf "$WORK/loc-bad-param.conf" \
    'soft_limit_req zone=h bogus=1;'
expect_fail "soft_limit_req unknown parameter" "$WORK/loc-bad-param.conf" \
    'invalid parameter'

# --- invalid: set= aliasing the reserved internal guard variable -----------
# set=$__soft_limit_req_seen would alias the once-per-request guard slot; the
# parser must reject it (C5 hardening).
write_loc_conf "$WORK/loc-reserved-var.conf" \
    'soft_limit_req zone=h burst=5 set=$__soft_limit_req_seen;'
expect_fail "soft_limit_req set= reserved guard name" \
    "$WORK/loc-reserved-var.conf" 'reserved'

# nginx/Angie variable names are case-insensitive, so a mixed-case variant
# must be rejected too (the case-sensitive compare let it slip through).
write_loc_conf "$WORK/loc-reserved-var-mixedcase.conf" \
    'soft_limit_req zone=h burst=5 set=$__SOFT_LIMIT_REQ_SEEN;'
expect_fail "soft_limit_req set= reserved guard name (mixed case)" \
    "$WORK/loc-reserved-var-mixedcase.conf" 'reserved'

# --- referencing an UNDEFINED zone is rejected at config load --------------
# soft_limit_req accepts a zone= name syntactically (like stock limit_req does),
# but referencing a zone that no soft_limit_req_zone ever defined is caught by
# nginx CORE at config load: the size-0 shared-memory reference is rejected with
# "zero size shared memory zone". So a misconfig can never reach a worker with a
# NULL ctx (no runtime crash / NULL deref) — this asserts that protection as an
# executable regression test (raised in PR review). write_loc_conf defines zone
# "h"; we deliberately reference a different, undefined name.
write_loc_conf "$WORK/loc-undef-zone.conf" \
    'soft_limit_req zone=nosuchzone burst=10;'
expect_fail "soft_limit_req referencing an undefined zone" \
    "$WORK/loc-undef-zone.conf" 'zero size shared memory zone'

# --- invalid: two directives in one location sharing one set=$var ----------
# Two soft_limit_req on DIFFERENT zones (a, b) but the SAME set=$over in one
# location silently wipe each other's verdict at runtime; the parser must
# reject the collision. Built with write_conf (two zones) because write_loc_conf
# hardcodes a single zone "h" and cannot express this.
write_conf "$WORK/loc-dup-set.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    location / {
        soft_limit_req zone=a burst=10 set=\$over;
        soft_limit_req zone=b burst=10 set=\$over;
    }
}"
expect_fail "soft_limit_req duplicate set= in one location" \
    "$WORK/loc-dup-set.conf" \
    'set=\$over.*already used by another.*soft_limit_req'

# --- invalid: mixed-case set= aliases the same variable index --------------
# nginx variable names are case-insensitive, so set=$over and set=$OVER map to
# one index and collide just like the exact-match case above.
write_conf "$WORK/loc-dup-set-mixedcase.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    location / {
        soft_limit_req zone=a burst=10 set=\$over;
        soft_limit_req zone=b burst=10 set=\$OVER;
    }
}"
# The reject message prints the raw config token (&name points into cf->args, not
# a lowercased copy), so the last-writer set=$OVER renders verbatim as set=$OVER;
# the regex uses a case-insensitive character class to match either rendering robustly.
expect_fail "soft_limit_req duplicate set= (mixed case)" \
    "$WORK/loc-dup-set-mixedcase.conf" \
    'set=\$[oO][vV][eE][rR].*already used by another.*soft_limit_req'

# --- valid: two zones with DIFFERENT set= variables ------------------------
# Guards against an over-greedy reject: distinct variables must stay legal.
write_conf "$WORK/loc-distinct-set.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    location / {
        soft_limit_req zone=a burst=10 set=\$over_a;
        soft_limit_req zone=b burst=10 set=\$over_b;
    }
}"
expect_ok "soft_limit_req distinct set= variables (two zones)" \
    "$WORK/loc-distinct-set.conf"

# --- valid: two zones, neither has set= (NGX_CONF_UNSET guard) --------------
# Directives without set= carry set_index == NGX_CONF_UNSET; the guard must let
# any number of them coexist without matching each other.
write_conf "$WORK/loc-no-set.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    location / {
        soft_limit_req zone=a burst=10;
        soft_limit_req zone=b burst=10;
    }
}"
expect_ok "soft_limit_req two directives without set= (two zones)" \
    "$WORK/loc-no-set.conf"

# --- valid: same set=$var at server{} vs location{} (separate arrays) -------
# A server-level soft_limit_req and a location-level one live in SEPARATE conf
# arrays and the location fully overrides the inherited set via merge, so they
# never run together. Sharing set=$over across that boundary is legal -- the
# per-array reject must not reach across it.
write_conf "$WORK/loc-srv-vs-loc.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    soft_limit_req zone=a burst=10 set=\$over;
    location / {
        soft_limit_req zone=b burst=10 set=\$over;
        return 200 ok;
    }
}"
expect_ok "soft_limit_req same set= across server/location (separate arrays)" \
    "$WORK/loc-srv-vs-loc.conf"

finish
