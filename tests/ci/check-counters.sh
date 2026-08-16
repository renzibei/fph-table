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
        if grep -q 'arena exhausted' "$WORK/probe.err"; then
            fph_error "the probe serves every allocation from a fixed arena, which is what makes"
            fph_error "the counts reproducible. A change that makes the parameter search restart"
            fph_error "far more often can use it up. Raise kArenaBytes in tests/ci/counter_probe.cpp"
            fph_error "in the same commit, and say in the pull request what made the search harder."
        fi
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
    # name it is not a reason to fail the gate, and it is not an error either:
    # it is said here, in the header line, where the numbers it qualifies are.
    TAG=$(fph_toolchain_tag "$CXX") ||
        TAG="unidentified ($CXX did not report its predefined macros)"
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

# One probe source builds both sides, so a counter reported by one of them and
# not the other is a counter nothing was able to compare.
#
# It is NOT a run that stopped early. Both sides have already been through
# measure(), which requires the probe's own `probe_complete 1` last line, so by
# the time the join runs neither side can be truncated. What is left is a probe
# whose text compiles differently against the two include trees -- an #ifdef on
# a macro the new API defines, which is the considerate way to probe new API
# because it keeps the base compiling.
#
# That used to leave through an unwaivable exit 2, and the asymmetry it created
# rewarded the cruder change. Measured, one pull request adding a counter behind
# `#ifdef FPH_HAS_...` and another adding the same counter unconditionally:
#
#   probe change            PR, no label   PR + label   push to master
#   guarded by #ifdef            2              2             2
#   used unconditionally         2              0             0
#
# The unconditional one stops the base compiling, which fph_base_side_unbuildable
# already treats as a signable "nothing could be compared". Both are the same
# situation -- this revision has API the base does not -- so both are signed off
# the same way, with this gate's label, and both report rather than gate on the
# push that merges them.
#
# What stays unwaivable is the floor: if NO counter compared, there is no
# measurement at all, and no label or already-landed commit turns that into one.
# The counters that did compare are still gated on for regressions.
#
# exit 0 clean, 1 regressed, 3 one-sided, 4 both, 2 nothing compared at all.
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
    exit (na + nr > 0 ? 3 : 0) + (nw > 0 ? 1 : 0)
}
' "$WORK/joined.txt" > "$WORK/report.txt" && status=0 || status=$?

cat "$WORK/report.txt"
fph_rule

ONE_SIDED=0
REGRESSED=0
case "$status" in
    0) ;;
    1) REGRESSED=1 ;;
    3) ONE_SIDED=1 ;;
    4) ONE_SIDED=1; REGRESSED=1 ;;
    2) fph_error "the two sides have no counter in common; nothing was compared"
       exit 2 ;;
    *) fph_error "the comparison could not be read (awk exited $status)"
       exit 2 ;;
esac

# Counters only one side reported. Both probes ran to their last line, so this
# is a probe that compiles differently against the two trees, not a short run.
if [ "$ONE_SIDED" -eq 1 ]; then
    if reason=$(fph_gate_waived "$LABEL"); then
        fph_announce warning "$GATE: some counters were not compared" \
            "the probe reports counters against this revision that it does not report against $REFERENCE_LABEL, so those were not compared. Signed off by $reason. The list is in the log."
    elif fph_report_only; then
        fph_announce warning "$GATE: some counters were not compared" \
            "the probe reports counters against this revision that it does not report against $REFERENCE_LABEL, so those were not compared. This run reports an already-landed commit, and the base predates the change."
    else
        fph_error "a counter was reported by one side and not the other"
        fph_error "both probes ran to their last line, so this is not a run that stopped early: it"
        fph_error "is a probe that compiles differently against the two include trees, which is what"
        fph_error "an #ifdef on a macro this revision's API defines looks like. Those counters were"
        fph_error "not compared. Either:"
        fph_error "  * land the API first and add the probe's counters in a later pull request, or"
        fph_error "  * say that they cannot be compared yet, with the $LABEL label"
        fph_error "  * tests/ci/check-counters.sh --allow-change   (locally)"
        exit 2
    fi
fi

if [ "$REGRESSED" -eq 1 ]; then
    if reason=$(fph_gate_waived "$LABEL"); then
        fph_announce warning "$GATE waived" \
            "construction got more expensive under $CXX and was signed off by $reason. The numbers are in the log."
        exit 0
    fi

    if fph_report_only; then
        fph_announce warning "$GATE: reported, not gated" \
            "construction got more expensive under $CXX. This run reports a commit that has already landed, so it does not gate. The numbers are in the log."
        exit 0
    fi

    fph_error "construction got more expensive than $REFERENCE_LABEL"
    fph_error "these are exact counts, not timings: an increase is real, not noise."
    fph_error "if it is the intended price of a fix, sign it off with:"
    fph_error "  * the pull request label  $LABEL   -- adding it starts a new run"
    fph_error "  * tests/ci/check-counters.sh --allow-change   (locally)"
    exit 1
fi

if [ "$ONE_SIDED" -eq 0 ]; then
    fph_info "no counter got worse"
fi
exit 0
