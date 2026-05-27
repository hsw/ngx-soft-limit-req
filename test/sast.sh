#!/bin/bash
# sast.sh — host-side driver for the parallel SAST suite.
#
# 5 SAST tools (scan-build, clang-tidy, cppcheck, gcc-fanalyzer, flawfinder) run
# in parallel containers from the same image. Outputs land in tmp/sast-results/.
#
# Valgrind is NOT part of this driver: our regression cases are HOST-driven over
# HTTP and cannot run inside a compose container, so valgrind has its own host
# driver — `bash test/valgrind.sh`. The ASan and coverage layers are likewise
# host-driven (test/asan.sh, test/coverage.sh). `all` here therefore runs the
# 5 SAST tools only (== `sast`).
#
# Usage:
#   bash test/sast.sh               # all 5 SAST tools in parallel, then summary
#   bash test/sast.sh sast          # alias for the above
#   bash test/sast.sh scan-build    # single tool
#   bash test/sast.sh clang-tidy
#   bash test/sast.sh cppcheck
#   bash test/sast.sh gcc-fanalyzer
#   bash test/sast.sh flawfinder
#   bash test/sast.sh summary       # re-print saved SAST summary
#
# Returns nonzero if compose reports a non-zero exit from any service, so CI (or
# a local gate) can act on it. scan-build is advisory inside run-sast.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TOOL="${1:-all}"
case "$TOOL" in
    scan-build|clang-tidy|cppcheck|gcc-fanalyzer|flawfinder|all|sast|summary) ;;
    *)
        echo "sast.sh: unknown tool '${TOOL}'" >&2
        echo "  expected: scan-build | clang-tidy | cppcheck | gcc-fanalyzer | flawfinder | all | sast | summary" >&2
        echo "  (valgrind runs via 'bash test/valgrind.sh', not here)" >&2
        exit 2
        ;;
esac

COMPOSE_FILE="test/docker/docker-compose.sast.yml"
mkdir -p "${REPO_ROOT}/tmp/sast-results"

# Build first (deduped per unique image), then run in parallel. Avoids the
# first-run race where multiple services sharing an image: name kick off
# redundant build context transfers. On warm cache this is a fast no-op.
build_images() {
    local services=("$@")
    echo "==> building images for: ${services[*]}"
    docker compose -f "$COMPOSE_FILE" build "${services[@]}"
}

# Map service name -> container name (per docker-compose.sast.yml).
container_name() {
    case "$1" in
        scan-build|clang-tidy|cppcheck|gcc-fanalyzer|flawfinder|summary) echo "sast-$1" ;;
        *) echo "" ;;
    esac
}

# Run a set of services in parallel and collect their exit codes after all
# finish. Avoids --abort-on-container-exit, which SIGKILLs longer-running tools
# as soon as the fastest one (flawfinder) finishes.
run_parallel() {
    local services=("$@")
    docker compose -f "$COMPOSE_FILE" up "${services[@]}"
    # Fail closed on a compose-level failure (image build broke, daemon refused,
    # a container couldn't be created). `up` without -d returns non-zero when it
    # cannot start the requested services; discarding it would let an analyzer
    # that never ran report a green gate.
    local up_rc=$?
    local rc=0
    if [ "$up_rc" -ne 0 ]; then
        echo "run_parallel: 'docker compose up' exited $up_rc — failing closed" >&2
        rc=1
    fi
    echo
    echo "==> per-service exit codes"
    for s in "${services[@]}"; do
        local cname
        cname="$(container_name "$s")"
        local code
        code="$(docker inspect --format '{{.State.ExitCode}}' "$cname" 2>/dev/null || echo "missing")"
        printf "  %-16s exit=%s\n" "$s" "$code"
        # A "missing" container (service never created) is a FAILURE, not a pass:
        # treating it as success would let a compose/create failure masquerade as
        # an analyzer that ran clean. Any non-zero exit also fails.
        if [ "$code" != "0" ]; then
            rc=1
        fi
    done
    return $rc
}

rc=0
case "$TOOL" in
    all|sast)
        # `all` == `sast`: the 5 SAST tools. valgrind/asan/coverage are
        # host-driven via their own scripts (see header).
        build_images scan-build clang-tidy cppcheck gcc-fanalyzer flawfinder
        echo "==> running 5 SAST tools in parallel (results -> tmp/sast-results/)"
        run_parallel scan-build clang-tidy cppcheck gcc-fanalyzer flawfinder
        rc=$?
        echo
        echo "==> SAST summary"
        docker compose -f "$COMPOSE_FILE" run --rm summary || true
        ;;
    summary)
        docker compose -f "$COMPOSE_FILE" run --rm summary
        rc=$?
        ;;
    *)
        build_images "$TOOL"
        echo "==> running single service: ${TOOL}"
        run_parallel "$TOOL"
        rc=$?
        ;;
esac

echo
echo "=== sast.sh summary ==="
echo "  tool:            ${TOOL}"
echo "  sast results:    ${REPO_ROOT}/tmp/sast-results/"
echo "  (valgrind:       run 'bash test/valgrind.sh' — host-driven, not here)"
ls -la "${REPO_ROOT}/tmp/sast-results" 2>/dev/null | sed 's/^/    /' | head -15 || true

exit "$rc"
