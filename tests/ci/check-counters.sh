#!/bin/sh
# check-counters.sh -- construction must not get more expensive.
# See docs/ci.md for what this gates and why.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

GATE="construction counters"
LABEL=allow-construction-cost-increase

usage() {
    cat <<'EOF'
check-counters.sh -- construction must not get more expensive.

  tests/ci/check-counters.sh                    # head vs the merge base
  tests/ci/check-counters.sh --base master --cxx g++
  tests/ci/check-counters.sh --base-include DIR # compare against a tree on disk
  tests/ci/check-counters.sh --print            # just show the numbers
  tests/ci/check-counters.sh --allow-change     # sign off an increase

Both sides are built here, with this compiler, from tests/ci/counter_probe.cpp.
The comparison is head <= base, so allocating less or copying fewer keys passes
with nothing to update; only an increase fails.

The counts are not portable -- the library's parameter search draws from
std::uniform_int_distribution, so libstdc++ and libc++ disagree and so do two
gcc versions. That is why the reference is a revision built in this job and
never a number recorded elsewhere.

Signing off an increase needs the allow-construction-cost-increase pull request
label, or --allow-change locally.
EOF
}

BASE_REF=""
BASE_INCLUDE=""
CXX=${FPH_CI_CXX:-}
PRINT_ONLY=0
ALLOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF=$2; shift 2 ;;
        --base-include) BASE_INCLUDE=$2; shift 2 ;;
        --cxx) CXX=$2; shift 2 ;;
        --print) PRINT_ONLY=1; shift ;;
        --allow-change) ALLOW=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }
[ "$ALLOW" = "1" ] && FPH_CI_ALLOW_CHANGE=1
export FPH_CI_ALLOW_CHANGE=${FPH_CI_ALLOW_CHANGE:-0}

# Pinned on purpose: the counts depend on the optimisation level and on NDEBUG,
# so the configuration is part of the measurement, not a caller's choice.
BUILD_STD=c++17
BUILD_FLAGS="-O2 -DNDEBUG"

INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}
WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT
trap 'rm -rf "$WORK"; exit 143' TERM

measure() { # <side> <include-dir> <out-file>
    side=$1; shift
    $FPH_NICE "$CXX" -std="$BUILD_STD" $BUILD_FLAGS -Wall -Wextra \
        -I"$1" "$SELF_DIR/counter_probe.cpp" -o "$WORK/probe" >"$WORK/build.log" 2>&1 || {
            sed 's/^/  /' "$WORK/build.log" | head -30
            if [ "$side" = base ]; then
                fph_base_side_unbuildable "$GATE" "$LABEL" "$REFERENCE_LABEL"
            fi
            fph_error "the counter probe does not build against this revision ($1)"
            exit 2
        }
    # Not a pipeline: `probe | sort` reports sort's status, so a probe that
    # exits 2 half way through -- exhausting its arena, say -- would hand the
    # comparison a short file and a zero. The workloads it never reached would
    # then be absent from BOTH sides and compare equal.
    set +e
    $FPH_NICE "$WORK/probe" > "$WORK/raw.txt" 2>"$WORK/probe.err"
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 0 ]; then
        fph_error "the counter probe built against $1 exited $probe_status"
        fph_error "it emitted $(wc -l < "$WORK/raw.txt" | tr -d ' ') of its counters; the rest were not measured"
        sed 's/^/  /' "$WORK/probe.err" | head -10
        exit 2
    fi
    cat "$WORK/probe.err" >&2
    if ! grep -q '^probe_complete 1$' "$WORK/raw.txt"; then
        fph_error "the counter probe built against $1 stopped before its last workload"
        exit 2
    fi
    grep -v '^probe_complete 1$' "$WORK/raw.txt" | LC_ALL=C sort > "$2"
}

measure head "$INCLUDE" "$WORK/head.txt"

