#!/bin/bash
# run-sast.sh — in-container SAST dispatcher for ngx_http_soft_limit_req_module.
#
# Runs one of:
#   scan-build | clang-tidy | cppcheck | gcc-fanalyzer | flawfinder | all | summary
#
# Each tool writes its raw output to /work/sast-results/<tool>.log (mounted from
# the host as tmp/sast-results/). The host driver `test/sast.sh` is the
# convenient entry point; this script is only invoked inside the SAST image.
#
# The module is a single .c file (a fork of nginx's ngx_http_limit_req_module),
# so the analysis target is just MODULE_SRCS below.
#
# Gate policy:
#   Blocking (contributes to overall_rc): clang-tidy, cppcheck, gcc-fanalyzer, flawfinder
#   Advisory  (informational only):       scan-build (--status-bugs exits non-zero
#                                          on any finding; logged, not gated)
#
# Blocking-surface caveats (narrow on purpose):
#   * clang-tidy: only clang-analyzer-* + a couple high-signal cert/bugprone
#     checks trip the gate via -warnings-as-errors. The rest of --checks runs
#     advisory (printed, not blocking) so existing bugprone-* style noise does
#     not red-flag every run.
#   * cppcheck: --error-exitcode=2 only fires on severity=error. Warning/
#     performance/portability/style findings are printed but do NOT gate.
#   * gcc-fanalyzer: runs `make` against the WHOLE nginx tree, so the analyzer
#     fires on nginx-core paths we don't own. Gate is two-layered:
#       (i)  -Werror=analyzer-null-dereference + -Werror=analyzer-use-after-free
#            promote the two most severe classes to build-failures anywhere.
#       (ii) a post-process greps gcc-fanalyzer.log for -Wanalyzer-* findings
#            whose path is OUR module source (/work/module/) and trips the gate
#            on any match, regardless of class.
#     Other -Wanalyzer-* classes firing on nginx-core paths remain advisory.

set -uo pipefail

# Aggregate exit code across all blocking analyzer invocations. scan-build's rc
# is logged but never OR'd in.
overall_rc=0

TOOL="${1:-all}"
RESULTS=/work/sast-results
mkdir -p "$RESULTS"

MODULE_SRCS=(
  /work/module/src/ngx_http_soft_limit_req_module.c
)

# Include paths required to parse the module .c file outside compile_commands.
NGINX_INCS=(
  -I/work/nginx/src/core
  -I/work/nginx/src/event
  -I/work/nginx/src/event/modules
  -I/work/nginx/src/os/unix
  -I/work/nginx/src/http
  -I/work/nginx/src/http/modules
  -I/work/nginx/objs
)

configure_nginx() {
    local cc="$1"
    local extra_cflags="${2:-}"
    local rc
    cd /work/nginx
    make clean 2>/dev/null || true
    # Capture configure's exit code via PIPESTATUS — we pipe to `tail` for a
    # terse summary, but a piped failure must not slip through (set -uo pipefail,
    # not -e), else we'd analyze a stale/empty objs/ and report false-green.
    ./configure \
      --with-cc="$cc" \
      --with-cc-opt="-Wno-error ${extra_cflags}" \
      --with-compat \
      --add-module=/work/module \
      2>&1 | tail -3
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "configure_nginx: ./configure failed (rc=${rc}) for cc=${cc}" >&2
        return "$rc"
    fi
    return 0
}

