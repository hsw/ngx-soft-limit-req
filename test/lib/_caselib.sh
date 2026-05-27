#!/usr/bin/env bash
#
# Shared assertion + curl helpers for test/cases/*.sh.
#
# This file lives OUTSIDE test/cases/ on purpose: run.sh enumerates cases via
# `test/cases/*.sh`, so a helper placed under test/cases/ would be executed as a
# (vacuous) "case". Cases source it via a path relative to the case file:
#
#     . "$(dirname "$0")/../lib/_caselib.sh"
#
# (run.sh invokes each case as `bash test/cases/NN-name.sh` with cwd = repo root,
# so $0 is the case path and ../lib resolves regardless of cwd.)
#
# Cases run on the HOST and drive the already-running container over HTTP, so the
# helper only needs to be reachable on the host filesystem — it is.
#
# Contract (preserved verbatim from the hand-rolled boilerplate each case used):
#   - `fails` accumulates sub-check failures; cases run `set -uo pipefail`
#     WITHOUT -e so sub-checks keep going.
#   - pass/fail print the exact "PASS  <msg>" / "FAIL  <msg>" lines.
#   - finish prints "<n> sub-check(s) failed" and `exit 1` when any sub-check
#     failed, else `exit 0` — this nonzero-exit-on-any-failure contract is what
#     run.sh relies on to count a case as FAIL.

# Sub-check failure counter. Sourced into each case's scope.
fails=0

# pass <msg>: record a passing sub-check.
pass() {
    printf 'PASS  %s\n' "$*"
}

# fail <msg>: record a failing sub-check (increments the counter).
fail() {
    printf 'FAIL  %s\n' "$*"
    fails=$((fails + 1))
}

# finish: emit the standard footer and exit with the correct status. Call this
# as the last line of every case (replaces the duplicated trailing if-block).
finish() {
    if [ "$fails" -ne 0 ]; then
        printf '%s sub-check(s) failed\n' "$fails"
        exit 1
    fi
    exit 0
}

# header_field <name>: read a curl `-D -` dump on stdin and print the first
# whitespace-delimited token after the named response header (case-insensitive),
# with CRs stripped. Empty output if the header is absent. This is the shared
# form of the per-case `tr -d '\r' | awk 'tolower($1)=="x-...:" {print $2}'`
# extractor. The header NAME is matched including its trailing colon, e.g.
#   header_field x-over:
header_field() {
    local name="$1"
    tr -d '\r' | awk -v h="$name" 'tolower($1) == tolower(h) { print $2 }'
}
