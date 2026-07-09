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

cd "$SRC"

# 1) Build the PROJECT itself with $LIB_BUILD_FLAGS so the importers (the fuzzed code) are
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
cmake --build "$SRC/build" -j"$MAYHEM_JOBS"

# Locate the built static libs (paths vary slightly by assimp version / build layout).
LIBASSIMP="$(find "$SRC/build" -name 'libassimp*.a' | head -1)"
LIBZLIB="$(find "$SRC/build" -name 'libzlibstatic*.a' -o -name 'libzlib*.a' | head -1)"
[ -n "$LIBASSIMP" ] || { echo "ERROR: libassimp*.a not found under $SRC/build" >&2; exit 1; }

INCLUDES=(-I"$SRC/include" -I"$SRC/build/include")

# Compile the libFuzzer init hook — injects -timeout=30 so a single slow run (e.g.
# the roundtrip fuzzer exporting to 40+ formats) cannot block the fuzz-smoke gate
# indefinitely. See mayhem/libfuzzer_init.c for the full explanation.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/libfuzzer_init.c" -o /tmp/libfuzzer_init.o

# 2a) The libFuzzer harness (the Mayhem target): harness + engine + sanitized assimp.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
     "$SRC/fuzz/assimp_fuzzer.cc" $LIB_FUZZING_ENGINE /tmp/libfuzzer_init.o \
     "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
     -o /mayhem/assimp_fuzzer

# 2b) Standalone (non-fuzzer) reproducer: same harness + LLVM's run-once driver instead of the
#     engine. Compile the C driver with $CC first so its LLVMFuzzerTestOneInput ref keeps C linkage
#     (clang++ would mangle it and miss the harness's extern "C" definition). Respects $SANITIZER_FLAGS.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
     "$SRC/fuzz/assimp_fuzzer.cc" /tmp/standalone_main.o /tmp/libfuzzer_init.o \
     "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
     -o /mayhem/assimp_fuzzer-standalone

# 2c) The round-trip fuzzer (OSS-Fuzz ships this too): import any format, then export to every
#     supported format. Build libFuzzer target + standalone reproducer.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
     "$SRC/fuzz/assimp_roundtrip_fuzzer.cc" $LIB_FUZZING_ENGINE /tmp/libfuzzer_init.o \
     "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
     -o /mayhem/assimp_roundtrip_fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
     "$SRC/fuzz/assimp_roundtrip_fuzzer.cc" /tmp/standalone_main.o /tmp/libfuzzer_init.o \
     "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
     -o /mayhem/assimp_roundtrip_fuzzer-standalone

# 2d) The 12 per-format harnesses (OSS-Fuzz ships these alongside the generic one). Each
#     fuzz/assimp_fuzzer_<fmt>.cc includes fuzz/fuzzer_common.h (quote-include → resolved relative
#     to the source dir) and links the SAME sanitized assimp static lib. Build each one twice,
#     exactly like the generic harness above: a libFuzzer Mayhem target (/mayhem/assimp_fuzzer_<fmt>)
#     and a standalone run-once reproducer (/mayhem/assimp_fuzzer_<fmt>-standalone). The standalone
#     driver object (/tmp/standalone_main.o) was already compiled with $CC above; reuse it.
for fmt in obj gltf glb fbx collada stl 3ds 3mf amf ase blend ifc; do
  src="$SRC/fuzz/assimp_fuzzer_${fmt}.cc"
  [ -f "$src" ] || { echo "ERROR: missing harness source $src" >&2; exit 1; }

  # libFuzzer Mayhem target
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
       "$src" $LIB_FUZZING_ENGINE /tmp/libfuzzer_init.o \
       "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
       -o "/mayhem/assimp_fuzzer_${fmt}"

  # standalone (non-fuzzer) reproducer
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${INCLUDES[@]}" \
       "$src" /tmp/standalone_main.o /tmp/libfuzzer_init.o \
       "$LIBASSIMP" ${LIBZLIB:+"$LIBZLIB"} -lpthread -ldl \
       -o "/mayhem/assimp_fuzzer_${fmt}-standalone"
done

# 3) Build assimp's OWN GoogleTest suite (the `unit` target) — the functional oracle that
#    mayhem/test.sh runs. SEPARATE build dir ($SRC/build-tests) with NORMAL flags (no
#    SANITIZER_FLAGS) so it stays an honest, independent PATCH oracle and never touches the
#    sanitized fuzz build above. Same lean options (static, bundled zlib, no tools/samples),
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
cmake --build "$SRC/build-tests" --target unit -j"$MAYHEM_JOBS"
