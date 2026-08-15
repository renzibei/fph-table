#!/bin/sh
# check-counters.sh -- construction must not get more expensive.
#
#   tests/ci/check-counters.sh                       # head vs merge base
#   tests/ci/check-counters.sh --base master
#   tests/ci/check-counters.sh --baseline tests/ci/baselines/counters-<tag>.txt
#   tests/ci/check-counters.sh --print                # just show the numbers
#   tests/ci/check-counters.sh --allow-change         # sign off an increase
#
# The comparison is always "head <= reference", never equality, so making the
# library allocate less or copy fewer keys passes without anyone touching a
# baseline. Only an increase fails.
#
# Two reference modes, because they answer different questions:
#
#   --base <ref>       (the default, and what CI uses)
#       Builds the reference revision's headers with the SAME compiler in the
#       SAME job. This is the reliable one. Measured fact: these counts are not
#       portable -- the library's parameter search draws from
#       std::uniform_int_distribution, so libstdc++ and libc++ disagree, and
#       even gcc 13 and gcc 15 disagree. Comparing a revision against a number
#       measured on someone else's machine would produce false failures.
#
#   --baseline <file>  (for a working tree with no useful git base)
#       Compares against a recorded file. The recorded files under
#       tests/ci/baselines/ are tagged with the toolchain they were measured
#       with; using one from a different toolchain is meaningless, so the tag
#       is checked and a mismatch is reported rather than failed.
#
# Overriding a genuine increase: --allow-change, the `allow-cost-increase` pull
# request label, or [allow-cost-increase] in a commit message.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

BASE_REF=""
BASE_INCLUDE=""
BASELINE=""
CXX=${FPH_CI_CXX:-}
PRINT_ONLY=0
UPDATE_TO=""
ALLOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF=$2; shift 2 ;;
        --base-include) BASE_INCLUDE=$2; shift 2 ;;
        --baseline) BASELINE=$2; shift 2 ;;
        --cxx) CXX=$2; shift 2 ;;
        --print) PRINT_ONLY=1; shift ;;
        --write) UPDATE_TO=$2; shift 2 ;;
        --allow-change) ALLOW=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
trap 'rm -rf "$WORK"' EXIT INT TERM

measure() { # <include-dir> <out-file>
    $FPH_NICE "$CXX" -std="$BUILD_STD" $BUILD_FLAGS -Wall -Wextra \
        -I"$1" "$SELF_DIR/counter_probe.cpp" -o "$WORK/probe" >"$WORK/build.log" 2>&1 || {
            fph_error "the counter probe does not build against $1"
            sed 's/^/  /' "$WORK/build.log" | head -30
            exit 2
        }
    $FPH_NICE "$WORK/probe" | LC_ALL=C sort > "$2"
}

# The toolchain tag identifies which recorded baseline, if any, applies here.
TAG=$(fph_toolchain_tag "$CXX")

measure "$INCLUDE" "$WORK/head.txt"

if [ "$PRINT_ONLY" = "1" ]; then
    fph_info "# toolchain: $TAG"
    fph_info "# flags: $BUILD_STD $BUILD_FLAGS"
    cat "$WORK/head.txt"
    exit 0
fi

if [ -n "$UPDATE_TO" ]; then
    mkdir -p "$(dirname "$UPDATE_TO")"
    {
        printf '# fph-table construction cost, recorded by tests/ci/update-baselines.sh\n'
        printf '# toolchain: %s\n' "$TAG"
        printf '# flags: %s %s\n' "$BUILD_STD" "$BUILD_FLAGS"
        printf '# every entry is an UPPER BOUND: the check is head <= this.\n'
        cat "$WORK/head.txt"
    } > "$UPDATE_TO"
    fph_info "wrote $UPDATE_TO"
    exit 0
fi

REFERENCE_LABEL=""
if [ -n "$BASELINE" ]; then
    [ -f "$BASELINE" ] || { fph_error "no such baseline: $BASELINE"; exit 2; }
    recorded_tag=$(awk '/^# toolchain:/ { print $3; exit }' "$BASELINE")
    if [ -n "$recorded_tag" ] && [ "$recorded_tag" != "$TAG" ]; then
        fph_warn "baseline $BASELINE was recorded with $recorded_tag, this is $TAG"
        fph_warn "these counters are not comparable across toolchains; skipping"
        fph_warn "use --base <ref> instead, which measures both sides here"
        exit 0
    fi
    grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' | LC_ALL=C sort > "$WORK/ref.txt"
    REFERENCE_LABEL="baseline $BASELINE"
else
    if [ -z "$BASE_INCLUDE" ]; then
        if ! BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); then
            fph_error "cannot work out what to compare against; pass --base or --baseline"
            exit 2
        fi
        fph_materialise_base "$BASE_REF" "$WORK/base"
        BASE_INCLUDE="$WORK/base/include"
        REFERENCE_LABEL="revision $BASE_REF"
    else
        REFERENCE_LABEL="include tree $BASE_INCLUDE"
    fi
    measure "$BASE_INCLUDE" "$WORK/ref.txt"
fi

fph_info "construction cost: $CXX ($BUILD_STD $BUILD_FLAGS)"
fph_info "  head      : $INCLUDE"
fph_info "  reference : $REFERENCE_LABEL"
fph_rule

# join(1) is in POSIX and present on both runner images; awk keeps the
# arithmetic and the report in one place.
LC_ALL=C join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$WORK/ref.txt" "$WORK/head.txt" \
    > "$WORK/joined.txt"

awk '
{
    name = $1; ref = $2; head = $3
    if (ref == "MISSING") { added[++na] = name "  (new counter, value " head ")"; next }
    if (head == "MISSING") { removed[++nr] = name; next }
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
    if (na) { print "new counters (not gated until the next run):"; for (i = 1; i <= na; i++) print "  " added[i] }
    if (nr) { print "counters that disappeared:"; for (i = 1; i <= nr; i++) print "  " removed[i] }
    printf "%d unchanged, %d improved, %d regressed, %d added, %d removed\n",
           same, nb + 0, nw + 0, na + 0, nr + 0
    exit (nw + nr) > 0 ? 1 : 0
}
' "$WORK/joined.txt" > "$WORK/report.txt" && status=0 || status=$?

cat "$WORK/report.txt"
fph_rule

if [ "$status" -eq 0 ]; then
    fph_info "no counter got worse"
    exit 0
fi

if reason=$(fph_change_allowed '[allow-cost-increase]' allow-cost-increase); then
    fph_warn "construction got more expensive and the increase is signed off (via $reason)"
    exit 0
fi

fph_error "construction got more expensive than $REFERENCE_LABEL"
fph_error "these are exact counts, not timings: an increase is real, not noise."
fph_error "if it is the intended price of a fix, sign it off with one of:"
fph_error "  * the pull request label  allow-cost-increase"
fph_error "  * [allow-cost-increase] in a commit message"
fph_error "  * tests/ci/check-counters.sh --allow-change   (locally)"
fph_error "to move a recorded baseline instead: tests/ci/update-baselines.sh --counters"
exit 1