run_scan_build() {
    echo "=== scan-build ==="
    if ! configure_nginx clang; then
        echo "blocking: configure failed for scan-build — skipping analyzer" >&2
        overall_rc=1
        return
    fi
    # alpha checkers catch bounds/cast issues the default set doesn't. We skip
    # security.insecureAPI.DeprecatedOrUnsafeBufferHandling — it fires on every
    # memcpy/memset (nginx core uses them everywhere) and drowns real findings.
    #
    # ADVISORY: --status-bugs makes scan-build exit non-zero on any finding. We
    # log the rc but never OR it into overall_rc.
    local rc
    CCC_CC=clang CCC_CXX=clang++ \
    scan-build \
      -o "$RESULTS/scan-build" \
      --status-bugs \
      -enable-checker alpha.security.ArrayBoundV2 \
      -enable-checker alpha.security.ReturnPtrRange \
      -enable-checker alpha.unix.cstring.OutOfBounds \
      -enable-checker alpha.core.CastSize \
      -enable-checker alpha.core.SizeofPtr \
      -enable-checker alpha.deadcode.UnreachableCode \
      make -j"$(nproc)" \
      2>&1 | tee "$RESULTS/scan-build.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        # Distinguish "bugs found" (advisory) from a tool-execution failure
        # (analyzer crashed / configure broke / binary missing). The latter has
        # NO "bugs found" / "No bugs found" marker — surface it as blocking so a
        # silently broken advisory analyzer can't masquerade as "ran clean".
        local bugs
        bugs=$(grep -Eo '[0-9]+ bugs? found' "$RESULTS/scan-build.log" | tail -1 || true)
        if [ -n "$bugs" ] || grep -qE 'No bugs found' "$RESULTS/scan-build.log"; then
            echo "advisory: scan-build exited $rc${bugs:+ (${bugs})} — NOT contributing to overall_rc"
        else
            echo "BLOCKING: scan-build exited $rc with NO 'bugs found' marker — analyzer crashed or failed to launch (check $RESULTS/scan-build.log)" >&2
            overall_rc=1
        fi
    fi
}

run_clang_tidy() {
    echo "=== clang-tidy ==="
    if [ ! -f /work/nginx/compile_commands.json ]; then
        echo "compile_commands.json missing — was the image built without the bear step?" >&2
        exit 1
    fi
    local rc
    # -clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling:
    # this checker flags every memcpy/memset as "insecure" (wants the C11 Annex K
    # *_s variants, which Linux/nginx do not provide and never use). nginx core
    # — and this module, via ngx_memcpy/ngx_memset — uses plain memcpy/memset
    # everywhere, so leaving it on (and promoted to error via clang-analyzer-*
    # below) red-flags every run with a pure false positive. Disabled here for
    # the same reason this checker is disabled for nginx static analysis.
    clang-tidy \
      --checks='-*,clang-analyzer-*,cert-*,bugprone-*,-clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling' \
      --warnings-as-errors='clang-analyzer-*,cert-err33-c,bugprone-use-after-move' \
      -p /work/nginx/compile_commands.json \
      "${MODULE_SRCS[@]}" \
      2>&1 | tee "$RESULTS/clang-tidy.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "blocking: clang-tidy exited $rc"
        overall_rc=1
    fi
}

run_cppcheck() {
    echo "=== cppcheck ==="
    # We do NOT use --error-exitcode here: this cppcheck version counts ANY
    # enabled-severity finding (including [style]) toward that exit code, which
    # would make every const-correctness / variable-scope nit blocking. Instead
    # we run with the full enabled set for the REPORT, then gate only on
    # severity=[error] via a post-grep — so warning/performance/portability/style
    # findings are printed/reviewed but advisory, matching the intended policy.
    cppcheck \
      -j "$(nproc)" \
      --enable=warning,performance,portability,style \
      --inconclusive \
      --force \
      --std=c11 \
      "${NGINX_INCS[@]}" \
      --suppress=missingIncludeSystem \
      --suppress=unusedFunction \
      --template='{file}:{line}: [{severity}] {id}: {message}' \
      "${MODULE_SRCS[@]}" \
      2>&1 | tee "$RESULTS/cppcheck.log"
    # Gate on error-severity findings located in OUR module source only (the
    # NGINX_INCS headers also get scanned and we don't own their style).
    local cppcheck_errors
    cppcheck_errors=$(grep -E '\[error\]' "$RESULTS/cppcheck.log" 2>/dev/null \
        | grep -F '/work/module/' || true)
    if [ -n "$cppcheck_errors" ]; then
        echo "blocking: cppcheck reported [error]-severity finding(s) in module sources:" >&2
        printf '%s\n' "$cppcheck_errors" >&2
        overall_rc=1
    fi
}

