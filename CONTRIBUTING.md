# Contributing

Lookup performance comes first. `find()`, `count()`, `contains()`,
`GetSlotPos()`, `GetPointerNoCheck()`, the const `operator[]`, the index-map
policies and the layout of the table object are the hot path, and a change that
makes any of them slower is not accepted because it is otherwise correct.

Both `include/fph/dynamic_fph_table.h` and `include/fph/meta_fph_table.h`
implement the same table twice. A fix usually belongs in both.

## What the checks decide

Four checks are deterministic: lookup asm, `sizeof`, the construction and
geometry counters, and callgrind. Each compares this revision against the pull
request's base revision built in the same job, and each produces exact integers,
so a difference is a real change and not a bad minute on the runner.

If one of them fails, either the change goes back out or it is signed off in the
same branch: add the label the failure message names, or put its marker in a
commit message, and say in the pull request why the new cost is the right trade.
Both leave a record on the pull request. Do not disable a check.

The timing report is not one of these. It cannot fail a build and it is not on
its own a reason to hold a pull request: wall clock on a shared runner cannot
resolve the differences this library cares about. The report prints the noise it
measured during that run and the threshold that implies, so a figure can be
checked. If one looks real, reproduce it on a quiet machine before acting.

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
