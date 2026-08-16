#!/bin/sh
# check-sizeof.sh -- the containers must stay exactly the size they are.
# See docs/ci.md for what this gates and why.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"

usage() {
    cat <<'EOF'
check-sizeof.sh -- the containers must stay exactly the size they are.

  tests/ci/check-sizeof.sh                 # against tests/ci/baselines/sizeof.txt
  tests/ci/check-sizeof.sh --cxx g++
  tests/ci/check-sizeof.sh --update        # rewrite the baseline on purpose

An exact comparison in both directions. Growing the table object costs every
lookup a wider cache footprint; shrinking it means the layout was rearranged.
Either way the fix is to update the baseline in the commit that changes it.

The recorded sizes are LP64 sizes. On a target where they cannot hold, this
fails rather than skipping: a check that reports success without comparing
anything is worse than one that says it cannot run here.
EOF
}

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
        -h|--help) usage; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }

INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}
WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT
trap 'rm -rf "$WORK"; exit 143' TERM

$FPH_NICE "$CXX" -std="$STD" -O1 -Wall -Wextra -I"$INCLUDE" \
    "$SELF_DIR/sizeof_probe.cpp" -o "$WORK/sizeof_probe"

# Not a pipeline: `probe | sort` reports sort's status, so a probe that crashes
# part way through hands the rest of the script a truncated file and a zero.
set +e
$FPH_NICE "$WORK/sizeof_probe" > "$WORK/raw.txt" 2>"$WORK/probe.err"
probe_status=$?
set -e
if [ "$probe_status" -ne 0 ]; then
    fph_error "the sizeof probe exited $probe_status after $(wc -l < "$WORK/raw.txt" | tr -d ' ') line(s)"
    fph_error "the sizes it did not get to were not compared"
    sed 's/^/  /' "$WORK/probe.err" | head -10
    exit 2
fi
cat "$WORK/probe.err" >&2
LC_ALL=C sort "$WORK/raw.txt" > "$WORK/measured.txt"

# The probe's own last line. Its absence means the output is truncated even
# though the process managed to exit 0.
if ! grep -q '^probe_complete 1$' "$WORK/measured.txt"; then
    fph_error "the sizeof probe's output is incomplete; it did not reach the end"
    exit 2
fi
grep -v '^probe_complete 1$' "$WORK/measured.txt" > "$WORK/records.txt"
mv "$WORK/records.txt" "$WORK/measured.txt"

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
if [ -z "$pointer_size" ]; then
    fph_error "the probe did not report sizeof(void*), so its output cannot be trusted"
    exit 2
fi
if [ "$pointer_size" != "8" ]; then
    fph_error "pointer size is $pointer_size, not 8; tests/ci/baselines/sizeof.txt records LP64 sizes"
    fph_error "this platform needs its own baseline before the check means anything here"
    exit 2
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
