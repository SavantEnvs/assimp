#!/usr/bin/env bash
# assimp/mayhem/build.sh — build assimp (static, ASan+UBSan+SanitizerCoverage) so the FUZZED
# CODE (the model importers) is coverage-instrumented, then build the OSS-Fuzz libFuzzer harness
# (fuzz/assimp_fuzzer.cc, which calls Importer::ReadFileFromMemory) twice: once with
# $LIB_FUZZING_ENGINE (the Mayhem target /mayhem/assimp_fuzzer) and once with the standalone
# run-once driver ($STANDALONE_FUZZ_MAIN → /mayhem/assimp_fuzzer-standalone, a non-fuzzer
# reproducer).
#
# Step 3 (below) ALSO builds assimp's own GoogleTest suite (the `unit` binary) in a SEPARATE
# build dir with NORMAL flags (no sanitizers) — that's the honest oracle mayhem/test.sh RUNS.
# It's built independently so it never disturbs the sanitized fuzz build above.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# LIB_BUILD_FLAGS = SANITIZER_FLAGS + SanitizerCoverage (fuzzer-no-link).
# -fsanitize=fuzzer-no-link injects __sanitizer_cov_trace_pc_guard callbacks into every compiled
# TU so that libFuzzer can count edges through the library code at runtime.  Without it, only the
# harness TU is instrumented (from $LIB_FUZZING_ENGINE at link time) → Mayhem sees ~0 edges
# through the actual importer code → 0-edge cloud runs on all targets.
# NOTE: -fsanitize=fuzzer (LIB_FUZZING_ENGINE) implies fuzzer-no-link at the harness link step,
# but that does NOT retroactively instrument the already-compiled libassimp.a object files; the
# library must be compiled with fuzzer-no-link explicitly.
LIB_BUILD_FLAGS="${SANITIZER_FLAGS} -fsanitize=fuzzer-no-link"

# Harness binaries (step 2) link with lld: ld.bfd spends ~6 s per link pulling the 250 MB
# sanitized libassimp.a (x28 binaries, serially = minutes); lld does the same link in <1 s. The
# objects, flags and sanitizer runtimes linked are unchanged — only the linker program is.
HARNESS_LDFLAGS="-fuse-ld=lld"

cd "$SRC"

# BUILD COST (rlenv rebuilds this script from a `git clean -ffdX`-ed tree within a fixed per-call
# window, issue #1090): the two INDEPENDENT library builds — the sanitized fuzz build (step 1) and
# the normal-flags oracle build (step 3) — share no objects (different flags), so they are
# configured up front and compiled CONCURRENTLY instead of back to back, and the 28 harness
# binaries (step 2) are compiled+linked in parallel ($MAYHEM_JOBS at a time) instead of one by one.
# PEAK PARALLELISM is therefore up to 2x$MAYHEM_JOBS processes: each of the two cmake trees runs
# -j$MAYHEM_JOBS, and the harness jobs ($MAYHEM_JOBS at a time) start while the oracle tree may
# still be compiling. Total CPU work is unchanged; only the overlap is.
# Nothing is cached across the clean: every object of the project's own sources is rebuilt from
# the (patched) tree on every run, exactly as before.

