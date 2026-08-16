# Continuous integration

CI runs shell scripts from `tests/ci/`. The workflow files pick a runner and a
compiler; everything else is in the scripts, so any failure can be reproduced
locally:

```sh
tests/ci/compile-matrix.sh
tests/ci/check-asm.sh
tests/ci/check-sizeof.sh
tests/ci/check-counters.sh
tests/ci/check-callgrind.sh --skip-unsupported
```

All of them take `--help`. `check-callgrind.sh` needs Linux and valgrind;
without `--skip-unsupported` it exits 2 anywhere else, including macOS.

## Jobs

| workflow / job | cells | gates |
| --- | --- | --- |
| `ci / compile` | 11 | headers compile clean under `-Wall -Wextra -Werror` |
| `ci / ctest` | 7 | the registered tests |
| `ci / asan+ubsan` | 1 | the same tests under ASan and UBSan |
| `lookup-guard / lookup asm` | 3 | the machine code of the lookup path |
| `lookup-guard / sizeof` | 2 | `sizeof` and `alignof` of the containers and iterators |
| `lookup-guard / counters` | 2 | allocations, bytes, peak footprint, key copies and moves, table geometry |
| `lookup-guard / callgrind` | 2 | instructions and simulated D1 misses in the lookup loop |

The compile matrix is 11 cells, not the full product: gcc and clang at C++17,
C++20 and C++23 on Linux x86-64; clang only on macOS arm64, where the image has
no system gcc; and both compilers at C++17 only on Linux arm64.

`ctest` runs three configurations, because optimisation level and assertions are
separate axes and a bug can hide in either gap: `Release` (`-O3 -DNDEBUG`) on
both Linux compilers and on macOS, `O2-asserts` (`-O2`, assertions live) and
`Debug` (`-O0`, assertions live) on both Linux compilers. One defect in this
library trips an assert at `-O0` and becomes heap corruption under `-DNDEBUG`.

The callgrind job is Linux only: valgrind has no macOS arm64 port.

## Which events run what

| event | `ci` | `lookup-guard` |
| --- | --- | --- |
| pull request opened, updated, reopened | yes | yes |
| pull request labelled or unlabelled | no | yes |
| push to `master` | yes | yes, reporting only |
| manual run (`workflow_dispatch`) | yes | yes |
| nightly, 03:17 UTC | yes | no |

`lookup-guard` runs on label changes because that is how a gate is signed off.
Adding the label starts a new run that sees it; re-running the failed one
replays the payload it already had.

The base revision the comparison gates use differs per event:

| event | base |
| --- | --- |
| pull request | `git merge-base HEAD origin/<base branch>` |
| push | the event's predecessor sha |
| manual run | whatever was typed in, or the merge base with `origin/master` |

On a pull request it has to be the merge base and not the base sha in the event
payload. That sha is a snapshot from when the payload was written, while
`refs/pull/N/merge` is recomputed whenever the target branch moves, so once
`master` advances the two disagree and the gate charges the pull request with
`master`'s changes.

On a manual run there is no default base. A checkout has `origin/master` and no
local `master`, so a default of `master` resolves to nothing on a branch and to
`HEAD` on `master`; leaving it empty lets the script take the merge base, and on
`master` itself the previous commit.

## What a green check means

A check reports success only when it took its measurement and the measurement
passed. A crashed probe, a compiler that is not installed, a disassembly that
came out empty, a counter that only one side reported, zero matching tests: each
of those fails the job.

Three things finish green without a measurement, and each says so in a warning
annotation and a line in the job summary:

- A push whose predecessor does not exist — the first push of a branch.
- A pull request whose probe cannot be built against the base revision, once it
  carries that gate's label. See "Adding public API" below.
- A push whose predecessor cannot build the probe, which is what merging such a
  pull request looks like: the base is then the `master` before the merge, and
  by definition it does not have the new API.

