#!/bin/sh
# compile-matrix.sh -- compile the library headers with warnings as errors.
#
#   tests/ci/compile-matrix.sh                  # every compiler found, every std
#   tests/ci/compile-matrix.sh --cxx g++-15     # one compiler, every std
#   tests/ci/compile-matrix.sh --cxx c++ --std c++20
#
# What this gates: `tests/ci/compile_probe.cpp`, which instantiates the public
# surface of all four containers, must compile with -Wall -Wextra -Werror.
#
# What this deliberately does NOT gate: `tests/test_fph_table.cpp`. That file
# has warnings on a pristine checkout (see docs/ci.md) and cleaning it up is not
# this job's business; the test suite is built without -Werror by CMake.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CXX_LIST=""
STD_LIST=""
EXTRA_FLAGS=${FPH_CI_EXTRA_FLAGS:-}
OPT=${FPH_CI_OPT:--O2}

while [ $# -gt 0 ]; do
    case "$1" in
        --cxx) CXX_LIST="$CXX_LIST $2"; shift 2 ;;
        --std) STD_LIST="$STD_LIST $2"; shift 2 ;;
        --opt) OPT=$2; shift 2 ;;
        --extra-flags) EXTRA_FLAGS="$EXTRA_FLAGS $2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$CXX_LIST" ] || CXX_LIST=$(fph_default_compilers)
[ -n "$STD_LIST" ] || STD_LIST="c++17 c++20 c++23"

PROBE="$FPH_CI_DIR/compile_probe.cpp"
INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}

fph_info "compile matrix"
fph_info "  include : $INCLUDE"
fph_info "  probe   : $PROBE"
fph_info "  flags   : $OPT -Wall -Wextra -Werror $EXTRA_FLAGS"
fph_rule

# Which spelling of this standard does this compiler accept?
#
# An older Apple clang rejects -std=c++23 but accepts -std=c++2b, which selects
# the same language. Falling back to the draft spelling keeps the cell real
# instead of skipping it, and reporting the rejection as a library failure would
# be a lie. Tested with an empty translation unit so the answer is about the
# flag and nothing else.
resolve_std() {
    empty="$WORKDIR/empty.cpp"
    : > "$empty"
    for candidate in $2 $(std_alias "$2"); do
        if "$1" -std="$candidate" -fsyntax-only "$empty" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

std_alias() {
    case "$1" in
        c++23) printf 'c++2b\n' ;;
        c++20) printf 'c++2a\n' ;;
        c++17) printf 'c++1z\n' ;;
        *) : ;;
    esac
}

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fphmatrix.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

failures=0
skipped=0
cells=0
for cxx in $CXX_LIST; do
    if ! command -v "$cxx" >/dev/null 2>&1; then
        fph_warn "skipping $cxx: not on PATH"
        continue
    fi
    for requested in $STD_LIST; do
        if ! std=$(resolve_std "$cxx" "$requested"); then
            printf 'SKIP  %-12s %-6s  (no spelling of this standard is accepted)\n' \
                   "$cxx" "$requested"
            skipped=$((skipped + 1))
            continue
        fi
        [ "$std" = "$requested" ] || fph_note "$cxx: using -std=$std for $requested"
        cells=$((cells + 1))
        log="$WORKDIR/cc.log"
        # -Werror is what makes this a gate rather than a report. A new warning
        # from a compiler upgrade will fail the build; that is intended -- the
        # matrix pins nothing, so the warning is real.
        if $FPH_NICE "$cxx" -std="$std" $OPT -Wall -Wextra -Werror $EXTRA_FLAGS \
                -I"$INCLUDE" -c "$PROBE" -o /dev/null > "$log" 2>&1; then
            printf 'PASS  %-12s %-6s\n' "$cxx" "$std"
        else
            printf 'FAIL  %-12s %-6s\n' "$cxx" "$std"
            sed 's/^/      /' "$log" | head -40
            failures=$((failures + 1))
        fi
    done
done

fph_rule
if [ "$cells" -eq 0 ]; then
    fph_error "nothing was checked: no requested compiler/standard combination was usable"
    fph_error "($skipped combination(s) skipped). A green result here would be meaningless."
    exit 2
fi
if [ "$failures" -ne 0 ]; then
    fph_error "$failures of $cells matrix cells failed"
    exit 1
fi
if [ "$skipped" -ne 0 ]; then
    fph_info "all $cells matrix cells passed ($skipped skipped)"
else
    fph_info "all $cells matrix cells passed"
fi
