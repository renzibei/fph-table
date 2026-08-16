# Continuous integration

CI runs shell scripts from `tests/ci/`. The workflow files pick a runner and a
compiler; everything else is in the scripts, so any failure can be reproduced
locally:

```sh
tests/ci/compile-matrix.sh
tests/ci/check-asm.sh
tests/ci/check-sizeof.sh
tests/ci/check-counters.sh
tests/ci/check-callgrind.sh    # Linux with valgrind installed
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

The compile matrix is gcc and clang, C++17/20/23, on Linux x86-64, Linux arm64
and macOS arm64.

`ctest` runs three configurations, because optimisation level and assertions are
separate axes and a bug can hide in either gap: `Release` (`-O3 -DNDEBUG`),
`O2-asserts` (`-O2`, assertions live), and `Debug` (`-O0`, assertions live). One
defect in this library trips an assert at `-O0` and becomes heap corruption
under `-DNDEBUG`.

## Method

Nothing is timed. A shared runner cannot resolve the differences this library
cares about, so every gate produces exact integers instead.

Nothing is compared against a number recorded elsewhere either, except `sizeof`.
Each gate builds the base revision in the same job with the same compiler and
compares against that, so a runner image or compiler upgrade moves both sides at
once and cannot fail a pull request that changed nothing. It also means there is
no baseline to go stale.

## What a green check means

A check reports success only when it took its measurement and the measurement
passed. A crashed probe, a compiler that is not installed, a disassembly that
came out empty, a counter that only one side reported, zero matching tests: each
of those fails the job. None of them is a pass.

There is one exception, and it announces itself. A push whose predecessor does
not exist — the first push of a branch — leaves the comparison gates nothing to
compare against. They emit a warning annotation saying so and finish without a
measurement.

## Which events run what

`ci` and `lookup-guard` both run on pull requests and on pushes to `master`.

The base revision differs per event: on a pull request it is the merge base, on
a push it is the event's predecessor. On a push the commit has already landed,
so the run reports rather than gates — it is what notices a direct push that
should have been a pull request.

## Signing off a deliberate change

Each gate has its own label. Adding one needs write access to the repository and
shows in the pull request header.

| gate | label |
| --- | --- |
| lookup asm | `allow-lookup-asm-change` |
| counters | `allow-construction-cost-increase` |
| callgrind | `allow-lookup-cost-increase` |

One label waives one gate. A waived gate emits a warning annotation and a line
in the job summary, so it does not read as a pass.

Locally, each script takes `--allow-change`.

There is no commit-message channel. A marker in a commit message is self-service
to anyone who can open a pull request, applies to every later push on the branch
once it is there, matches inside prose that is arguing against it, and survives
a merge.

## Lookup asm

`check-asm.sh` builds the lookup path as standalone symbols from both revisions
and compares them.

Identical passes. Anything else fails and prints the instruction diff, in both
directions. A shorter lookup path is not by itself an improvement — a static
instruction count is not a speed proxy, and a vectorised loop counts as one
instruction whatever it does — so it needs the same sign-off as a longer one.

What is normalised away is instruction addresses, branch and call targets,
`<symbol+offset>` operands and `%rip`-relative displacements: all of them move
when unrelated code changes size. Immediates are kept. Masks, shift amounts,
struct field offsets and hash constants are the content of the lookup path, and
erasing them hides changes like `and $0x1,%eax` becoming `and $0x3,%eax`.

## sizeof

Compared against `tests/ci/baselines/sizeof.txt` for exact equality, in both
directions. The recorded sizes hold on every LP64 target tried, so there is one
file rather than one per platform; a target where they cannot hold fails and
needs its own baseline.

```sh
tests/ci/update-baselines.sh --sizeof
```

## Counters

Fixed workloads, counted allocations and key operations, compared as upper
bounds against the base revision. Improvements pass with nothing to update; only
increases fail.

These counts cannot be written down: the parameter search draws from
`std::uniform_int_distribution`, so libstdc++ and libc++ disagree, and so do two
gcc versions.

The same probe reports the table's geometry for a fixed 20000-key set: the slot
stride, the slot span, the bucket count, and how many distinct 64-byte lines a
sweep of the key set touches. They are computed from slot indices rather than
addresses, so no part of them depends on where an allocation landed. They exist
because the asm gate proves the lookup *code* is unchanged and cannot see the
*data layout*: the parameter search can pick a geometry that spreads the same
keys over more cache lines while the disassembly stays byte-identical.

Both probe runs must reach their last workload. One probe source builds both
sides, so a counter that appears on one side only means a run stopped early, and
the check fails rather than treating it as new.

## Callgrind

`check-callgrind.sh` counts what one lookup loop executes, with the table built
before the collection window opens so the parameter search is not in the count.
Linux only: valgrind has no macOS arm64 port. `-march` and the simulated cache
geometry are pinned; both change the counts, and neither should be a property of
the runner the job landed on.

Instructions are compared for exact equality. Repeat runs are bit-identical, and
a commit that touched only construction moved the count by 0.0000% in every
scenario, so any movement is a real change of code path. Read it as a detector,
not a speedometer: on the one known lookup improvement it moved between 0.76x
and 3.85x the measured time change.

Simulated D1 misses are compared as an upper bound with 1% of headroom, about
ninety times the drift measured on a construction-only change. This is the
counter that sees a runtime parameter, which the disassembly cannot: changing
`max_load_factor` leaves the machine code byte-identical and moves the misses.
Measured, 0.6 to 0.9: D1 misses -8.6%, wall clock -9.2%.

Two limits on its reach. It is one-sided, so that 0.6 to 0.9 case **passes** —
it is the faster direction, and only a regression fails. And its sensitivity is
lumpy rather than linear: 0.6 to 0.45 moves nothing at all, because `Ceil2`
rounds both to the same slot count.

The parser requires the callgrind output to name `Ir`, `D1mr` and `D1mw`. A
column it cannot find would read as zero on both sides and compare equal, which
would retire half the gate without saying so.

Branch simulation is off; valgrind's predictor is a 2004 bimodal model and
reported 14 mispredicts per million probes here.

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

`ctest -L correctness`, `-LE slow` and `-R <name>` work as usual. Note that
`ctest` exits 0 when a selector matches nothing, so a label or a name that does
not exist reports success; check `ctest -N` if a run finishes suspiciously fast.
The benchmark is not registered unless you configure with
`-DFPH_ENABLE_BENCHMARK_TEST=ON`.

Adding a test needs only `tests/CMakeLists.txt`:

```cmake
add_executable(my_test my_test.cpp)
target_link_libraries(my_test fph::fph_table)
add_test(NAME my_test COMMAND my_test)
set_tests_properties(my_test PROPERTIES LABELS correctness TIMEOUT 600)
```

`tests/test_fph_table.cpp` reports a failure by logging it and carrying on;
`tests/main.cpp` turns the count of those reports into the exit status. It also
counts the checks that ran and fails if too few did, because a suite that
returns without testing anything otherwise passes in no time at all.
