#!/bin/sh
# check-callgrind.sh -- the lookup loop must execute the same instructions and
# touch no more cache lines than the base revision.
#
#   tests/ci/check-callgrind.sh                 # head vs merge base
#   tests/ci/check-callgrind.sh --base master --cxx g++
#   tests/ci/check-callgrind.sh --print         # just show the numbers
#   tests/ci/check-callgrind.sh --allow-change  # sign off a change
#
# Linux only. Valgrind has no macOS arm64 port, so this leg does not exist on
# the macOS runner and the script skips itself rather than failing there.
#
# Why this gate exists alongside check-asm.sh: the asm gate proves the machine
# code of the lookup path is unchanged, and that is not the same as proving the
# cost is unchanged. max_load_factor is a runtime parameter; changing its
# default leaves the disassembly byte-identical while moving the work the loop
# does. Measured on this library, meta_map_miss, 0.6 -> 0.9: instructions
# +0.078%, simulated D1 misses -8.61%, wall clock -9.24%. The instruction count
# is blind to that change and the D1 miss count tracks it almost exactly.
#
# The two counters are gated differently because they behave differently:
#
#   Ir   instructions executed in the loop. Measured on this repository's own
#        branches: bit-identical across repeats, and 0.0000% different across a
#        commit that changed only construction, in all ten scenario x compiler
#        cells. So it is gated at EXACT EQUALITY -- any movement is a real
#        change of code path. Note it is a detector, not an estimator: on the
#        one known lookup improvement it moved between 0.76x and 3.85x the
#        measured time change, because a wider vectorised loop counts one
#        instruction regardless of how much work it does. Do not read a
#        percentage here as a percentage of speed.
#
#   D1m  simulated first-level data cache misses. Same-binary repeats are
#        bit-identical, but the count depends on where the heap lands, so a
#        change to construction alone moved it by up to 0.011%. Gated as an
#        UPPER BOUND with 1% of headroom, which is about ninety times the
#        measured drift; a reduction passes with nothing to update.
#
# Branch simulation is deliberately off. Valgrind's predictor is a bimodal
# model from 2004 and reported 14 mispredicts per million probes on this
# workload, which is not a number about any real processor.
#
# Both sides are built here, in this job, with this compiler, for the same
# reason as every other gate: a runner or compiler change moves both at once.
#
# Overriding a deliberate change: --allow-change, the `allow-cost-increase`
# pull request label, or [allow-cost-increase] in a commit message.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

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
        -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

# Not being able to run is not a failure: this gate is one platform's leg of a
# check that also exists as check-asm.sh and the geometry counters.
if [ "$(uname -s)" != Linux ]; then
    fph_info "callgrind: $(uname -s) is not supported by valgrind; skipping"
    exit 0
fi
if ! command -v valgrind >/dev/null 2>&1; then
    fph_info "callgrind: valgrind is not installed; skipping"
    exit 0
fi

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }
[ "$ALLOW" = "1" ] && FPH_CI_ALLOW_CHANGE=1
export FPH_CI_ALLOW_CHANGE=${FPH_CI_ALLOW_CHANGE:-0}

# Pinned on purpose, all of it.
#
#   -march  never `native`: its meaning depends on which machine the job landed
#           on. Measured: the same pair of revisions differs by -8.05% at
#           x86-64-v2 and -9.15% at v3, so the level is part of the measurement.
#   --I1/--D1/--LL  or valgrind reads the host's cache geometry out of CPUID and
#           the miss counts become a property of the runner.
BUILD_STD=c++17
BUILD_FLAGS="-O2 -DNDEBUG"
case "$(uname -m)" in
    x86_64) MARCH="-march=x86-64-v2" ;;
    aarch64) MARCH="-march=armv8-a" ;;
    *) MARCH="" ;;
esac
CACHE="--I1=32768,8,64 --D1=32768,8,64 --LL=8388608,16,64"
SCENARIOS="dyn_map_hit dyn_map_miss dyn_map_find meta_map_hit meta_map_miss meta_map_find"

# Address space randomisation perturbs simulated cache misses, and valgrind
# does not neutralise it. Without setarch the D1 numbers wander between runs of
# the same binary.
SETARCH=""
if command -v setarch >/dev/null 2>&1 && setarch "$(uname -m)" -R true >/dev/null 2>&1; then
    SETARCH="setarch $(uname -m) -R"
else
    fph_warn "setarch -R is unavailable; D1 miss counts will be less stable"
fi

INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}
WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT INT TERM

build() { # <include-dir> <out>
    $FPH_NICE "$CXX" -std="$BUILD_STD" $BUILD_FLAGS $MARCH -Wall -Wextra \
        -I"$1" "$SELF_DIR/callgrind_probe.cpp" -o "$2" >"$WORK/build.log" 2>&1 || {
            fph_error "the callgrind probe does not build against $1"
            sed 's/^/  /' "$WORK/build.log" | head -30
            exit 2
        }
}

