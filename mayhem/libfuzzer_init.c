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
 * This file is compiled separately and linked into EVERY fuzzer binary in build.sh.
 * It does not modify any upstream source file.
 */

#include <stdlib.h>
#include <string.h>

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    int i;

    /* Honour an explicit -timeout=N on the command line — don't override it. */
    for (i = 1; i < *argc; i++) {
        if (strncmp((*argv)[i], "-timeout=", 9) == 0 ||
            strcmp((*argv)[i], "-timeout") == 0) {
            return 0;
        }
    }

    /* Inject -timeout=30 as argv[1], shifting existing args right. */
    int new_argc = *argc + 1;
    char **new_argv = (char **)malloc((size_t)(new_argc + 1) * sizeof(char *));
    if (!new_argv) return 0;  /* Graceful: proceed without injection on alloc failure */

    new_argv[0] = (*argv)[0];        /* argv[0] = binary name */
    new_argv[1] = "-timeout=30";     /* injected flag */
    for (i = 1; i < *argc; i++) {
        new_argv[i + 1] = (*argv)[i];
    }
    new_argv[new_argc] = NULL;

    *argc = new_argc;
    *argv = new_argv;
    return 0;
}