Push-triggered runs of `lookup-guard` report rather than gate. The commit has
already landed and a push event carries no pull request and so no labels, so a
difference is a warning annotation and the job stays green; otherwise every
merge of a signed-off pull request would turn `master` red. Everything else
that stops a measurement — a probe that will not build against this revision, a
compiler that is not installed, an empty disassembly — still fails the job on a
push.

## Method

Nothing is timed. A shared runner cannot resolve the differences this library
cares about, so every gate produces exact integers instead.

Nothing is compared against a number recorded elsewhere either, except `sizeof`.
Each gate builds the base revision in the same job with the same compiler and
compares against that, so a runner image or compiler upgrade moves both sides at
once and cannot fail a pull request that changed nothing.

## Signing off a deliberate change

Each gate has its own label. Adding one needs write access to the repository,
shows in the pull request header, and starts a new run.

| gate | label | `--allow-change` locally |
| --- | --- | --- |
| lookup asm | `allow-lookup-asm-change` | yes |
| counters | `allow-construction-cost-increase` | yes |
| callgrind | `allow-lookup-cost-increase` | yes |
| sizeof | none — rewrite the baseline instead | no |
| compile matrix | none — nothing to sign off | no |

One label waives one gate. A waived gate exits 0, so on the pull request's check
list it is the same green tick as a pass. What tells them apart is the warning
annotation on the run, the line it adds to the job summary, and the label on the
pull request itself.

There is no commit-message channel. A marker in a commit message needs no write
access, applies to every later push on the branch once it is there, and
survives a merge.

## Adding public API

The probe sources always come from the revision under test, so a pull request
that adds public API and exercises it in a probe leaves the base revision unable
to compile that probe. No comparison is possible. The gate says which side
failed to build and stops with exit 2. Two ways forward:

- Land the API first, and add the probe's use of it in a later pull request.
  The gate then measures both.
- Add that gate's label. The gate announces that it did not run and finishes
  green, and the label records that the run measured nothing.

The push that merges such a pull request hits the same wall, because its base
is the `master` before the merge. There it is a warning and the job stays
green, for the same reason every other push-triggered difference is.

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

The probe serves every allocation from a fixed 512 MiB arena, which is what
makes the counts reproducible; it is `.bss`, so untouched pages cost nothing.
A change that makes the parameter search restart far more often can use it up,
and the probe then stops with `arena exhausted`. Measured high-water marks at
20000 keys: 13 MB unmodified, 51 MB with the default load factor at 0.9, 239 MB
at 0.97. If a change needs more, raise `kArenaBytes` in
`tests/ci/counter_probe.cpp` in the same commit. It cannot grow much further:
2 GiB of `.bss` does not link under the default code model.

## Callgrind

`check-callgrind.sh` counts what one lookup loop executes, with the table built
before the collection window opens so the parameter search is not in the count.
Linux only. `-march` and the simulated cache geometry are pinned; both change
the counts, and neither should be a property of the runner the job landed on.

Instructions are compared for exact equality. Repeat runs are bit-identical, and
a commit that touched only construction moved the count by 0.0000% in every
scenario, so any movement is a real change of code path. It detects a change; it
does not measure its size. On the one known lookup improvement it moved between
0.76x and 3.85x the measured time change.

Simulated D1 misses are compared as an upper bound with 1% of headroom, about
ninety times the drift measured on a construction-only change. This is the
counter that sees a runtime parameter, which the disassembly cannot: changing
`max_load_factor` leaves the machine code byte-identical and moves the misses.

Measured, the default `max_load_factor` 0.6 to 0.9: D1 misses fall between 3.86%
and 8.59% across the six scenarios, so the D1 half passes — the bound is
one-sided and this is the faster direction. The gate still **fails**, on Ir: the
`meta_map_miss` scenario moves +18,090 instructions under g++ and +1,611,257
under clang++, and Ir is compared for exact equality in both directions. Its
sensitivity is also lumpy rather than linear: 0.6 to 0.45 moves nothing at all,
because `Ceil2` rounds both to the same slot count.

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
