#!/usr/bin/env bash
#
# coverage.sh — host driver for the gcov-instrumented variant of
# ngx_http_soft_limit_req_module.
#
# Builds the instrumented image (test/docker/Dockerfile.coverage) if missing,
# boots a container with a `sleep infinity` entrypoint, starts nginx daemon-on
# (the stripped /etc/nginx/nginx.conf), runs as many test/cases/*.sh as feasible
# against it over HTTP (coverage overhead is low, ~2x, so we run them all for
# max coverage — the same cases test/run.sh uses, NOT rewritten), then
# `nginx -s quit` flushes .gcda and gcov summarises the result.
#
# Output:
#   * Per-file gcov line/branch coverage % for our module.
#   * tmp/coverage-logs/uncovered.txt — every executable line never executed
#     (gcov `#####:` markers).
#
# OUR harness drives the container from the HOST over HTTP (host-driven HTTP
# cases rather than running tests inside the container).
#
# Usage:
#   bash test/coverage.sh
# Env:
#   SLR_COVERAGE_CASES   space-separated case-number prefixes (default: all)
#   HOST_PORT            host port to bind (default 18093)
#   NGINX_VERSION        override the pinned nginx version (build-arg)
#
# Coverage is informational: a case FAILING does not fail this driver (we want
# the .gcda either way). The driver fails only if gcov produced no data at all.
#
# Logs land in tmp/coverage-logs/ on the host (gitignored).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="ngx-soft-limit-req-coverage:latest"
CONTAINER="ngx-soft-limit-req-coverage-$$"
HOST_PORT="${HOST_PORT:-18093}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
LOG_DIR="${REPO_ROOT}/tmp/coverage-logs"

# Default: every case. Cases 10/50/70 use docker; 10 mounts its own configs
# carrying a `load_module ...so;` line that a STATIC build rejects, so its
# nginx -t sub-checks will fail — that's expected and does not fail this driver
# (coverage is informational). 50 (soak) and 70 (4000-key flood) still add
# coverage and run fine. Override SLR_COVERAGE_CASES to narrow.
ALL_CASES="$(for f in test/cases/*.sh; do basename "$f" | sed 's/-.*//'; done | sort -u | tr '\n' ' ')"
SLR_COVERAGE_CASES="${SLR_COVERAGE_CASES:-$ALL_CASES}"

mkdir -p "$LOG_DIR"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- build ----------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building ${IMAGE} from test/docker/Dockerfile.coverage (NGINX_VERSION=${NGINX_VERSION:-default})"
    if [ -n "${NGINX_VERSION:-}" ]; then
        docker build --build-arg "NGINX_VERSION=${NGINX_VERSION}" \
            -t "$IMAGE" -f test/docker/Dockerfile.coverage . || {
            echo "coverage.sh: docker build failed" >&2; exit 1; }
    else
        docker build -t "$IMAGE" -f test/docker/Dockerfile.coverage . || {
            echo "coverage.sh: docker build failed" >&2; exit 1; }
    fi
else
    log "reusing existing image ${IMAGE} (docker rmi ${IMAGE} to force rebuild)"
fi

# --- boot (sleep entrypoint, then nginx daemon-on) ------------------------
cleanup
log "booting container ${CONTAINER} on :${HOST_PORT}"
docker run -d --name "$CONTAINER" -p "${HOST_PORT}:80" \
    --entrypoint sleep "$IMAGE" infinity >/dev/null || {
    echo "coverage.sh: docker run failed" >&2; exit 1; }

log "starting nginx (daemon on)"
docker exec "$CONTAINER" sh -c 'nginx -g "daemon on;"' >/dev/null 2>&1 || true

ready=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "$BASE_URL/" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    log "server did not come up"
    docker exec "$CONTAINER" sh -c 'cat /var/log/nginx/error.log 2>/dev/null | tail -30' || true
    docker logs "$CONTAINER" 2>&1 | tail -20 || true
    exit 1
fi
log "instrumented server is up"