if [ "$PRINT_ONLY" = "1" ]; then
    # Only --print uses the toolchain tag, and a compiler that will not report
    # its predefined macros still compiles and still counts. Not being able to
    # name it is not a reason to fail the gate.
    TAG=$(fph_toolchain_tag "$CXX") || TAG="unidentified toolchain"
    fph_info "# toolchain: $TAG"
    fph_info "# flags: $BUILD_STD $BUILD_FLAGS"
    cat "$WORK/head.txt"
    exit 0
fi

if [ -z "$BASE_INCLUDE" ]; then
    set +e
    BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); resolved=$?
    set -e
    case "$resolved" in
        0) ;;
        3) fph_no_base "$GATE"; exit 0 ;;
        *) fph_error "cannot work out what to compare against; pass --base or --base-include"
           exit 2 ;;
    esac
    fph_materialise_base "$BASE_REF" "$WORK/base" || exit 2
    BASE_INCLUDE="$WORK/base/include"
    REFERENCE_LABEL="revision $BASE_REF"
else
    [ -d "$BASE_INCLUDE" ] || { fph_error "no such include tree: $BASE_INCLUDE"; exit 2; }
    REFERENCE_LABEL="include tree $BASE_INCLUDE"
fi
measure base "$BASE_INCLUDE" "$WORK/ref.txt"

fph_info "construction cost: $CXX ($BUILD_STD $BUILD_FLAGS)"
fph_info "  head      : $INCLUDE"
fph_info "  reference : $REFERENCE_LABEL"
fph_rule

LC_ALL=C join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$WORK/ref.txt" "$WORK/head.txt" \
    > "$WORK/joined.txt"

# One probe source builds both sides, so the two must report the same counters.
# A counter on one side only means one of the runs is incomplete, not that the
# workload is new, and an ungated counter is one nothing is watching.
awk '
{
    name = $1; ref = $2; head = $3
    if (ref == "MISSING") { added[++na] = name "  (head only, value " head ")"; next }
    if (head == "MISSING") { removed[++nr] = name "  (base only, value " ref ")"; next }
    if (head + 0 > ref + 0) {
        worse[++nw] = sprintf("  %-44s %10d -> %10d  %+d", name, ref, head, head - ref)
    } else if (head + 0 < ref + 0) {
        better[++nb] = sprintf("  %-44s %10d -> %10d  %+d", name, ref, head, head - ref)
    } else {
        same++
    }
}
END {
    if (nb) { print "improved:"; for (i = 1; i <= nb; i++) print better[i] }
    if (nw) { print "REGRESSED:"; for (i = 1; i <= nw; i++) print worse[i] }
    if (na) { print "counters only one side reported:"; for (i = 1; i <= na; i++) print "  " added[i] }
    if (nr) { print "counters only one side reported:"; for (i = 1; i <= nr; i++) print "  " removed[i] }
    printf "%d unchanged, %d improved, %d regressed, %d reported by one side only\n",
           same, nb + 0, nw + 0, na + nr + 0
    if (same + nb + nw == 0) { print "no counter was compared at all"; exit 2 }
    exit (nw + nr + na) > 0 ? 1 : 0
}
' "$WORK/joined.txt" > "$WORK/report.txt" && status=0 || status=$?

cat "$WORK/report.txt"
fph_rule

if [ "$status" -eq 0 ]; then
    fph_info "no counter got worse"
    exit 0
fi
if [ "$status" -eq 2 ]; then
    fph_error "the two sides have no counter in common; nothing was compared"
    exit 2
fi

if reason=$(fph_gate_waived "$LABEL"); then
    fph_announce warning "$GATE waived" \
        "construction got more expensive under $CXX and was signed off by $reason. The numbers are in the log."
    exit 0
fi

if fph_report_only; then
    fph_announce warning "$GATE: reported, not gated" \
        "construction got more expensive under $CXX. This run was triggered by a push, so the commit has already landed. The numbers are in the log."
    exit 0
fi

fph_error "construction got more expensive than $REFERENCE_LABEL"
fph_error "these are exact counts, not timings: an increase is real, not noise."
fph_error "if it is the intended price of a fix, sign it off with:"
fph_error "  * the pull request label  $LABEL   -- adding it starts a new run"
fph_error "  * tests/ci/check-counters.sh --allow-change   (locally)"
exit 1