# CLEANUP of background work. A plain `kill <pid>` of a background `cmake --build` only kills the
# cmake parent: its gmake/clang children are reparented to PID 1 and keep compiling after this
# script has exited (stealing CPU from, and racing `git clean`/rebuild of, the next call). So on
# ANY exit (success, `set -e` failure, a failed harness job, or TERM/INT/HUP) every descendant of
# this script is frozen with SIGSTOP (so nothing can fork new children mid-scan), re-scanned until
# no new descendant appears, then SIGKILLed, and the direct children are reaped. Background jobs
# deliberately stay in this script's process group (no setsid / set -m), so an external
# process-group kill by the caller still reaches all of them too. The /proc scan uses only shell
# builtins (no forks), so it never sees its own helper processes.
kill_descendants() {
  set +e
  local f line rest pid ppid stat q p n_before
  local -A kids=() seen=()
  local -a found=() queue=()
  while :; do
    kids=()
    for f in /proc/[0-9]*/stat; do
      { read -r line < "$f"; } 2>/dev/null || continue
      pid="${f#/proc/}"; pid="${pid%/stat}"
      rest="${line##*) }"            # fields after "(comm) ": state ppid ...
      stat="${rest%% *}"; rest="${rest#* }"; ppid="${rest%% *}"
      [ "$stat" = Z ] && continue    # zombies can't run or fork; ignore
      kids[$ppid]+=" $pid"
    done
    n_before=${#seen[@]}
    queue=("$$")
    while [ "${#queue[@]}" -gt 0 ]; do
      p="${queue[0]}"; queue=("${queue[@]:1}")
      for q in ${kids[$p]:-}; do
        queue+=("$q")
        [ -n "${seen[$q]:-}" ] && continue
        seen[$q]=1; found+=("$q")
        kill -STOP "$q" 2>/dev/null
      done
    done
    [ "${#seen[@]}" -eq "$n_before" ] && break
  done
  [ "${#found[@]}" -gt 0 ] && kill -KILL "${found[@]}" 2>/dev/null
  wait 2>/dev/null
  return 0
}
trap 'rc=$?; kill_descendants; exit $rc' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# 3a) Configure assimp's OWN GoogleTest suite (the `unit` target) — the functional oracle that
#    mayhem/test.sh runs. SEPARATE build dir ($SRC/build-tests) with NORMAL flags (no
#    SANITIZER_FLAGS) so it stays an honest, independent PATCH oracle and never touches the
#    sanitized fuzz build below. Same lean options (static, bundled zlib, no tools/samples),
#    but with -DASSIMP_BUILD_TESTS=ON, and build only the `unit` target. The test executable
#    lands at $SRC/build-tests/bin/unit (assimp's COMMON_OUTPUT_DIRECTORY = <build>/bin); the
#    model dir (ASSIMP_TEST_MODELS_DIR) is baked in at compile time as the absolute repo path
#    $SRC/test/models, so the binary finds models regardless of cwd.
cmake -S "$SRC" -B "$SRC/build-tests" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DBUILD_SHARED_LIBS=OFF \
      -DASSIMP_BUILD_ZLIB=ON \
      -DASSIMP_BUILD_TESTS=ON \
      -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
      -DASSIMP_BUILD_SAMPLES=OFF \
      -DASSIMP_WARNINGS_AS_ERRORS=OFF

# 1) Configure the PROJECT itself with $LIB_BUILD_FLAGS so the importers (the fuzzed code) are
#    coverage-instrumented. Static lib, no tests, no tools, no samples; bundle zlib statically.
cmake -S "$SRC" -B "$SRC/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$LIB_BUILD_FLAGS" -DCMAKE_CXX_FLAGS="$LIB_BUILD_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF \
      -DASSIMP_BUILD_ZLIB=ON \
      -DASSIMP_BUILD_TESTS=OFF \
      -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
      -DASSIMP_BUILD_SAMPLES=OFF \
      -DASSIMP_WARNINGS_AS_ERRORS=OFF

# 3b) Oracle `unit` build in the background, concurrently with steps 1-2; joined (and its exit
#     status checked) at the end of the script.
#     If the script exits early, the EXIT trap above kills the whole oracle build tree.
cmake --build "$SRC/build-tests" --target unit -j"$MAYHEM_JOBS" &
ORACLE_PID=$!

# 1b) Build the sanitized library. Run as a background job + `wait` (not a foreground command)
#     only so a TERM/INT/HUP is acted on at once instead of after the library finishes; a
#     failure still fails the script (set -e on the `wait` status).
cmake --build "$SRC/build" -j"$MAYHEM_JOBS" &
wait "$!"

# Locate the built static libs (paths vary slightly by assimp version / build layout).
LIBASSIMP="$(find "$SRC/build" -name 'libassimp*.a' | head -1)"
LIBZLIB="$(find "$SRC/build" -name 'libzlibstatic*.a' -o -name 'libzlib*.a' | head -1)"
[ -n "$LIBASSIMP" ] || { echo "ERROR: libassimp*.a not found under $SRC/build" >&2; exit 1; }

INCLUDES=(-I"$SRC/include" -I"$SRC/build/include")

# Compile the libFuzzer init hook — injects -timeout=30 so a single slow run (e.g.
# the roundtrip fuzzer exporting to 40+ formats) cannot block the fuzz-smoke gate
# indefinitely. See mayhem/libfuzzer_init.c for the full explanation.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/libfuzzer_init.c" -o /tmp/libfuzzer_init.o

# Build-time LeakSanitizer off-switch (linked into every fuzz + -standalone binary below).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o

# Standalone (non-fuzzer) reproducer driver: compile the C driver with $CC first so its
# LLVMFuzzerTestOneInput ref keeps C linkage (clang++ would mangle it and miss the harness's
# extern "C" definition). Respects $SANITIZER_FLAGS.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# Bounded parallel runner for the harness builds: at most $MAYHEM_JOBS at once; any failure
# fails the script (background jobs are invisible to `set -e`, so every pid is waited on), and
# the EXIT trap then kills the still-running sibling harness jobs and the oracle build.
HARNESS_PIDS=()
run_bg() {
  "$@" &
  HARNESS_PIDS+=("$!")
  if [ "${#HARNESS_PIDS[@]}" -ge "$MAYHEM_JOBS" ]; then
    wait "${HARNESS_PIDS[0]}" || { echo "ERROR: harness build failed" >&2; exit 1; }
    HARNESS_PIDS=("${HARNESS_PIDS[@]:1}")
  fi
}

# build_harness <harness.cc> <name>: link it twice, exactly as before —
#   /mayhem/<name>             harness + $LIB_FUZZING_ENGINE + sanitized assimp (the Mayhem target)
#   /mayhem/<name>-standalone  harness + LLVM's run-once driver (non-fuzzer reproducer)
build_harness() {
  local src="$1" name="$2"
  [ -f "$src" ] || { echo "ERROR: missing harness source $src" >&2; return 1; }
  run_bg $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
       "$src" $LIB_FUZZING_ENGINE /tmp/libfuzzer_init.o /tmp/lsan_off.o \
       "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl $HARNESS_LDFLAGS \
       -o "/mayhem/${name}"
  run_bg $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
       "$src" /tmp/standalone_main.o /tmp/libfuzzer_init.o /tmp/lsan_off.o \
       "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl $HARNESS_LDFLAGS \
       -o "/mayhem/${name}-standalone"
}

# 2a) The generic OSS-Fuzz harness (fuzz/assimp_fuzzer.cc, Importer::ReadFileFromMemory).
build_harness "$SRC/fuzz/assimp_fuzzer.cc" assimp_fuzzer

# 2b) The round-trip fuzzer (OSS-Fuzz ships this too): import any format, then export to every
#     supported format.
build_harness "$SRC/fuzz/assimp_roundtrip_fuzzer.cc" assimp_roundtrip_fuzzer

# 2c) The 12 per-format harnesses (OSS-Fuzz ships these alongside the generic one). Each
#     fuzz/assimp_fuzzer_<fmt>.cc includes fuzz/fuzzer_common.h (quote-include → resolved relative
#     to the source dir) and links the SAME sanitized assimp static lib.
for fmt in obj gltf glb fbx collada stl 3ds 3mf amf ase blend ifc; do
  build_harness "$SRC/fuzz/assimp_fuzzer_${fmt}.cc" "assimp_fuzzer_${fmt}"
done

for pid in "${HARNESS_PIDS[@]}"; do
  wait "$pid" || { echo "ERROR: harness build failed" >&2; exit 1; }
done

# 3c) Join the oracle build.
wait "$ORACLE_PID" || { echo "ERROR: oracle (unit) build failed" >&2; exit 1; }
