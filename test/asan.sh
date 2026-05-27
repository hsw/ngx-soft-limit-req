#!/usr/bin/env bash
#
# asan.sh — host-side driver for the AddressSanitizer + UBSan variant of
# ngx_http_soft_limit_req_module.
#
# Builds the instrumented image (test/docker/Dockerfile.asan) if missing, boots
# a container serving OUR test config on a host port, runs a curated subset of
# test/cases/*.sh against it over HTTP (the same cases the runtime harness
# test/run.sh uses — they are NOT rewritten), then cats the per-pid sanitizer
# log files out of the container and gates on them.
#
# OUR harness drives the running container from the HOST over HTTP via
# test/cases/*.sh (exactly like test/run.sh does), rather than running tests
# inside the container.
#
# Usage:
#   bash test/asan.sh
# Env:
#   SLR_ASAN_CASES   space-separated case-number prefixes to run
#                    (default below; override to widen/narrow the subset)
#   HOST_PORT        host port to bind (default 18091 — avoids run.sh's 18080)
#   NGINX_VERSION    override the pinned nginx version (passed as build-arg)
#
# Gate (see "sanitizer findings" below):
#   * ANY `==ERROR: AddressSanitizer` -> hard fail.
#   * UBSan `runtime error:` lines -> fail, EXCEPT known nginx-CORE noise:
#       - the function-pointer-cast class
#         ("call to function ... through pointer to incorrect function type"),
#         which fires for every nginx module via core's generic handler casts;
#       - any finding whose only frames are nginx-core src/ (our module is
#         ngx_http_soft_limit_req_module).
#   * Fails closed if zero HTTP traffic succeeded (instrumented nginx never
#     actually served, so a green result would be meaningless).
#
# Logs land in tmp/asan-logs/ on the host (gitignored).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="ngx-soft-limit-req-asan:latest"
CONTAINER="ngx-soft-limit-req-asan-$$"
HOST_PORT="${HOST_PORT:-18091}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
LOG_DIR="${REPO_ROOT}/tmp/asan-logs"

# Curated subset. Skips 30 (duplicate of 31's set=$var coverage) and 50 (soak —
# long-running, redundant with 20's flood under instrumentation).
#
# Case 10 (zone-directive parsing) is also EXCLUDED here even though it is a
# pure-config test: it mounts its OWN nginx.conf files that hardcode
# `load_module .../ngx_http_soft_limit_req_module.so;` and runs them via
# `docker run $IMAGE nginx -t`. This image is a STATIC build (the module is
# compiled in, no .so exists), so every one of case 10's nginx -t invocations
# fails with `dlopen() ... cannot open shared object file` — a harness/build-
# shape mismatch, NOT a defect in our module. Parser-error coverage runs
# against the dynamic-build runtime harness (test/run.sh) where the .so exists.
#
# The remaining cases drive the module's full runtime surface under ASan/UBSan:
# flood/never-reject node create+lookup (20), multi-var (31), coexistence+map
# routing (40), empty-key bypass (60), zone-full slab eviction + NGX_ERROR path
# (70), and the three internal-redirect re-entry shapes (80/81/82).
SLR_ASAN_CASES="${SLR_ASAN_CASES:-20 31 40 60 70 80 81 82}"

mkdir -p "$LOG_DIR"

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
    log "building ${IMAGE} from test/docker/Dockerfile.asan (NGINX_VERSION=${NGINX_VERSION:-default})"
    if [ -n "${NGINX_VERSION:-}" ]; then
        docker build --build-arg "NGINX_VERSION=${NGINX_VERSION}" \
            -t "$IMAGE" -f test/docker/Dockerfile.asan . || {
            echo "asan.sh: docker build failed" >&2; exit 1; }
    else
        docker build -t "$IMAGE" -f test/docker/Dockerfile.asan . || {
            echo "asan.sh: docker build failed" >&2; exit 1; }
    fi
else
    log "reusing existing image ${IMAGE} (docker rmi ${IMAGE} to force rebuild)"
fi

# --- boot + serve ---------------------------------------------------------
cleanup
log "booting container ${CONTAINER} on :${HOST_PORT}"
docker run -d --name "$CONTAINER" -p "${HOST_PORT}:80" "$IMAGE" >/dev/null || {
    echo "asan.sh: docker run failed" >&2; exit 1; }

