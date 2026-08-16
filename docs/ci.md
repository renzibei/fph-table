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
| pull request opened, updated, reopened | yes | yes, gating |
| pull request labelled or unlabelled | no | yes, gating |
| push to `master` | yes | yes; `asm`, `counters` and `callgrind` report, `sizeof` gates |
| manual run (`workflow_dispatch`) on `master` | yes | as a push to `master` |
| manual run on a branch | yes | yes, gating |
| nightly, 03:17 UTC | yes | no |

`lookup-guard` runs on label changes because that is how a gate is signed off.
Adding the label starts a new run that sees it; re-running the failed one
replays the payload it already had.

A manual run on `master` counts as a push. The commit has already landed, so
there is nothing left to hold back, and the run carries no pull request and so
no label; gating it would leave it red on a difference that was signed off
before it merged, with no way to say so.

The base revision the comparison gates use differs per event. `sizeof` is not in
this table: it compares against a file in the tree, not against a revision.

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

For the same reason, do not type the name of the branch the run is on into the
`base` box. `actions/checkout` puts that branch at `HEAD`, so `master` on a run
on `master` names the revision being tested; the gates fail with a message
saying so rather than announcing that there was nothing to compare against. A
sha, `HEAD~1`, or an empty box all work.

## What a green check means

A check reports success only when it took its measurement and the measurement
passed. A crashed probe, a compiler that is not installed, a disassembly that
came out empty, a base tree that arrived incomplete, a counter or a scenario
that only one side reported, zero matching tests: each of those fails the job,
on every event, and no label changes that. `ctest` is passed `--no-tests=error`
for the last of them, because on its own it exits 0 when nothing matches.

Every gate that has a base side measures this revision first and the base
second, so a failure to build or run is charged to the side that caused it.
Reaching the base side first turns a broken probe or a missing compiler into
"the base predates this change", which is green on a push.

Three things finish green without a measurement, and each says so in a warning
annotation and a line in the job summary:

- A push whose predecessor does not exist — the first push of a branch. The
  head side is still built first, so this is green only when the gate is
  otherwise working.
- A pull request whose probe builds against this revision but not against the
  base revision, once it carries that gate's label. See "Adding public API".
- A push whose predecessor cannot build the probe, which is what merging such a
  pull request looks like: the base is then the `master` before the merge, and
  by definition it does not have the new API.

Runs of `lookup-guard` on a commit that has already landed — a push to `master`,
or a manual run on `master` — report rather than gate. Such a run carries no
pull request and so no labels, so a measured difference is a warning annotation
and the job stays green; otherwise every merge of a signed-off pull request
would turn `master` red. This covers a measured difference and nothing else.
Everything in the first paragraph above still fails there.

`sizeof` is the exception: it gates on every event, including a push. It
compares against `tests/ci/baselines/sizeof.txt`, which travels in the same
commit as the change that moves it, so the push that merges a recorded change
compares the new sizes against the new file and passes. There is no state in
which reporting rather than gating would save it, and nothing for a label to
rescue.

## Method

Nothing is timed. A shared runner cannot resolve the differences this library
cares about, so every gate produces exact integers instead.

Three of the four gates compare against no recorded number. `asm`, `counters`
and `callgrind` build the base revision in the same job with the same compiler
and compare against that, so a runner image or compiler upgrade moves both sides
at once and cannot fail a pull request that changed nothing. They have no
choice: their numbers depend on the standard library and the compiler version,
so there is nothing to write down.

`sizeof` does compare against a recorded file. Struct sizes hold across LP64
targets and across compilers, so they can be written down, and a file states
what the sizes are rather than only that they did not move since yesterday.

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
to compile that probe. No comparison is possible. The gate reaches this only
after the same probe has built and run against this revision, so what it names
is a difference between the two trees and not a broken probe or a broken
runner. It says which side failed to build and stops with exit 2. Two ways
forward:

- Land the API first, and add the probe's use of it in a later pull request.
  The gate then measures both.