# measure <binary> <out-file> -- one line per scenario: "<name> <Ir> <D1m>".
measure() {
    : > "$2"
    for scenario in $SCENARIOS; do
        rm -f "$WORK/cg.out"
        $FPH_NICE $SETARCH valgrind --tool=callgrind \
            --instr-atstart=no --collect-atstart=no \
            --cache-sim=yes --branch-sim=no $CACHE \
            --callgrind-out-file="$WORK/cg.out" \
            "$1" "$scenario" >"$WORK/run.out" 2>"$WORK/run.err" || {
                fph_error "callgrind failed on $scenario"
                sed 's/^/  /' "$WORK/run.err" | head -20
                exit 2
            }
        if ! grep -q '^callgrind 1$' "$WORK/run.out"; then
            fph_error "the probe was built without <valgrind/callgrind.h>"
            fph_error "install the valgrind development headers, or skip this gate"
            exit 2
        fi
        # The totals line carries the events named in the header, in that order,
        # so the columns are found by name rather than by position.
        awk -v scen="$scenario" '
            /^events:/ { for (i = 2; i <= NF; i++) col[$i] = i - 1; next }
            /^(summary|totals):/ { for (i = 2; i <= NF; i++) v[i - 1] = $i + 0; got = 1 }
            END {
                if (!got || !("Ir" in col)) { exit 3 }
                ir = v[col["Ir"]]
                d1 = v[col["D1mr"]] + v[col["D1mw"]]
                if (ir <= 0) { exit 4 }
                printf "%s %d %d\n", scen, ir, d1
            }
        ' "$WORK/cg.out" >> "$2" || {
            fph_error "could not read counts for $scenario out of the callgrind output"
            fph_error "(an empty count means the collection window never opened)"
            exit 2
        }
    done
    LC_ALL=C sort -o "$2" "$2"
}

build "$INCLUDE" "$WORK/head.bin"
measure "$WORK/head.bin" "$WORK/head.txt"

TAG=$(fph_toolchain_tag "$CXX")

if [ "$PRINT_ONLY" = "1" ]; then
    fph_info "# toolchain: $TAG"
    fph_info "# flags: $BUILD_STD $BUILD_FLAGS $MARCH"
    fph_info "# cache: $CACHE"
    cat "$WORK/head.txt"
    exit 0
fi

if [ -z "$BASE_INCLUDE" ]; then
    if ! BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); then
        fph_error "cannot work out what to compare against; pass --base"
        exit 2
    fi
    fph_materialise_base "$BASE_REF" "$WORK/base"
    BASE_INCLUDE="$WORK/base/include"
    REFERENCE_LABEL="revision $BASE_REF"
else
    REFERENCE_LABEL="include tree $BASE_INCLUDE"
fi

build "$BASE_INCLUDE" "$WORK/base.bin"
measure "$WORK/base.bin" "$WORK/ref.txt"

fph_info "lookup loop cost under callgrind: $CXX ($BUILD_STD $BUILD_FLAGS $MARCH)"
fph_info "  head      : $INCLUDE"
fph_info "  reference : $REFERENCE_LABEL"
fph_info "  cache     : $CACHE"
fph_rule

LC_ALL=C join -a1 -a2 -e MISSING -o 0,1.2,1.3,2.2,2.3 "$WORK/ref.txt" "$WORK/head.txt" \
    > "$WORK/joined.txt"

# Ir at exact equality, D1m as an upper bound with headroom. A fall in Ir is not
# waved through the way a shorter disassembly is: the instruction count is a
# detector, and a smaller one is not by itself evidence of a faster lookup.
awk '
BEGIN {
    d1_headroom = 1.01
    printf "%-14s %12s %12s %10s   %12s %12s %8s\n",
           "scenario", "Ir base", "Ir head", "delta", "D1m base", "D1m head", "delta"
}
{
    name = $1
    if ($2 == "MISSING" || $4 == "MISSING") {
        printf "%-14s %s\n", name, ($2 == "MISSING" ? "(new scenario)" : "(scenario removed)")
        if ($2 != "MISSING") removed++
        next
    }
    ir_ref = $2 + 0; d1_ref = $3 + 0; ir_head = $4 + 0; d1_head = $5 + 0
    d1_delta = d1_ref > 0 ? (d1_head - d1_ref) / d1_ref * 100.0 : 0
    printf "%-14s %12d %12d %+10d   %12d %12d %+7.2f%%\n",
           name, ir_ref, ir_head, ir_head - ir_ref, d1_ref, d1_head, d1_delta
    if (ir_head != ir_ref) ir_changed++
    if (d1_head > d1_ref * d1_headroom) d1_worse++
}
END {
    printf "\n%d scenario(s) changed instruction count, %d exceeded the D1 miss bound (+%.0f%%)\n",
           ir_changed + 0, d1_worse + 0, (d1_headroom - 1) * 100
    exit (ir_changed + d1_worse + removed) > 0 ? 1 : 0
}
' "$WORK/joined.txt" > "$WORK/report.txt" && status=0 || status=$?

cat "$WORK/report.txt"
fph_rule

if [ "$status" -eq 0 ]; then
    fph_info "the lookup loop executes the same instructions and misses no more often"
    exit 0
fi

if reason=$(fph_change_allowed '[allow-cost-increase]' allow-cost-increase); then
    fph_warn "the lookup loop's cost changed and the change is signed off (via $reason)"
    exit 0
fi

fph_error "the lookup loop's cost changed against $REFERENCE_LABEL"
fph_error "these counts are simulated exactly, not timed: a difference is real."
fph_error "if the change is intended, sign it off with one of:"
fph_error "  * the pull request label  allow-cost-increase"
fph_error "  * [allow-cost-increase] in a commit message"
fph_error "  * tests/ci/check-callgrind.sh --allow-change   (locally)"
exit 1
