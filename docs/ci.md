# Continuous integration

Everything CI does is a shell script in `tests/ci/`. The workflow files under
`.github/workflows/` only choose a runner and pass a compiler name, so any
failure can be reproduced locally without pushing a commit:

```sh
tests/ci/compile-matrix.sh          # what the compile jobs run
tests/ci/check-asm.sh               # what the lookup-asm jobs run
tests/ci/check-sizeof.sh            # what the sizeof jobs run
tests/ci/check-counters.sh          # what the counters jobs run
tests/ci/perf-report.sh             # what the timing report runs
cmake -S tests -B build && cmake --build build && ctest --test-dir build
```

Every script takes `--help`.

## Why the gates are what they are

This library's first priority is lookup performance, and a GitHub-hosted runner
cannot measure lookup performance. The noise floor measured for this project is
0.15-0.76% on a dedicated pinned machine and 5.7-10.6% at p95 (with excursions
past 70%) on a merely busy one; a shared virtual machine is worse than the busy
one. Any timing threshold tight enough to catch a real 3% regression would fire
constantly on nothing.

So nothing is gated on wall-clock. What is gated is machine code, struct sizes
and exact operation counts, all of which are integers that do not care how busy
the runner is. Timings are still published, as a report that cannot fail, with
the machine's own noise floor printed next to every figure.

## What each job gates

| job | gates | fails when |
| --- | --- | --- |
| `ci / compile` | `tests/ci/compile_probe.cpp` against the headers, `-Wall -Wextra -Werror` | a warning or error on any compiler/standard |
| `ci / ctest` | the randomized correctness suite, the bit-array test, the sample, the API smoke test | a test exits non-zero, times out, or logs an `Error` line |
| `ci / asan+ubsan` | the same ctest set under AddressSanitizer and UndefinedBehaviorSanitizer, `-fno-sanitize-recover=all` | any sanitizer report |
| `lookup-guard / lookup asm` | the disassembly of the lookup symbols | the lookup path gets longer or changes shape |
| `lookup-guard / sizeof` | `sizeof`/`alignof` of every container and iterator | any size changes, in either direction |
| `lookup-guard / counters` | allocations, bytes, peak footprint, key copies/moves for fixed workloads | any of them increases |
| `lookup-guard / timing report` | nothing | never; it only publishes numbers |

The compile matrix covers gcc and clang, C++17/20/23, on Linux x86-64, Linux
arm64 and macOS arm64. The arm64 Linux cells are marked experimental until one
run is seen green on that runner label; they are worth having because one known
defect in this library passes on arm64/clang and crashes on x86-64/gcc.

## The lookup disassembly gate

`tests/ci/check-asm.sh` builds `tests/ci/asm_probe.cpp` — which pins the lookup
path down as standalone symbols — against **this revision and the pull request's
base revision, in the same job, with the same compiler**, and compares the two
symbol by symbol.

There is deliberately no checked-in disassembly baseline. A baseline recorded on
one compiler goes stale the moment the runner image changes, and would then fail
pull requests that changed nothing. Building both sides in the same job means a
compiler upgrade moves both and cancels out.

Verdicts:

* **identical** — passes silently.
* **every difference is shorter** — passes, and prints how much shorter. Making
  lookup cheaper needs no permission.
* **anything else** — fails, and prints the instruction-level diff.

To accept a deliberate change, one of:

* add the `allow-lookup-asm-change` label to the pull request;
* put `[allow-asm-change]` in a commit message on the branch;
* locally, `tests/ci/check-asm.sh --allow-change`.

The diff is still printed when it is overridden, so the accepted change is on
the record.

Two normalisations are applied on top of `asmdump.sh`: nop padding is dropped
(objdump attributes a function's alignment padding to the function before it, so
without this, shortening one symbol rewrites the tail of its neighbour), and the
residual absolute addresses in objdump's `# 212 <sym+0x..>` comments are
normalised away. Both were false-failure sources on x86-64/gcc.

## The sizeof gate

`tests/ci/check-sizeof.sh` compares against `tests/ci/baselines/sizeof.txt` for
exact equality. Growing the table object costs every lookup a wider footprint;
shrinking it means the layout was rearranged. Both deserve a human, so both
fail.

The measured sizes are identical on every LP64 target tried (linux-x86_64 and
darwin-arm64, gcc and clang), so there is one file rather than one per platform.
The probe prints `sizeof void*` and the check declines to run rather than report
a false failure if it is not 8.

To move it on purpose:

```sh
tests/ci/update-baselines.sh --sizeof
git diff -- tests/ci/baselines/sizeof.txt     # commit this with the change
```

## The construction-cost gate

`tests/ci/check-counters.sh` runs fixed workloads and counts allocations, bytes
requested, peak footprint, bytes still outstanding at the end, and key
value-constructions, copies, moves and assignments. Every one is compared as an
**upper bound**: `head <= reference`. An improvement passes with nothing to
update; only an increase fails.

By default the reference is the pull request's base revision, built in the same
job with the same compiler, for the same reason as the asm gate.

To accept a deliberate increase — a fix that costs an allocation is a perfectly
reasonable thing to land — use the `allow-cost-increase` label, or
`[allow-cost-increase]` in a commit message, or `--allow-change` locally.

### Two things worth knowing about these numbers

