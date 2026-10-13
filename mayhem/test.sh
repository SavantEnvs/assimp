#!/usr/bin/env bash
#
# assimp/mayhem/test.sh — RUN assimp's GoogleTest suite (the `unit` binary, built by build.sh
# in $SRC/build-tests with NORMAL flags) → CTRF. PATCH-grade oracle. This only RUNS the
# pre-built binary; it never compiles.
#
# CWD GOTCHA: most tests read models via the compile-time absolute macro
# ASSIMP_TEST_MODELS_DIR (= $SRC/test/models), so they work from any cwd. But a handful of
# tests open files by a cwd-relative path (e.g. utD3MFImportExport reads "test.3mf", which
# lives at $SRC/test/test.3mf). So we run the binary from $SRC/test. (The exception tests use
# bogus names like "deadlyImportError.fail" that are MEANT to fail-to-load — those are not
# affected by cwd.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The unit binary lands at <build>/bin/unit (assimp's COMMON_OUTPUT_DIRECTORY).
BIN="$SRC/build-tests/bin/unit"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; exit 2; }

# Run from $SRC/test so the few cwd-relative model loads (e.g. test.3mf) resolve.
cd "$SRC/test"
out="$("$BIN" 2>&1)"; echo "$out"

# GoogleTest summary lines: "[==========] N tests from M ... ran.", "[ PASSED ] P tests.",
# "[ SKIPPED ] S tests, ...". failed = total - passed - skipped (avoids parsing repeated FAILED lines).
total=$(  printf '%s\n' "$out" | sed -n 's/.*\[=*\] \([0-9][0-9]*\) tests* from .*ran\..*/\1/p'    | tail -1)
passed=$( printf '%s\n' "$out" | sed -n 's/.*\[ *PASSED *\] \([0-9][0-9]*\) tests*\..*/\1/p'        | tail -1)
skipped=$(printf '%s\n' "$out" | sed -n 's/.*\[ *SKIPPED *\] \([0-9][0-9]*\) tests*,.*/\1/p'        | tail -1)
: "${total:=0}" "${passed:=0}" "${skipped:=0}"
failed=$(( total - passed - skipped )); [ "$failed" -lt 0 ] && failed=0

emit_ctrf "googletest" "$passed" "$failed" "$skipped"
