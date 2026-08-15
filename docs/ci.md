# Continuous integration

CI runs shell scripts from `tests/ci/`. The workflow files pick a runner and a
compiler; everything else is in the scripts, so any failure can be reproduced
locally:

```sh
tests/ci/compile-matrix.sh
tests/ci/check-asm.sh
tests/ci/check-sizeof.sh
tests/ci/check-counters.sh
tests/ci/check-callgrind.sh
tests/ci/perf-report.sh
```

All of them take `--help`.

## Jobs

| job | gates |
| --- | --- |
| `ci / compile` | headers compile clean under `-Wall -Wextra -Werror` |
| `ci / ctest` | the registered tests |
| `ci / asan+ubsan` | the same tests under ASan and UBSan |
| `lookup-guard / lookup asm` | the machine code of the lookup path |
| `lookup-guard / sizeof` | `sizeof` and `alignof` of the containers and iterators |
| `lookup-guard / counters` | allocations, bytes, peak footprint, key copies and moves, table geometry |
| `lookup-guard / callgrind` | instructions and simulated D1 misses in the lookup loop, Linux only |
| `lookup-guard / timing report` | nothing; it publishes numbers |

The compile matrix is gcc and clang, C++17/20/23, on Linux x86-64, Linux arm64
and macOS arm64.

`ctest` runs three configurations, because optimisation level and assertions are
separate axes and a bug can hide in either gap: `Release` (`-O3 -DNDEBUG`),
`O2-asserts` (`-O2`, assertions live), and `Debug` (`-O0`, assertions live). One
defect in this library trips an assert at `-O0` and becomes heap corruption
under `-DNDEBUG`.

A `stress` job runs on a nightly schedule and on `workflow_dispatch`, never on a
pull request. Its seed comes from the run number, so consecutive runs explore
different configurations; the seed is in the job name and the harness prints a
per-configuration recipe, so a failure can be replayed. Nothing carries the
`stress` label yet.

Timings are not gated. A shared runner cannot resolve the differences this
library cares about, so the report is informational. It prints the run's own
measured noise alongside each figure, and the threshold that noise implies, and
it states no verdict: a threshold can be checked against the numbers next to it,
a verdict cannot. The report is posted as a comment on the pull request and
rewritten in place on each push, as well as going to the job summary and an
artifact.

## Lookup asm

`check-asm.sh` builds the lookup path as standalone symbols from both the
current revision and the pull request base, in the same job with the same
compiler, and compares them. There is no checked-in baseline: one would go stale
whenever the runner image changed, and building both sides together means a
compiler upgrade cancels out.

Identical passes. Shorter passes, and prints how much shorter. Anything else
fails and prints the instruction diff.

To accept a deliberate change, add the `allow-lookup-asm-change` label, or put
`[allow-asm-change]` in a commit message, or pass `--allow-change` locally. The
diff is printed either way.

## sizeof

Compared against `tests/ci/baselines/sizeof.txt` for exact equality, in both
directions. The recorded sizes hold on every LP64 target tried, so there is one
file rather than one per platform; the check skips itself if `sizeof(void*)`
is not 8.

```sh
tests/ci/update-baselines.sh --sizeof
```

## Counters

Fixed workloads, counted allocations and key operations, compared as upper
bounds against the pull request base. Improvements pass with nothing to update;
only increases fail. Use the `allow-cost-increase` label, `[allow-cost-increase]`
in a commit message, or `--allow-change` locally.

Counts are not portable across standard library implementations, because the
parameter search draws from `std::uniform_int_distribution`. That is why the
comparison is against the base revision rather than a recorded number; the files
in `tests/ci/baselines/` are tagged with the toolchain that produced them and
skipped when it does not match.

```sh
tests/ci/update-baselines.sh --counters
```

The same probe reports the table's geometry for a fixed 20000-key set: the slot
stride, the slot span, the bucket count, and how many distinct 64-byte lines a
sweep of the key set touches. They are computed from slot indices rather than
addresses, so no part of them depends on where an allocation landed. They exist
because the asm gate proves the lookup *code* is unchanged and cannot see the
*data layout*: the parameter search can pick a geometry that spreads the same
keys over more cache lines while the disassembly stays byte-identical.

## Callgrind

`check-callgrind.sh` counts what one lookup loop executes, with the table built
before the collection window opens so the parameter search is not in the count.
Linux only: valgrind has no macOS arm64 port, and the script skips itself
elsewhere. `-march` and the simulated cache geometry are pinned; both change the
counts, and neither should be a property of the runner the job landed on.

Instructions are compared for exact equality. Repeat runs are bit-identical, and
a commit that touched only construction moved the count by 0.0000% in every
scenario, so any movement is a real change of code path. Read it as a detector,
not a speedometer: on the one known lookup improvement it moved between 0.76x
and 3.85x the measured time change.

Simulated D1 misses are compared as an upper bound with 1% of headroom, about
ninety times the drift measured on a construction-only change. This is the
counter that sees a runtime parameter: `max_load_factor` 0.6 to 0.9 leaves the
disassembly byte-identical and moves D1 misses 8.6% and wall clock 9.2%.

Branch simulation is off; valgrind's predictor is a 2004 bimodal model and
reported 14 mispredicts per million probes here.

Use the `allow-cost-increase` label, `[allow-cost-increase]` in a commit
message, or `--allow-change` locally.

## Tests

```sh
cmake -S tests -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

| test | labels |
| --- | --- |
| `fph_api_smoke` | `correctness` |
| `bits_array` | `correctness` |
| `sample_fph` | `correctness` |
| `fph_table_correctness` | `correctness`, `slow` |

`ctest -L correctness`, `-LE slow` and `-R <name>` work as usual. The benchmark
is not registered unless you configure with `-DFPH_ENABLE_BENCHMARK_TEST=ON`.

Adding a test needs only `tests/CMakeLists.txt`:

```cmake
add_executable(my_test my_test.cpp)
target_link_libraries(my_test fph::fph_table)
add_test(NAME my_test COMMAND my_test)
set_tests_properties(my_test PROPERTIES LABELS correctness TIMEOUT 600)
```

Two things to know when writing one:

`tests/test_fph_table.cpp` logs failures and exits 0 regardless, so ctest
matches its error output instead (`FAIL_REGULAR_EXPRESSION` in
`tests/CMakeLists.txt`).

A test that deliberately exhausts the parameter search will take minutes at the
library's default retry budget. Configure with `-DFPH_TEST_RETRY_BUDGET=<n>` to
pass a smaller one; it reaches tests as both a macro and an environment
variable, and goes to `Build()`'s `max_try_seed2_time` and `max_reseed2_time`.