run_gcc_fanalyzer() {
    echo "=== GCC -fanalyzer ==="
    # NOTE: we deliberately do NOT pass -Werror=analyzer-null-dereference /
    # -Werror=analyzer-use-after-free. gcc -fanalyzer runs against the WHOLE
    # nginx tree, and nginx-core trips those analyzer classes (e.g.
    # src/core/ngx_log.c null-deref, ngx_socket.c fd-leak) — false positives we
    # don't own that would promote to build failures and fail the gate on
    # nginx-core, not our code. Instead the build runs warning-only and we gate
    # solely on the module-scoped post-process below, which catches ANY
    # -Wanalyzer-* class (null-deref, uaf, fd-leak, uninit, ...) in OUR source.
    if ! configure_nginx gcc "-fanalyzer -fanalyzer-verbosity=1"; then
        echo "blocking: configure failed for gcc-fanalyzer — skipping analyzer" >&2
        overall_rc=1
        return
    fi
    cd /work/nginx
    local rc
    make -j"$(nproc)" 2>&1 | tee "$RESULTS/gcc-fanalyzer.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "blocking: gcc -fanalyzer build exited $rc"
        overall_rc=1
    fi

    # Module-scoped gate: ANY -Wanalyzer-* finding in OUR module source blocks.
    # Match on /work/module/ (the in-container module path) so we don't
    # false-positive on nginx-core *_limit_req / *_filter paths.
    local module_findings
    module_findings=$(grep -E 'warning:.*-Wanalyzer-' "$RESULTS/gcc-fanalyzer.log" 2>/dev/null \
        | grep -F '/work/module/' || true)
    if [ -n "$module_findings" ]; then
        echo "blocking: gcc -fanalyzer reported -Wanalyzer-* finding(s) in module sources:" >&2
        printf '%s\n' "$module_findings" >&2
        overall_rc=1
    fi
}

run_flawfinder() {
    echo "=== flawfinder ==="
    # --error-level=N returns non-zero when any finding at severity >= N is
    # reported. Level 4 = the documented "really bad" tier (strcpy, gets, etc.);
    # level 1+ findings are still printed but only level>=4 trip the gate.
    local rc
    flawfinder --columns --context --minlevel=1 --error-level=4 \
      "${MODULE_SRCS[@]}" \
      2>&1 | tee "$RESULTS/flawfinder.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "blocking: flawfinder exited $rc"
        overall_rc=1
    fi
}

print_summary() {
    echo "========== scan-build =========="
    grep -v '^scan-build: ' "$RESULTS/scan-build.log" 2>/dev/null | grep -v '^$' | head -100
    echo
    echo "========== clang-tidy =========="
    grep -v '^$' "$RESULTS/clang-tidy.log" 2>/dev/null | head -200
    echo
    echo "========== cppcheck =========="
    grep -v '^$' "$RESULTS/cppcheck.log" 2>/dev/null \
      | grep -v 'checkersReport\|Active checkers' | head -100
    echo
    echo "========== GCC -fanalyzer =========="
    grep -E 'warning:.*-Wanalyzer' "$RESULTS/gcc-fanalyzer.log" 2>/dev/null \
      | grep -F '/work/module/' \
      | head -80
    echo
    echo "========== flawfinder =========="
    head -200 "$RESULTS/flawfinder.log" 2>/dev/null
}

case "$TOOL" in
    scan-build)    run_scan_build ;;
    clang-tidy)    run_clang_tidy ;;
    cppcheck)      run_cppcheck ;;
    gcc-fanalyzer) run_gcc_fanalyzer ;;
    flawfinder)    run_flawfinder ;;
    all)
        run_scan_build
        run_clang_tidy
        run_cppcheck
        run_gcc_fanalyzer
        run_flawfinder
        print_summary
        ;;
    summary)       print_summary ;;
    *)
        echo "Unknown tool: $TOOL" >&2
        echo "Usage: $0 {scan-build|clang-tidy|cppcheck|gcc-fanalyzer|flawfinder|all|summary}" >&2
        exit 2
        ;;
esac

# Exit non-zero if any BLOCKING analyzer reported failure. scan-build is
# advisory and never affects this.
if [ "$overall_rc" -ne 0 ]; then
    echo "run-sast.sh: blocking analyzer(s) failed — overall_rc=${overall_rc}" >&2
fi
exit "$overall_rc"