**They are not portable.** The library's parameter search draws from
`std::uniform_int_distribution`, whose sequence is not specified across
implementations. Measured: gcc 13 and clang 18 on the same Linux box agree
exactly; macOS/libc++ and Linux/libstdc++ do not; gcc 13 and gcc 15 do not.
That is why CI compares against the base revision rather than a recorded number,
and why the recorded files under `tests/ci/baselines/` are tagged with the
toolchain they came from and skipped when the tag does not match.

**Construction depends on heap addresses.** With an ordinary `malloc`, 100
consecutive runs of the counter probe produced 100 different results, with a
spread of up to 66% on one allocation counter. The same binary under
`setarch -R`, with address space randomisation disabled, produced identical
results every time. Something in the build path therefore depends on where the
allocator happens to place things. `tests/ci/counter_probe.cpp` serves every
allocation from a bump arena so that the layout is a pure function of the
allocation sequence, which makes the whole program reproducible — 15/15
identical runs with ASLR still on. This is a real property of the library and
worth chasing down; the probe merely removes it from the measurement, because a
gate that is 66% noisy is not a gate.

To record the current numbers for your toolchain:

```sh
tests/ci/update-baselines.sh --counters
```

Or both at once: `tests/ci/update-baselines.sh`.

## The timing report

`tests/ci/perf-report.sh` times three arms, not two: the base revision, this
revision, and a **byte-identical copy of this revision's binary**. The third one
differs from the second by nothing at all, so the difference between them is a
direct measurement of the runner's noise floor during that very run. It is
printed in the `noise` column next to every figure.

A `head/base` delta is only called "worth a look" when it exceeds several times
that measured floor. Nothing in the report can fail a build. If a number there
looks alarming, the thing to do is reproduce it on a quiet machine, not to argue
about the CI run.

## Running the tests

```sh
cmake -S tests -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

Registered tests:

| test | what it is | labels |
| --- | --- | --- |
| `fph_api_smoke` | instantiates and exercises the public API of all four containers | `correctness` |
| `bits_array` | the bit-array unit test | `correctness` |
| `sample_fph` | the README example | `correctness` |
| `fph_table_correctness` | the randomized differential suite against `std::unordered_*` | `correctness`, `slow` |

The minutes-long benchmark is not registered by default; configure with
`-DFPH_ENABLE_BENCHMARK_TEST=ON` to add it as `fph_table_benchmark`.

`ctest -L correctness`, `ctest -LE slow` and `ctest -R <name>` all work.

### A caveat about `fph_table_correctness` on this revision

`tests/test_fph_table.cpp` reports a failure by logging it in red and carrying
on; the process exit status is 0 whatever happens. Matching the escape sequence
`LogHelper` emits for `Error` (`FAIL_REGULAR_EXPRESSION` in
`tests/CMakeLists.txt`) turns those reports into a real ctest failure without
editing the suite. Ordinary output never contains that sequence.

### Slow cases and the retry budget

The library's parameter search has a retry budget of 10 x 10 x 1000 x 1000, so a
case that is meant to exhaust it takes tens of seconds to minutes. Configure
with `-DFPH_TEST_RETRY_BUDGET=<n>` to hand tests a reduced budget: it is passed
to the test targets both as the macro `FPH_TEST_RETRY_BUDGET` and in the
environment of every registered test. `0`, the default, leaves the library's
defaults alone. `Build()` takes `max_try_seed2_time` and `max_reseed2_time`
arguments, which is where a reduced budget goes.

## Adding a test

Adding a case to `tests/CMakeLists.txt` is all that is required; no workflow
file needs to change.

```cmake
add_executable(my_test my_test.cpp)
target_link_libraries(my_test fph::fph_table)
add_test(NAME my_test COMMAND my_test)
set_tests_properties(my_test PROPERTIES LABELS correctness TIMEOUT 600)
```

## What is not covered yet

* `tests/test_fph_table.cpp` itself is built without `-Werror`: it has 6
  warnings under clang (`-Wunused-but-set-variable`) and 13 under gcc (which
  adds `-Wdangling-reference`) on a pristine checkout. The library headers are
  clean and are the thing `-Werror` is pointed at.
* `FPH_ENABLE_ITERATOR=0` and `FPH_DY_DUAL_BUCKET_SET=1` are documented
  configurations that do not compile, so they are not in the matrix.
* MSVC. See below.
* The correctness suite's own pass/fail reporting: see the caveat above.

## MSVC

The library advertises C++17 portability and has never been compiled with MSVC.
It is not in the matrix because it does not build there yet, and adding a job
that is red on day one defeats the purpose of having a green master.

What it would take, from reading the headers:

* `__builtin_clzll`, `__builtin_expect`, `__builtin_prefetch` and
  `__attribute__((always_inline))` all need MSVC equivalents
  (`_BitScanReverse64`, no-op, `_mm_prefetch`, `__forceinline`). The headers
  already have `FPH_HAVE_BUILTIN` / `FPH_ALWAYS_INLINE` / `FPH_PREFETCH` macros,
  so the work is in one place rather than scattered.
* `__uint128_t` has no MSVC equivalent; the multiply-high paths need
  `_umul128`/`__umulh`.
* `#pragma GCC` / `#pragma clang` diagnostics need guarding.
* `tests/ci/compile_probe.cpp` is already written in portable standard C++17
  with no GNU extensions, so it is the natural first target: get that to compile
  under `windows-2022` with `/std:c++17 /W4 /WX` before attempting the test
  suite, which uses `__attribute__` and POSIX-flavoured printf formats.

A `windows-2022` runner is free for public repositories, so the only cost is the
porting work.
