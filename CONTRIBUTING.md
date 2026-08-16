# Contributing

Lookup performance comes first. `find()`, `count()`, `contains()`,
`GetSlotPos()`, `GetPointerNoCheck()`, the const `operator[]`, the index-map
policies and the layout of the table object are the hot path, and a change that
makes any of them slower is not accepted because it is otherwise correct.

Both `include/fph/dynamic_fph_table.h` and `include/fph/meta_fph_table.h`
implement the same table twice. A fix usually belongs in both.

## What the checks decide

Four checks gate a pull request: lookup asm, `sizeof`, the construction and
geometry counters, and callgrind. Each compares this revision against the pull
request's base revision built in the same job, and each produces exact integers,
so a difference is a real change and not a bad minute on the runner.

A red check means one of them measured a difference. Either the change goes back
out, or it is signed off: add the label that the failure message names, and say
in the pull request why the new cost is the right trade. Each label waives one
gate, adding one needs write access, and a waived gate is annotated on the run
rather than rendered as a pass. Do not disable a check.

The same workflows also run on pushes to `master`. Those runs compare against
the pushed commit's predecessor, and the commit has already landed, so they
report rather than gate — they are what notices a direct push that should have
been a pull request. On the first push of a branch there is nothing to compare
against; the gates say so and measure nothing.

## Before opening a pull request

```sh
tests/ci/compile-matrix.sh
tests/ci/check-asm.sh
tests/ci/check-sizeof.sh
tests/ci/check-counters.sh
tests/ci/check-callgrind.sh    # Linux with valgrind installed
cmake -S tests -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

`docs/ci.md` says what each one gates and how to move a baseline on purpose.

A fix wants a test that fails before it and passes after. Tests go in
`tests/test_fph_table.cpp` or a new file registered in `tests/CMakeLists.txt`.
