#!/usr/bin/env bash
#
# Case 11: soft_limit_req_server (server-scope, POST_READ) directive parsing.
#
# Asserts that a valid `soft_limit_req_server` config passes `nginx -t`, that it
# is accepted at server{} and http{} scope but REJECTED in location{}, and that
# malformed variants (burst=0/negative, bad set=, missing zone=, duplicate,
# unknown param, reserved guard name, undefined zone) are rejected with the
# expected error. The shared parser is exercised independently of the location
# directive so the srv-conf array-init / duplicate-check path is covered.
#
# Runs each config in a fresh, ephemeral container off $IMAGE via `nginx -t -c`.
# Exported by run.sh: CONTAINER, BASE_URL, IMAGE.

set -uo pipefail

: "${IMAGE:?IMAGE must be set by run.sh}"

. "$(dirname "$0")/../lib/_caselib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# shared valid zone + a server scaffold whose server-level body is $2.
write_srv_conf() {
    # $1 = file, $2 = server-scope body
    write_conf "$1" \
"soft_limit_req_zone \$host zone=h:10m rate=100r/s;
server {
    listen 80;
    $2
    location / { return 200 ok; }
}"
}

# --- valid: server scope, zone + burst + set= ------------------------------
write_srv_conf "$WORK/srv-ok.conf" \
    'soft_limit_req_server zone=h burst=10 set=$over_srv;'
expect_ok "soft_limit_req_server valid (zone+burst+set)" "$WORK/srv-ok.conf"

# --- valid: zone only (burst/set optional) ---------------------------------
write_srv_conf "$WORK/srv-zone-only.conf" \
    'soft_limit_req_server zone=h;'
expect_ok "soft_limit_req_server valid (zone only)" "$WORK/srv-zone-only.conf"

# --- valid: http{} scope (inherited by all servers, intended) --------------
write_conf "$WORK/srv-http-scope.conf" \
"soft_limit_req_zone \$host zone=h:10m rate=100r/s;
soft_limit_req_server zone=h burst=10 set=\$over_srv;
server {
    listen 80;
    location / { return 200 ok; }
}"
expect_ok "soft_limit_req_server valid at http{} scope" "$WORK/srv-http-scope.conf"

# --- invalid: NOT allowed in location{} ------------------------------------
# The directive is NGX_HTTP_SRV_CONF only; nginx rejects it in a location.
write_conf "$WORK/srv-in-loc.conf" \
"soft_limit_req_zone \$host zone=h:10m rate=100r/s;
server {
    listen 80;
    location / {
        soft_limit_req_server zone=h burst=10;
        return 200 ok;
    }
}"
expect_fail "soft_limit_req_server rejected in location{}" \
    "$WORK/srv-in-loc.conf" 'directive is not allowed here'

# --- invalid: burst=0 ------------------------------------------------------
write_srv_conf "$WORK/srv-burst0.conf" \
    'soft_limit_req_server zone=h burst=0;'
expect_fail "soft_limit_req_server burst=0" "$WORK/srv-burst0.conf" \
    'invalid burst value'

# --- invalid: negative burst -----------------------------------------------
write_srv_conf "$WORK/srv-burstneg.conf" \
    'soft_limit_req_server zone=h burst=-5;'
expect_fail "soft_limit_req_server burst=-5" "$WORK/srv-burstneg.conf" \
    'invalid burst value'

# --- invalid: set= without a leading $ -------------------------------------
write_srv_conf "$WORK/srv-set-nodollar.conf" \
    'soft_limit_req_server zone=h burst=5 set=over;'
expect_fail "soft_limit_req_server set= without \$" \
    "$WORK/srv-set-nodollar.conf" 'invalid variable name'

# --- invalid: missing zone= parameter --------------------------------------
write_srv_conf "$WORK/srv-no-zone.conf" \
    'soft_limit_req_server burst=5;'
expect_fail "soft_limit_req_server missing zone=" "$WORK/srv-no-zone.conf" \
    'must have .*zone'

# --- invalid: duplicate zone in one server ---------------------------------
write_srv_conf "$WORK/srv-dup.conf" \
    'soft_limit_req_server zone=h burst=5;
    soft_limit_req_server zone=h burst=5;'
expect_fail "soft_limit_req_server duplicate zone" "$WORK/srv-dup.conf" \
    'is duplicate'

# --- invalid: unknown parameter --------------------------------------------
write_srv_conf "$WORK/srv-bad-param.conf" \
    'soft_limit_req_server zone=h bogus=1;'
expect_fail "soft_limit_req_server unknown parameter" "$WORK/srv-bad-param.conf" \
    'invalid parameter'

# --- invalid: set= aliasing the reserved internal guard variable -----------
# Reuses the same reserved-name rejection as the location parser.
write_srv_conf "$WORK/srv-reserved-var.conf" \
    'soft_limit_req_server zone=h burst=5 set=$__soft_limit_req_seen;'
expect_fail "soft_limit_req_server set= reserved guard name" \
    "$WORK/srv-reserved-var.conf" 'reserved'

write_srv_conf "$WORK/srv-reserved-var-mixedcase.conf" \
    'soft_limit_req_server zone=h burst=5 set=$__SOFT_LIMIT_REQ_SEEN;'
expect_fail "soft_limit_req_server set= reserved guard name (mixed case)" \
    "$WORK/srv-reserved-var-mixedcase.conf" 'reserved'

# --- invalid: referencing an UNDEFINED zone --------------------------------
write_srv_conf "$WORK/srv-undef-zone.conf" \
    'soft_limit_req_server zone=nosuchzone burst=10;'
expect_fail "soft_limit_req_server referencing an undefined zone" \
    "$WORK/srv-undef-zone.conf" 'zero size shared memory zone'

# --- valid: coexists with location-level soft_limit_req on separate zones --
# The two directives share the parser but write to DIFFERENT conf arrays
# (srv vs loc). Same zone name in both scopes is fine (one limit each).
write_conf "$WORK/srv-coexist.conf" \
"soft_limit_req_zone \$host zone=a:10m rate=100r/s;
soft_limit_req_zone \$host zone=b:10m rate=100r/s;
server {
    listen 80;
    soft_limit_req_server zone=a burst=10 set=\$over_a;
    location / {
        soft_limit_req zone=b burst=10 set=\$over_b;
        return 200 ok;
    }
}"
expect_ok "soft_limit_req_server coexists with soft_limit_req (separate zones)" \
    "$WORK/srv-coexist.conf"

finish