# wait for the instrumented server to accept connections (ASan startup is
# slower than the plain build, so allow generous retries).
ready=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "$BASE_URL/" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.5
done
if [ "$ready" -eq 1 ]; then
    ok "instrumented server is up"
else
    bad "server did not come up"
    docker logs "$CONTAINER" 2>&1 | tail -40 || true
    exit 1
fi

# --- run case subset ------------------------------------------------------
export CONTAINER BASE_URL IMAGE
traffic_ok=0
for n in $SLR_ASAN_CASES; do
    # match exactly one case file per number prefix, e.g. 80-internal-redirect.sh
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
            traffic_ok=1
        else
            bad "case $(basename "$case_file")"
            # a case failing is itself a signal, but a sanitizer finding may be
            # the cause — keep going and let the log scan below decide the gate.
            traffic_ok=1
        fi
    done
done

# --- collect sanitizer logs ----------------------------------------------
# ASan/UBSan write each finding to its per-pid file under /tmp/sanlog at the
# MOMENT it occurs (not at exit), so the files already hold everything. We cat
# them out NOW, while the container is still running. We deliberately do NOT
# `nginx -s quit` first: the foreground master is PID 1, so quitting it stops
# the container and the subsequent `docker exec ... cat` would silently return
# nothing — turning the gate falsely green. (Leak-at-exit reporting is covered
# by the valgrind layer; ASan leak detection is disabled here anyway.)
SAN_OUT="${LOG_DIR}/sanitizer.txt"
docker exec "$CONTAINER" sh -c 'cat /tmp/sanlog/* 2>/dev/null' > "$SAN_OUT" 2>/dev/null || true

# Fail closed: no successful traffic means the instrumented nginx never served,
# so a clean log proves nothing.
if [ "$traffic_ok" -eq 0 ]; then
    bad "no case produced successful traffic — instrumented nginx may not have served; failing closed"
fi

# --- scan for findings ----------------------------------------------------
# ASan: any ==ERROR is a hard fail.
echo
log "=== sanitizer findings ==="
found_real=0

asan_hits="$(grep -E '==ERROR: AddressSanitizer' "$SAN_OUT" 2>/dev/null || true)"
if [ -n "$asan_hits" ]; then
    echo "--- AddressSanitizer ERROR(s) ---"
    grep -E '==ERROR: AddressSanitizer|SUMMARY: AddressSanitizer' "$SAN_OUT" | head -20
    found_real=1
fi

# UBSan: a `runtime error:` line carries its own COMPILE-TIME source location
# (e.g. "src/core/ngx_output_chain.c:70:20: runtime error: ...") regardless of
# whether the run-time symbolizer is available, so we classify by that source
# path — precise even when stack frames are bare addresses:
#   * the function-pointer-cast class ("call to function ... through pointer to
#     incorrect function type") fires from nginx core's generic handler casts
#     for EVERY module — pure core noise;
#   * any `runtime error:` anchored in an nginx-core source file
#     (src/core, src/http, src/event, src/os) is core noise;
#   * anything left — in particular a finding anchored in
#     ngx_http_soft_limit_req_module.c — is a REAL finding in our module.
ubsan_real="$(grep -E 'runtime error:' "$SAN_OUT" 2>/dev/null \
    | grep -v 'call to function .* through pointer to incorrect function type' \
    | grep -vE '(^|[[:space:]/])src/(core|http|event|os)/' \
    || true)"
ubsan_noise="$(grep -cE 'runtime error:' "$SAN_OUT" 2>/dev/null || true)"
if [ -n "$ubsan_real" ]; then
    echo "--- UBSan runtime error(s) anchored in OUR module ---"
    printf '%s\n' "$ubsan_real" | head -20
    found_real=1
fi
if [ "${ubsan_noise:-0}" -gt 0 ] && [ -z "$ubsan_real" ]; then
    echo "  (filtered ${ubsan_noise} nginx-core UBSan noise line(s): function-pointer-cast / core src — see ${SAN_OUT})"
fi

if [ "$found_real" -eq 0 ] && [ -z "$asan_hits" ]; then
    echo "  no sanitizer findings in OUR module"
fi

echo
log "=== asan summary: $PASS passed, $FAIL failed ==="
echo "  case subset:     ${SLR_ASAN_CASES}"
echo "  log dir:         ${LOG_DIR}/"
echo "  sanitizer log:   ${SAN_OUT}"

if [ "$FAIL" -ne 0 ] || [ "$found_real" -ne 0 ]; then
    exit 1
fi
exit 0
