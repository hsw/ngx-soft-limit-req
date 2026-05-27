#!/usr/bin/env bash
#
# Integration test harness for ngx_http_soft_limit_req_module.
#
# Builds the dynamic .so against the pinned nginx source inside Docker, boots
# nginx with the test config, and asserts:
#   - `nginx -t` passes (config + module load OK)
#   - the module .so is actually loaded
#   - GET / returns 200
#
# Then runs every test/cases/*.sh against the running container (later tasks add
# cases). Each case is sourced with helper env exported (CONTAINER, BASE_URL).
#
# Usage: ./test/run.sh
# Env:   NGINX_VERSION  override the pinned nginx version (default in Dockerfile)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="ngx-soft-limit-req-test"
CONTAINER="ngx-soft-limit-req-test-run"
HOST_PORT="${HOST_PORT:-18080}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"

PASS=0
FAIL=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- build ----------------------------------------------------------------
log "building image $IMAGE (NGINX_VERSION=${NGINX_VERSION:-default})"
if [ -n "${NGINX_VERSION:-}" ]; then
    docker build --build-arg "NGINX_VERSION=${NGINX_VERSION}" -t "$IMAGE" -f test/Dockerfile .
else
    docker build -t "$IMAGE" -f test/Dockerfile .
fi

# --- module compiled & present -------------------------------------------
log "checking module .so was produced"
if docker run --rm "$IMAGE" test -f /usr/lib/nginx/modules/ngx_http_soft_limit_req_module.so; then
    ok "ngx_http_soft_limit_req_module.so built and installed"
else
    bad "module .so missing"
fi

# --- config + module load validates --------------------------------------
log "checking 'nginx -t' (config valid + module loads)"
docker run --rm "$IMAGE" nginx -t >/tmp/nginx-t.out 2>&1 || true
if grep -q "syntax is ok" /tmp/nginx-t.out; then
    ok "nginx -t: syntax is ok"
else
    bad "nginx -t failed"
    cat /tmp/nginx-t.out || true
fi
if grep -q "test is successful" /tmp/nginx-t.out; then
    ok "nginx -t: test is successful (module loaded)"
else
    bad "nginx -t: config test not successful"
    cat /tmp/nginx-t.out || true
fi

# --- boot + serve ---------------------------------------------------------
cleanup
log "booting container on :$HOST_PORT"
docker run -d --name "$CONTAINER" -p "${HOST_PORT}:80" "$IMAGE" >/dev/null

# wait for the server to accept connections
ready=0
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "$BASE_URL/" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -eq 1 ]; then
    ok "server is up"
else
    bad "server did not come up"
    docker logs "$CONTAINER" || true
fi

log "checking GET / returns 200"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/" || echo 000)"
if [ "$code" = "200" ]; then
    ok "GET / -> 200"
else
    bad "GET / -> $code (expected 200)"
fi

# --- run case files (added by later tasks) --------------------------------
export CONTAINER BASE_URL IMAGE
shopt -s nullglob
for case_file in test/cases/*.sh; do
    log "case: $case_file"
    if bash "$case_file"; then
        ok "case $(basename "$case_file")"
    else
        bad "case $(basename "$case_file")"
    fi
done
shopt -u nullglob

# --- summary --------------------------------------------------------------
echo
log "summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
