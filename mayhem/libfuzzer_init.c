/*
 * assimp/mayhem/libfuzzer_init.c — libFuzzer per-run timeout injection.
 *
 * The assimp_roundtrip_fuzzer exports a parsed scene to every supported format (40+).
 * If the fuzzer generates an input that assimp parses successfully, the export loop can
 * run for many minutes before completing.  Without a per-run -timeout, libFuzzer's
 * -max_total_time=15 (used by the local fuzz-smoke gate) cannot terminate the fuzzer:
 * -max_total_time is checked BETWEEN runs, not during a blocking run. The fuzz-smoke.sh
 * container then blocks until the default 1200-second per-run timeout fires, causing the
 * gate to time out or report a false failure.
 *
 * FIX: define LLVMFuzzerInitialize (the standard libFuzzer pre-run hook) to inject
 * -timeout=30 into argv before libFuzzer processes the arguments.  A 30-second per-run
 * cap is generous for all format-specific fuzzers (which reject non-matching input in
 * microseconds) and safe for the roundtrip fuzzer (the export loop finishes in < 30s for
 * any sane input; slow/infinite loops are caught promptly).
 *
 * ALLOCATION CAP: an importer that sizes one allocation from a header field lets a ~130-byte
 * file ask for ~800 MB in a single new[] (e.g. HMPImporter::InternReadFile_HMP7, HMPLoader.cpp:259).
 * The run then peaks near 2.4 GB RSS without crashing, i.e. right at libFuzzer's 2048 MB
 * -rss_limit_mb, so whether it is flagged out-of-memory (no stack) depends on when the RSS
 * sampler fires: the same input passes, or "crashes" with no stack, run to run. No legitimate
 * assimp input (<= 1 MB) needs a 256 MB single allocation (the largest legitimate run in the
 * corpora peaks well under 100 MB RSS), so -malloc_limit_mb=256 is injected too: libFuzzer then
 * reports the oversized request deterministically, with a stack, on every run.
 *
 * This file is compiled separately and linked into EVERY fuzzer binary in build.sh.
 * It does not modify any upstream source file.
 */

#include <stdlib.h>
#include <string.h>

static int has_flag(int argc, char **argv, const char *name) {
    size_t n = strlen(name);
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], name, n) == 0 && (argv[i][n] == '=' || argv[i][n] == '\0')) {
            return 1;
        }
    }
    return 0;
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    /* Honour explicit command-line flags — don't override them. */
    const char *inject[2];
    int n_inject = 0;
    if (!has_flag(*argc, *argv, "-timeout")) inject[n_inject++] = "-timeout=30";
    if (!has_flag(*argc, *argv, "-malloc_limit_mb")) inject[n_inject++] = "-malloc_limit_mb=256";
    if (n_inject == 0) return 0;

    int new_argc = *argc + n_inject;
    char **new_argv = (char **)malloc((size_t)(new_argc + 1) * sizeof(char *));
    if (!new_argv) return 0;  /* Graceful: proceed without injection on alloc failure */

    new_argv[0] = (*argv)[0];        /* argv[0] = binary name */
    for (int i = 0; i < n_inject; i++) {
        new_argv[1 + i] = (char *)inject[i];
    }
    for (int i = 1; i < *argc; i++) {
        new_argv[i + n_inject] = (*argv)[i];
    }
    new_argv[new_argc] = NULL;

    *argc = new_argc;
    *argv = new_argv;
    return 0;
}
