#!/bin/sh
# check-valgrind-log.sh — classify a single valgrind --log-file output for
# ngx_http_soft_limit_req_module.
#
# Exit 0   : log is clean (no actionable errors / leaks). Fully-suppressed
#            "ERROR SUMMARY: N (suppressed: N)" lines and "definitely lost: 0
#            bytes" entries are considered clean.
# Exit 1   : log contains real (un-suppressed) errors or a non-zero
#            "definitely lost:" byte count. Findings are printed to stdout.
# Exit 2   : usage / file not readable.
#
# Used by test/valgrind.sh (host-side aggregator), so the gate semantics
# live in one place.
#
# Why awk and not grep:
#   - `grep -E 'ERROR SUMMARY: [1-9]'` matches ANY non-zero error count,
#     including fully-suppressed lines like
#     "ERROR SUMMARY: 1 errors from 1 contexts (suppressed: 1 from 1)" — that
#     red-flags known/whitelisted nginx-core noise.
#   - The detector below subtracts the `(suppressed: N)` count from the total
#     and only flags when (total - suppressed) > 0.

set -u

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <valgrind-log-file>" >&2
    exit 2
fi

f="$1"

if [ ! -r "$f" ]; then
    echo "$0: cannot read $f" >&2
    exit 2
fi

# - ERROR SUMMARY line: capture total and suppressed count; flag when
#   (total - suppressed) > 0.
# - definitely lost: NN bytes where NN > 0 -> real leak (NN may be
#   comma-grouped, e.g. "1,024 bytes").
# - No ERROR SUMMARY line at all => the run did not complete (valgrind always
#   emits exactly one ERROR SUMMARY line on a clean termination, even with zero
#   errors). Missing-SUMMARY => truncated or valgrind killed.
findings=$(awk '
    /ERROR SUMMARY: [0-9]+ errors? from [0-9]+ contexts? \(suppressed: [0-9]+/ {
        saw_summary = 1
        total_line = $0
        sub(/.*ERROR SUMMARY: /, "", total_line)
        total = total_line + 0
        supp_line = $0
        sub(/.*suppressed: /, "", supp_line)
        suppressed = supp_line + 0
        actionable = total - suppressed
        if (actionable > 0) {
            print "actionable:" actionable " errors in " FILENAME
        }
    }
    /definitely lost: [1-9][0-9,]* bytes/ {
        print "leak:" $0 " in " FILENAME
    }
    END {
        if (!saw_summary) {
            print "truncated:no ERROR SUMMARY in " FILENAME " (log truncated or valgrind killed)"
        }
    }
' "$f")

if [ -n "$findings" ]; then
    printf '%s\n' "$findings"
    exit 1
fi

exit 0