- Add that gate's label. The gate announces that it did not run and finishes
  green, and the label records that the run measured nothing.

The push that merges such a pull request hits the same wall, because its base
is the `master` before the merge. There it is a warning and the job stays green,
for the same reason every other difference on an already-landed commit is.

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
directions. The recorded sizes hold on every LP64 target tried — 41 of 41
records agree between Linux x86-64 and macOS arm64 today — so there is one file
rather than one per platform.

```sh
tests/ci/update-baselines.sh --sizeof
```

This gate has no label and no `--allow-change`, and it gates on a push as well
as on a pull request. Both follow from comparing against a file in the tree
rather than against another revision. Rewriting the file needs the same write
access a label needs and is visible in the diff, and because the file travels in
the commit that changes the sizes, the push that merges it compares the new
sizes against the new file and passes.

If a platform ever disagrees while the others still hold, the answer is a
baseline of its own rather than a way to wave the difference through:
`check-sizeof.sh --baseline FILE --update` records one, and the same
`--baseline` goes on that platform's cell in `lookup-guard.yml`. Until that
happens there is one file, and `fph_platform_tag` in `lib.sh` names a platform
for the `--print` headers rather than choosing a baseline.

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
the check fails with exit 2 rather than treating it as new. That is a failure to
measure and not a difference, so no label and no already-landed commit turns it
green. The callgrind gate treats a scenario reported by one side the same way.

The probe serves every allocation from a fixed 512 MiB arena, which is what
makes the counts reproducible; it is `.bss`, so untouched pages cost nothing.
A change that makes the parameter search restart far more often can use it up,
and the probe then stops with `arena exhausted`. If a change needs more, raise
`kArenaBytes` in `tests/ci/counter_probe.cpp` in the same commit. It cannot grow
much further: 2 GiB of `.bss` does not link under the default code model.

How much one run consumes was measured by raising `DEFAULT_MAX_LOAD_FACTOR` in
the headers, printing the arena's bump pointer after the last workload, and
building the probe the way the gate builds it (`-std=c++17 -O2 -DNDEBUG`):

| default `max_load_factor` | Linux, libstdc++ | macOS, libc++ |
| --- | --- | --- |
| 0.6, unmodified | 12.7 MiB | 12.7 MiB |
| 0.9, `dynamic_fph_table.h` only | 34.8 MiB | 30.6 MiB |
| 0.9, both headers | 56.9 MiB | 48.4 MiB |
| 0.97, `dynamic_fph_table.h` only | 143.5 MiB | 120.2 MiB |
| 0.97, both headers | 274.2 MiB | 227.7 MiB |

The Linux column is identical to the byte under gcc 13 and clang 18; libc++
runs lower on the same edits, because the parameter search draws from
`std::uniform_int_distribution` and the two libraries answer it differently.
That difference is why the arena is 512 MiB and not the 128 MiB it replaced: at
0.97 in `dynamic_fph_table.h` alone, 128 MiB is exhausted on Linux and not on
macOS, so the same change would have failed the Linux cells only.

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
ctest --test-dir build --output-on-failure --no-tests=error
```

| test | labels |
| --- | --- |
| `fph_api_smoke` | `correctness` |
| `bits_array` | `correctness` |
| `sample_fph` | `correctness` |
| `fph_table_correctness` | `correctness`, `slow` |

`ctest -L correctness`, `-LE slow` and `-R <name>` work as usual.

`--no-tests=error` is there because without it `ctest` exits 0 when it has
nothing to run. Measured on cmake 3.28.3, which is what the `ubuntu-24.04` image
carries, and on 4.2.1: a build with no registered test prints `No tests were
found!!!` and exits 0, and `-R` and `-L` with a selector that matches nothing do
the same. Deleting every `add_test` from `tests/CMakeLists.txt` left the job
green. With the flag each of those exits 8. A cmake old enough not to know the
flag rejects it outright; there, `ctest -N` lists what a run would have done.

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
