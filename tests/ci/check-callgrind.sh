#!/bin/sh
# check-callgrind.sh -- the lookup loop must execute the same instructions and
# touch no more cache lines than the base revision.
# See docs/ci.md for what this gates and why.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

GATE="lookup cost"
LABEL=allow-lookup-cost-increase

usage() {
    cat <<'EOF'
check-callgrind.sh -- the lookup loop's instruction and D1 miss counts.

  tests/ci/check-callgrind.sh                    # head vs the merge base
  tests/ci/check-callgrind.sh --base master --cxx g++
  tests/ci/check-callgrind.sh --base-include DIR # compare against a tree on disk
  tests/ci/check-callgrind.sh --print            # just show the numbers
  tests/ci/check-callgrind.sh --allow-change     # sign off a change
  tests/ci/check-callgrind.sh --skip-unsupported # exit 0 where valgrind cannot run

Linux and valgrind only. Without --skip-unsupported, a platform that cannot run
it is an error, because a check that exits 0 having measured nothing is
indistinguishable from one that passed.

Ir is compared for exact equality and D1 misses as an upper bound with 1% of
headroom. Signing off a change needs the allow-lookup-cost-increase pull
request label, or --allow-change locally.
EOF
}

BASE_REF=""
BASE_INCLUDE=""
CXX=${FPH_CI_CXX:-}
PRINT_ONLY=0
ALLOW=0
SKIP_UNSUPPORTED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF=$2; shift 2 ;;
        --base-include) BASE_INCLUDE=$2; shift 2 ;;
        --cxx) CXX=$2; shift 2 ;;
        --print) PRINT_ONLY=1; shift ;;
        --allow-change) ALLOW=1; shift ;;
        --skip-unsupported) SKIP_UNSUPPORTED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

unsupported() {
    if [ "$SKIP_UNSUPPORTED" = "1" ]; then
        fph_announce warning "$GATE did not run" "$1"
        exit 0
    fi
    fph_error "$1"
    fph_error "pass --skip-unsupported to make this platform's absence a pass"
    exit 2
}

if [ "$(uname -s)" != Linux ]; then
    unsupported "valgrind has no port for $(uname -s), so the lookup loop was not counted"
fi
if ! command -v valgrind >/dev/null 2>&1; then
    unsupported "valgrind is not installed, so the lookup loop was not counted"
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
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT
trap 'rm -rf "$WORK"; exit 143' TERM

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
        # so the columns are found by name rather than by position. Every event
        # this gate reads is required to be there: an unnamed column reads as
        # zero, and zero on both sides compares equal, which would retire half
        # the gate without saying so.
        awk -v scen="$scenario" '
            /^events:/ { for (i = 2; i <= NF; i++) col[$i] = i - 1; next }
            /^(summary|totals):/ { for (i = 2; i <= NF; i++) v[i - 1] = $i + 0; got = 1 }
            END {
                if (!got) { exit 3 }
                split("Ir D1mr D1mw", need, " ")
                for (i in need) if (!(need[i] in col)) { exit 5 }
                ir = v[col["Ir"]]
                d1 = v[col["D1mr"]] + v[col["D1mw"]]
                if (ir <= 0) { exit 4 }
                printf "%s %d %d\n", scen, ir, d1
            }
        ' "$WORK/cg.out" >> "$2" || {
            status=$?
            case "$status" in
                3) fph_error "$scenario: the callgrind output has no summary line" ;;
                4) fph_error "$scenario: the instruction count is zero, so the collection window never opened" ;;
                5) fph_error "$scenario: the callgrind output does not report all of Ir, D1mr and D1mw" ;;
                *) fph_error "$scenario: could not read the callgrind output" ;;
            esac
            fph_error "events line: $(awk '/^events:/ { print; exit }' "$WORK/cg.out")"
            exit 2
        }
    done
    expected=$(printf '%s\n' $SCENARIOS | wc -l | tr -d ' ')
    got=$(wc -l < "$2" | tr -d ' ')
    if [ "$got" -ne "$expected" ]; then
        fph_error "counted $got of $expected scenarios; the rest were not measured"
        exit 2
    fi
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
    # One probe source builds both sides, so a scenario on one side only means
    # one of the runs is incomplete, not that the scenario is new.
    if ($2 == "MISSING" || $4 == "MISSING") {
        printf "%-14s %s\n", name, ($2 == "MISSING" ? "(head only)" : "(base only)")
        if ($2 == "MISSING") added++; else removed++
        next
    }
    compared++
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
    if (compared + 0 == 0) { print "no scenario was compared at all"; exit 2 }
    exit (ir_changed + d1_worse + removed + added) > 0 ? 1 : 0
}
' "$WORK/joined.txt" > "$WORK/report.txt" && status=0 || status=$?

cat "$WORK/report.txt"
fph_rule

if [ "$status" -eq 0 ]; then
    fph_info "the lookup loop executes the same instructions and misses no more often"
    exit 0
fi
if [ "$status" -eq 2 ]; then
    fph_error "the two sides have no scenario in common; nothing was compared"
    exit 2
fi

if reason=$(fph_gate_waived "$LABEL"); then
    fph_announce warning "$GATE waived" \
        "the lookup loop's cost changed under $CXX and was signed off by $reason. The counts are in the log."
    exit 0
fi

fph_error "the lookup loop's cost changed against $REFERENCE_LABEL"
fph_error "these counts are simulated exactly, not timed: a difference is real."
fph_error "if the change is intended, sign it off with:"
fph_error "  * the pull request label  $LABEL"
fph_error "  * tests/ci/check-callgrind.sh --allow-change   (locally)"
exit 1
