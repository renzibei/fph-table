# Contributing

Lookup performance comes first. `find()`, `count()`, `contains()`,
`GetSlotPos()`, `GetPointerNoCheck()`, the const `operator[]`, the index-map
policies and the layout of the table object are the hot path, and a change that
makes any of them slower is not accepted because it is otherwise correct.

Both `include/fph/dynamic_fph_table.h` and `include/fph/meta_fph_table.h`
implement the same table twice. A fix usually belongs in both.

## What the checks decide

Every job in `ci` and `lookup-guard` gates a pull request: the compile matrix,
`ctest`, the sanitizers, and the four comparison gates — lookup asm, `sizeof`,
the construction and geometry counters, and callgrind.

The four comparison gates each compare this revision against the merge base,
built in the same job with the same compiler, and each produces exact integers,
so a difference is a real change and not a bad minute on the runner.

A red check from one of the four means it measured a difference. Either the
change goes back out, or it is signed off: add the label that the failure
message names, and say in the pull request why the new cost is the right trade.
Adding the label starts a new run. Each label waives one gate, adding one needs
write access, and a waived gate carries a warning annotation and a line in the
job summary. Do not disable a check.

`sizeof` has no label. It compares against `tests/ci/baselines/sizeof.txt`, and
a deliberate change is recorded by rewriting that file in the same commit:

```sh
tests/ci/update-baselines.sh --sizeof
```

The same workflows also run on pushes to `master`. Those runs compare against
the pushed commit's predecessor, and the commit has already landed, so
`lookup-guard` reports rather than gates there — a difference becomes a warning
annotation instead of a red check. On the first push of a branch there is
nothing to compare against; the gates say so and measure nothing.

`docs/ci.md` says what each check gates, which events run it, and what to do
about a pull request that adds public API a probe uses.

## Before opening a pull request

```sh
tests/ci/compile-matrix.sh
tests/ci/check-asm.sh
tests/ci/check-sizeof.sh
tests/ci/check-counters.sh
tests/ci/check-callgrind.sh --skip-unsupported   # measures on Linux with valgrind
cmake -S tests -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

`check-callgrind.sh` needs Linux and valgrind. `--skip-unsupported` makes it
finish with a warning anywhere else instead of exiting 2; the Linux runners
still measure it.

A fix wants a test that fails before it and passes after. Tests go in
`tests/test_fph_table.cpp` or a new file registered in `tests/CMakeLists.txt`.