# --- run cases ------------------------------------------------------------
export CONTAINER BASE_URL IMAGE
ran=0
for n in $SLR_COVERAGE_CASES; do
    shopt -s nullglob
    matches=(test/cases/"${n}"-*.sh)
    shopt -u nullglob
    [ "${#matches[@]}" -eq 0 ] && continue
    for case_file in "${matches[@]}"; do
        log "case: $case_file"
        # Coverage is informational; never block on a case failing. Tee output
        # to a per-case log for inspection.
        bash "$case_file" > "${LOG_DIR}/$(basename "$case_file").log" 2>&1 \
            && log "  case ok: $(basename "$case_file")" \
            || log "  case non-zero (informational): $(basename "$case_file")"
        ran=1
    done
done
if [ "$ran" -eq 0 ]; then
    echo "coverage.sh: no cases matched '${SLR_COVERAGE_CASES}'" >&2
    exit 1
fi

# --- flush .gcda ----------------------------------------------------------
log "nginx -s quit (flush .gcda)"
docker exec "$CONTAINER" sh -c 'nginx -s quit' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    if ! docker exec "$CONTAINER" sh -c 'test -f /run/nginx.pid' 2>/dev/null; then
        break
    fi
    sleep 0.5
done
sleep 1

# --- locate the addon objdir + verify .gcda exist -------------------------
# The .gcno/.gcda for --add-module=/src land under objs/addon/src/. Confirm the
# path before pointing gcov at it; if the addon layout differs, surface it.
OBJDIR="$(docker exec "$CONTAINER" sh -c '
    cd /usr/local/src/nginx
    if ls objs/addon/src/*.gcno >/dev/null 2>&1; then
        echo objs/addon/src
    else
        # fall back: find whatever dir holds the module .gcno
        dirname "$(find objs/addon -name "*soft_limit_req*.gcno" 2>/dev/null | head -n1)" 2>/dev/null
    fi
' | tr -d '\r')"
log "addon objdir: ${OBJDIR:-<none>}"

gcda_count="$(docker exec "$CONTAINER" sh -c "ls /usr/local/src/nginx/${OBJDIR}/*.gcda 2>/dev/null | wc -l" | tr -dc '0-9')"
gcda_count="${gcda_count:-0}"
if [ -z "$OBJDIR" ] || [ "$gcda_count" -eq 0 ]; then
    echo "coverage.sh: no .gcda produced under objs/addon — coverage flush failed" >&2
    docker exec "$CONTAINER" sh -c 'cd /usr/local/src/nginx && find objs/addon -name "*.gc*" 2>/dev/null | head' || true
    exit 1
fi
log "collected ${gcda_count} .gcda file(s)"

# --- gcov summary ---------------------------------------------------------
echo
log "=== gcov summary ==="
docker exec "$CONTAINER" sh -c "
    cd /usr/local/src/nginx
    gcov -b -c -o ${OBJDIR} /src/src/ngx_http_soft_limit_req_module.c 2>/dev/null \
        | grep -E '^(File|Lines|Branches|Taken|No branches|Calls)' | head -8
"

# Write uncovered lines (gcov '#####:' markers) to the host. gcov writes the
# .gcov annotation into cwd; we read it back from there.
echo
log "=== uncovered lines (first 80) ==="
docker exec "$CONTAINER" sh -c "
    cd /usr/local/src/nginx
    gcov -b -c -o ${OBJDIR} /src/src/ngx_http_soft_limit_req_module.c >/dev/null 2>&1
    f=ngx_http_soft_limit_req_module.c.gcov
    if [ -f \"\$f\" ]; then
        grep -nE '^[[:space:]]*#####:' \"\$f\"
    fi
" | tee "${LOG_DIR}/uncovered.txt" | head -80

echo
log "=== coverage summary ==="
echo "  case subset:       ${SLR_COVERAGE_CASES}"
echo "  addon objdir:      ${OBJDIR}"
echo "  .gcda collected:   ${gcda_count}"
echo "  log dir:           ${LOG_DIR}/"
echo "  uncovered detail:  ${LOG_DIR}/uncovered.txt"

exit 0
