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
  tests/ci/check-sizeof.sh --std c++20
  tests/ci/check-sizeof.sh --baseline FILE # compare against another baseline
  tests/ci/check-sizeof.sh --update        # rewrite the baseline on purpose

An exact comparison in both directions. Growing the table object costs every
lookup a wider cache footprint; shrinking it means the layout was rearranged.
Either way the fix is to update the baseline in the commit that changes it.

This gate has no --allow-change and no label, and unlike the other three it
gates on a push as well. Both follow from what it compares against: a file in
the tree. A deliberate change is recorded by rewriting that file in the same
commit, which needs the same write access a label does and is visible in the
diff, and usually the push that merges it then compares the new sizes against
the new file and passes.

Usually, not always: two pull requests that each add a member and each rerun
update-baselines.sh record the SAME file, so git merges them without a conflict
and master ends up with both members and a baseline describing one. That push
goes red, and the fix is a follow-up commit rerunning update-baselines.sh. It
gates rather than reports because the recorded file stays wrong until it is
rewritten, so reporting would only move the red onto the next pull request.

The recorded sizes are LP64 sizes, and one file serves every platform because
every LP64 target measured agrees. A target that genuinely disagrees needs its
own baseline -- --baseline names one, and the workflow cell for that platform
passes it -- rather than a way to wave the difference through. --update holds to
that too: it will not write a measurement from a non-LP64 target into the shared
file, only into one named with --baseline.
EOF
}

CXX=${FPH_CI_CXX:-}
STD=${FPH_CI_STD:-c++17}
UPDATE=0
SHARED_BASELINE="$SELF_DIR/baselines/sizeof.txt"
BASELINE="$SHARED_BASELINE"

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

# A build failure here is a failure to measure, not a size difference. Without
# this it reaches the caller as a raw compiler error and exit 1, which is the
# same status this script uses for "the sizes moved".
$FPH_NICE "$CXX" -std="$STD" -O1 -Wall -Wextra -I"$INCLUDE" \
    "$SELF_DIR/sizeof_probe.cpp" -o "$WORK/sizeof_probe" >"$WORK/build.log" 2>&1 || {
        fph_error "the sizeof probe does not build against $INCLUDE with $CXX -std=$STD"
        sed 's/^/  /' "$WORK/build.log" | head -30
        exit 2
    }

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

# Whether these numbers are LP64 numbers is decided before anything is written
# or compared, because it is the same question either way: the shared baseline
# holds the sizes every LP64 target agrees on, and a measurement from another
# target neither belongs in it nor can be judged against it.
#
# This used to sit after --update, so --update never reached it. Reproduced with
# a stand-in for an ILP32 compiler: `check-sizeof.sh --cxx <it>` exited 2 saying
# "pointer size is 4, not 8", while `update-baselines.sh --sizeof` on the very
# same target exited 0 and rewrote the shared baseline with the 32-bit numbers,
# which would then have failed every LP64 cell in CI.
#
# Recording another target's sizes is still allowed; it just needs a file of its
# own, which is what --baseline names and what lookup-guard.yml would pass from
# that platform's cell. The destination is compared by resolved path, so another
# spelling of the shared file is still the shared file.
fph_same_file() {
    a_dir=$(dirname "$1"); a_base=$(basename "$1")
    b_dir=$(dirname "$2"); b_base=$(basename "$2")
    if a_real=$(cd "$a_dir" 2>/dev/null && pwd); then a_dir=$a_real; fi
    if b_real=$(cd "$b_dir" 2>/dev/null && pwd); then b_dir=$b_real; fi
    [ "$a_dir/$a_base" = "$b_dir/$b_base" ]
}

pointer_size=$(awk '$1 == "sizeof" && $2 == "void*" { print $3 }' "$WORK/measured.txt")
if [ -z "$pointer_size" ]; then
    fph_error "the probe did not report sizeof(void*), so its output cannot be trusted"
    exit 2
fi
if [ "$pointer_size" != "8" ] && fph_same_file "$BASELINE" "$SHARED_BASELINE"; then
    fph_error "pointer size is $pointer_size, not 8; tests/ci/baselines/sizeof.txt records LP64 sizes"
    if [ "$UPDATE" = "1" ]; then
        fph_error "writing these numbers there would replace the sizes every LP64 target agrees on"
        fph_error "with this platform's, and every LP64 cell in CI would then fail against them."
        fph_error "if this platform needs a baseline, give it one of its own and pass the same"
        fph_error "--baseline from its cell in .github/workflows/lookup-guard.yml:"
        fph_error "  tests/ci/check-sizeof.sh --baseline tests/ci/baselines/sizeof-<platform>.txt --update"
    else
        fph_error "this platform needs its own baseline before the check means anything here"
    fi
    exit 2
fi

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

fph_info "sizeof check: $CXX $STD, include $INCLUDE"
fph_rule
if diff -u "$BASELINE" "$WORK/measured.txt" > "$WORK/diff.txt"; then
    fph_info "all $(wc -l < "$BASELINE" | tr -d ' ') records match the baseline"
    exit 0
fi

sed 's/^/  /' "$WORK/diff.txt"
fph_rule
fph_error "container sizes differ from $BASELINE"
fph_error "growing the table object slows every lookup; shrinking it means the layout moved."
fph_error "if the change is intended, record it in the same commit:"
fph_error "  tests/ci/update-baselines.sh --sizeof"
fph_error "if instead this platform disagrees with the recorded LP64 sizes while the others"
fph_error "still hold, it needs a baseline of its own: record one with --baseline and pass the"
fph_error "same --baseline from that platform's cell in .github/workflows/lookup-guard.yml."
fph_error "There is no label for this gate; the recorded file is the sign-off."
exit 1
