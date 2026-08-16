#include "loghelper.h"

#include <cstdio>
#include <cstring>

void TestSet();
void TestFPH();
void TestMapPerformance();

// A floor, not a target. The suite runs tens of thousands of table comparisons
// on a pristine checkout; this is low enough that trimming a scenario does not
// trip it and high enough that a suite which returns without testing anything
// cannot pass. Raise it when the suite grows, never lower it to make a run go
// green.
static const unsigned long kMinimumChecks = 1000;

static void PrintUsage(const char *program) {
    fprintf(stderr,
            "usage: %s [--correctness] [--benchmark]\n"
            "  --correctness  run the correctness tests (the default)\n"
            "  --benchmark    run the lookup/construct benchmark, which takes minutes\n"
            "With no option only the correctness tests run. The benchmark cannot fail\n"
            "and is minutes long, so CI does not run it.\n",
            program);
}

int main(int argc, char **argv) {
    bool run_correctness = false;
    bool run_benchmark = false;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--correctness") == 0) {
            run_correctness = true;
        }
        else if (strcmp(argv[i], "--benchmark") == 0) {
            run_benchmark = true;
        }
        else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            PrintUsage(argv[0]);
            return 2;
        }
    }
    if (!run_correctness && !run_benchmark) {
        run_correctness = true;
    }

    if (run_correctness) {
        // These report a failure by logging it and carrying on, so the verdict
        // is assembled here from what they counted.
        TestSet();
        TestFPH();

        const unsigned long checks = LogHelper::check_count();
        const unsigned long errors = LogHelper::error_count();
        printf("correctness checks run: %lu\n", checks);
        if (checks < kMinimumChecks) {
            fprintf(stderr,
                    "\033[40;31mcorrectness: only %lu checks ran, expected at least %lu; "
                    "the suite did not test what it is supposed to test\033[0m\n",
                    checks, kMinimumChecks);
            return 1;
        }
        if (errors != 0) {
            fprintf(stderr, "\033[40;31mcorrectness: %lu failure(s) reported\033[0m\n",
                    errors);
            return 1;
        }
    }
    if (run_benchmark) {
        TestMapPerformance();
    }

    return 0;
}
