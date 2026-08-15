#!/bin/sh
# check-sizeof.sh -- the containers must stay exactly the size they are.
#
#   tests/ci/check-sizeof.sh                 # against tests/ci/baselines/sizeof.txt
#   tests/ci/check-sizeof.sh --cxx g++
#   tests/ci/check-sizeof.sh --update        # rewrite the baseline on purpose
#
# Unlike the allocation counters this is an EXACT comparison in both directions.
# Growing the table object costs every lookup a wider cache footprint; shrinking
# it means the layout was rearranged, which is exactly the kind of change that
# should be noticed and explained rather than slipped in. Either way a human
# should see it, so either way this fails and the fix is to update the baseline
# in the same commit that changes the layout.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"

CXX=${FPH_CI_CXX:-}
STD=${FPH_CI_STD:-c++17}
UPDATE=0
BASELINE="$SELF_DIR/baselines/sizeof.txt"

while [ $# -gt 0 ]; do
    case "$1" in
        --cxx) CXX=$2; shift 2 ;;
        --std) STD=$2; shift 2 ;;
        --baseline) BASELINE=$2; shift 2 ;;
        --update) UPDATE=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }

INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}
WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT INT TERM

$FPH_NICE "$CXX" -std="$STD" -O1 -Wall -Wextra -I"$INCLUDE" \
    "$SELF_DIR/sizeof_probe.cpp" -o "$WORK/sizeof_probe"
$FPH_NICE "$WORK/sizeof_probe" | LC_ALL=C sort > "$WORK/measured.txt"

if [ "$UPDATE" = "1" ]; then
    mkdir -p "$(dirname "$BASELINE")"
    cp "$WORK/measured.txt" "$BASELINE"
    fph_info "wrote $BASELINE ($(wc -l < "$BASELINE" | tr -d ' ') records, measured with $CXX $STD)"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    fph_error "no baseline at $BASELINE; create it with tests/ci/update-baselines.sh"
    exit 2
fi

pointer_size=$(awk '$1 == "sizeof" && $2 == "void*" { print $3 }' "$WORK/measured.txt")
if [ "$pointer_size" != "8" ]; then
    fph_warn "pointer size is $pointer_size, not 8; the single sizeof baseline assumes LP64"
    fph_warn "skipping rather than reporting a failure that is really a porting question"
    exit 0
fi

fph_info "sizeof check: $CXX $STD, include $INCLUDE"
fph_rule
if diff -u "$BASELINE" "$WORK/measured.txt" > "$WORK/diff.txt"; then
    fph_info "all $(wc -l < "$BASELINE" | tr -d ' ') records match the baseline"
    exit 0
fi

sed 's/^/  /' "$WORK/diff.txt"
fph_rule
fph_error "container sizes differ from tests/ci/baselines/sizeof.txt"
fph_error "growing the table object slows every lookup; shrinking it means the layout moved."
fph_error "if the change is intended, record it in the same commit:"
fph_error "  tests/ci/update-baselines.sh --sizeof"
exit 1
