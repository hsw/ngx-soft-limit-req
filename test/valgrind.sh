#!/usr/bin/env bash
#
# valgrind.sh — host-side driver for the Valgrind memcheck variant of
# ngx_http_soft_limit_req_module.
#
# Builds the instrumented image (test/docker/Dockerfile.valgrind) if missing,
# boots a container with a `sleep infinity` entrypoint, wraps /usr/sbin/nginx
# with a valgrind memcheck shim, starts nginx daemon-on (so the exec returns
# and the master + worker run under valgrind), runs a SMALL subset of PURE-HTTP
# cases from the host over HTTP, then `nginx -s quit` (graceful shutdown so
# valgrind flushes its per-pid logs), copies the logs out, and gates each via
# test/check-valgrind-log.sh.
#
# OUR harness drives the running container from the HOST over HTTP via
# test/cases/*.sh (the same cases test/run.sh uses — NOT rewritten), rather
# than running tests inside the container.
#
# Valgrind is ~50x slower than native, so we run only a small PURE-HTTP subset
# (no docker exec/run cases): 20 (flood -> node create/lookup/expire), 60
# (empty-key bypass), 80 (internal-redirect re-entry). Cases 10/50/70 are NOT
# run under valgrind (10 spawns its own containers, 50 is a soak, 70 floods
# 4000+ requests which would take far too long under memcheck).
#
# Usage:
#   bash test/valgrind.sh
# Env:
#   SLR_VALGRIND_CASES   space-separated case-number prefixes (default below)
#   HOST_PORT            host port to bind (default 18092)
#   NGINX_VERSION        override the pinned nginx version (build-arg)
#
# Gate: a per-pid log is a real finding iff `definitely lost: [1-9]` OR
# ERROR SUMMARY (errors - suppressed) > 0 (see test/check-valgrind-log.sh).
# FAILS CLOSED if zero per-pid logs were collected.
#
# Logs land in tmp/valgrind-logs/ on the host (gitignored).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="ngx-soft-limit-req-valgrind:latest"
CONTAINER="ngx-soft-limit-req-valgrind-$$"
HOST_PORT="${HOST_PORT:-18092}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
LOG_DIR="${REPO_ROOT}/tmp/valgrind-logs"
GATE="${REPO_ROOT}/test/check-valgrind-log.sh"

SLR_VALGRIND_CASES="${SLR_VALGRIND_CASES:-20 60 80}"

# Start from a CLEAN raw-log dir. The fail-closed guard later counts *.log files
# in $LOG_DIR/raw to detect "Memcheck never ran"; stale logs from a previous run
# would let a broken run (nginx wrapper failed, no logs produced this time) pass
# by gating last time's clean logs. Recreate the dir so only THIS run's per-pid
# logs are ever considered.
rm -rf "$LOG_DIR/raw"
mkdir -p "$LOG_DIR/raw"

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
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building ${IMAGE} from test/docker/Dockerfile.valgrind (NGINX_VERSION=${NGINX_VERSION:-default})"
    if [ -n "${NGINX_VERSION:-}" ]; then
        docker build --build-arg "NGINX_VERSION=${NGINX_VERSION}" \
            -t "$IMAGE" -f test/docker/Dockerfile.valgrind . || {
            echo "valgrind.sh: docker build failed" >&2; exit 1; }
    else
        docker build -t "$IMAGE" -f test/docker/Dockerfile.valgrind . || {
            echo "valgrind.sh: docker build failed" >&2; exit 1; }
    fi
else
    log "reusing existing image ${IMAGE} (docker rmi ${IMAGE} to force rebuild)"
fi

# --- boot (sleep entrypoint so we orchestrate via docker exec) ------------
cleanup
log "booting container ${CONTAINER} on :${HOST_PORT}"
docker run -d --name "$CONTAINER" -p "${HOST_PORT}:80" \
    --entrypoint sleep "$IMAGE" infinity >/dev/null || {
    echo "valgrind.sh: docker run failed" >&2; exit 1; }

# --- wrap nginx under valgrind --------------------------------------------
# Replace /usr/sbin/nginx with a shim that exec's valgrind memcheck. Every
# `nginx ...` invocation (start, -s quit) then goes through valgrind.
# --trace-children=yes follows the master->worker fork so the WORKER (where the
# handler runs and our slab allocations happen) is instrumented, and its per-pid
# log is what we gate on. --error-exitcode=99 surfaces memcheck errors on exit.
log "wrapping nginx with valgrind memcheck shim"
docker exec "$CONTAINER" sh -c 'mv /usr/sbin/nginx /usr/sbin/nginx.real && cat > /usr/sbin/nginx << "EOF"
#!/bin/sh
# valgrind wrapper: every `nginx ...` call goes through memcheck.
exec valgrind \
    --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=definite,indirect \
    --track-origins=yes \
    --trace-children=yes \
    --error-exitcode=99 \
    --log-file=/tmp/valgrind.%p.log \
    --suppressions=/etc/valgrind.supp \
    /usr/sbin/nginx.real "$@"
