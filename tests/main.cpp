#include <cstdio>
#include <cstring>

void TestSet();
void TestFPH();
void TestMapPerformance();

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
        // These report a failure by logging it and carrying on, so the exit
        // status below is not by itself a verdict. ctest matches the escape
        // sequence LogHelper emits for an Error as well -- see
        // FAIL_REGULAR_EXPRESSION in tests/CMakeLists.txt.
        TestSet();
        TestFPH();
    }
    if (run_benchmark) {
        TestMapPerformance();
    }

    return 0;
}