EOF
chmod +x /usr/sbin/nginx' || { echo "valgrind.sh: failed to install shim" >&2; exit 1; }

# --- start nginx daemon-on under valgrind ---------------------------------
# daemon on (NOT `-g daemon off`) so the wrapped exec returns and the master
# backgrounds; valgrind --trace-children follows the fork. The stripped
# /etc/nginx/nginx.conf is used (load_module already removed at build time).
log "starting nginx (daemon on) under valgrind"
docker exec "$CONTAINER" sh -c 'nginx -g "daemon on;"' >/dev/null 2>&1 || true

# wait for the server to accept connections (valgrind startup is very slow).
ready=0
for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null "$BASE_URL/" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -eq 1 ]; then
    ok "instrumented server is up (under valgrind)"
else
    bad "server did not come up under valgrind"
    docker exec "$CONTAINER" sh -c 'cat /tmp/valgrind.*.log 2>/dev/null | tail -40' || true
    docker logs "$CONTAINER" 2>&1 | tail -20 || true
    exit 1
fi

# --- run pure-HTTP case subset --------------------------------------------
export CONTAINER BASE_URL IMAGE
for n in $SLR_VALGRIND_CASES; do
    shopt -s nullglob
    matches=(test/cases/"${n}"-*.sh)
    shopt -u nullglob
    if [ "${#matches[@]}" -eq 0 ]; then
        bad "no case file matches prefix '${n}'"
        continue
    fi
    for case_file in "${matches[@]}"; do
        log "case: $case_file"
        if bash "$case_file"; then
            ok "case $(basename "$case_file")"
        else
            bad "case $(basename "$case_file")"
        fi
    done
done

# --- graceful shutdown so valgrind flushes per-pid logs -------------------
log "nginx -s quit (flush valgrind logs)"
docker exec "$CONTAINER" sh -c 'nginx -s quit' >/dev/null 2>&1 || true
# give valgrind time to write the worker + master leak reports on exit.
for _ in $(seq 1 30); do
    n="$(docker exec "$CONTAINER" sh -c 'ls /tmp/valgrind.*.log 2>/dev/null | wc -l' | tr -dc '0-9')"
    # wait until at least one log exists AND the master has exited (pidfile gone)
    if ! docker exec "$CONTAINER" sh -c 'test -f /run/nginx.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
sleep 2

# --- collect logs ---------------------------------------------------------
log "collecting valgrind logs"
docker exec "$CONTAINER" sh -c 'ls /tmp/valgrind.*.log 2>/dev/null || true' \
    | while IFS= read -r f; do
        [ -n "$f" ] || continue
        docker cp "${CONTAINER}:${f}" "${LOG_DIR}/raw/$(basename "$f")" >/dev/null 2>&1 || true
    done

# --- gate -----------------------------------------------------------------
echo
log "=== valgrind findings ==="
found_real=0

# Fail closed if zero per-pid logs were collected — valgrind never actually ran
# (shim broken, nginx never started, docker cp failed). Without this the loop
# below sees nothing and falsely reports "no leaks".
shopt -s nullglob
_vg_logs=("${LOG_DIR}/raw"/*.log)
shopt -u nullglob
if [ "${#_vg_logs[@]}" -eq 0 ]; then
    echo "ERROR: valgrind gate found zero per-pid logs in ${LOG_DIR}/raw/ — Memcheck never ran" >&2
    exit 1
fi

for f in "${LOG_DIR}/raw"/*.log; do
    [ -f "$f" ] || continue
    if ! gate_out="$("$GATE" "$f" 2>&1)"; then
        echo "--- $(basename "$f") ---"
        printf '%s\n' "$gate_out"
        grep -E 'definitely lost:|indirectly lost:|possibly lost:|ERROR SUMMARY:|Invalid (read|write)|Conditional jump|Use of uninitialised' "$f" | head -12
        found_real=1
    fi
done

if [ "$found_real" -eq 0 ]; then
    echo "  no leaks beyond suppressions"
fi

echo
log "=== valgrind summary: $PASS passed, $FAIL failed ==="
echo "  case subset:     ${SLR_VALGRIND_CASES}"
echo "  per-pid logs:    ${#_vg_logs[@]}"
echo "  log dir:         ${LOG_DIR}/"

if [ "$FAIL" -ne 0 ] || [ "$found_real" -ne 0 ]; then
    exit 1
fi
exit 0
