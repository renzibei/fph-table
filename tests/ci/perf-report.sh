#!/bin/sh
# perf-report.sh -- wall-clock lookup timings, as a REPORT, never as a gate.
#
#   tests/ci/perf-report.sh                       # against the merge base
#   tests/ci/perf-report.sh --base master --rounds 7
#   tests/ci/perf-report.sh --markdown out.md     # also write a summary table
#
# Always exits 0. Read docs/ci.md before believing any number in here.
#
# The trick that makes the output readable: three arms are timed, not two.
#
#   base     the merge base, built here with this compiler
#   head     this revision, built here with this compiler
#   control  a byte-identical copy of the head binary
#
# `control` differs from `head` by nothing whatsoever, so head-vs-control is a
# direct measurement of this machine's noise floor during this very run. It is
# printed next to head-vs-base so a reader can tell a real change from the
# runner having a bad minute. A head-vs-base delta smaller than a few times the
# head-vs-control spread means nothing at all.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

BASE_REF=""
CXX=${FPH_CI_CXX:-}
ROUNDS=${FPH_CI_PERF_ROUNDS:-5}
REPEATS=${FPH_CI_PERF_REPEATS:-3}
MARKDOWN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF=$2; shift 2 ;;
        --cxx) CXX=$2; shift 2 ;;
        --rounds) ROUNDS=$2; shift 2 ;;
        --repeats) REPEATS=$2; shift 2 ;;
        --markdown) MARKDOWN=$2; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_info "no C++ compiler found; nothing to report"; exit 0; }

INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}
WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT INT TERM

if ! BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); then
    fph_info "no base revision to compare against; reporting head only"
    BASE_REF=""
fi

build() { # <include-dir> <out>
    $FPH_NICE "$CXX" -std=c++17 -O2 -DNDEBUG -I"$1" \
        "$SELF_DIR/perf_probe.cpp" -o "$2" > "$WORK/build.log" 2>&1 || {
            fph_info "perf probe does not build against $1; skipping the report"
            sed 's/^/  /' "$WORK/build.log" | head -20
            exit 0
        }
}

build "$INCLUDE" "$WORK/head"
cp "$WORK/head" "$WORK/control"   # byte-identical on purpose

have_base=0
if [ -n "$BASE_REF" ]; then
    if fph_materialise_base "$BASE_REF" "$WORK/basetree" 2>/dev/null; then
        build "$WORK/basetree/include" "$WORK/base"
        have_base=1
    fi
fi

# Interleave the arms so that a machine that gets slower part way through the
# run penalises all of them equally instead of whichever ran last.
: > "$WORK/samples.txt"
i=1
while [ "$i" -le "$REPEATS" ]; do
    for arm in base head control; do
        [ "$arm" = base ] && [ "$have_base" -eq 0 ] && continue
        $FPH_NICE "$WORK/$arm" "$ROUNDS" | awk -v a="$arm" '{ print a, $1, $2 }' \
            >> "$WORK/samples.txt"
    done
    i=$((i + 1))
done

fph_info "lookup timings -- INFORMATIONAL, NOT A GATE"
fph_info "  compiler : $CXX"
fph_info "  head     : $INCLUDE"
[ "$have_base" -eq 1 ] && fph_info "  base     : $BASE_REF"
fph_info "  rounds   : $ROUNDS inner, $REPEATS outer"
fph_info "  runner   : $(uname -s) $(uname -m)"
fph_rule

awk -v have_base="$have_base" '
{
    arm = $1; scen = $2; v = $3 + 0
    key = arm "/" scen
    if (!(key in best) || v < best[key]) best[key] = v
    seen[scen] = 1
}
END {
    printf "%-14s %12s %12s %12s %10s %10s  %s\n",
           "scenario", "base ns", "head ns", "control ns",
           "head/base", "noise", "verdict"
    n = 0
    for (s in seen) order[++n] = s
    # deterministic ordering without asort(), which is a gawk extension
    for (i = 1; i < n; i++)
        for (j = i + 1; j <= n; j++)
            if (order[j] < order[i]) { t = order[i]; order[i] = order[j]; order[j] = t }

    for (i = 1; i <= n; i++) {
        s = order[i]
        h = best["head/" s] / 1000.0
        c = best["control/" s] / 1000.0
        b = have_base ? best["base/" s] / 1000.0 : 0

        noise = (h > 0) ? (c - h) / h * 100.0 : 0
        if (noise < 0) noise = -noise

        if (have_base && b > 0) {
            delta = (h - b) / b * 100.0
            ad = delta < 0 ? -delta : delta
            # "Worth a look" only past several times the floor this very run
            # measured, and never below one percent.
            floor = noise * 4
            if (floor < 1.0) floor = 1.0
            verdict = (ad > floor) ? "worth a look" : "indistinguishable from noise"
            printf "%-14s %12.3f %12.3f %12.3f %+9.2f%% %9.2f%%  %s\n",
                   s, b, h, c, delta, noise, verdict
        } else {
            printf "%-14s %12s %12.3f %12.3f %10s %9.2f%%  %s\n",
                   s, "-", h, c, "-", noise, "no base to compare against"
        }
    }
}
' "$WORK/samples.txt" | tee "$WORK/table.txt"

fph_rule
fph_info "\"noise\" is head measured against a byte-identical copy of itself in this same run."
fph_info "It is the smallest difference this machine could possibly resolve today."
fph_info "Nothing here fails a build. The gate for lookup cost is tests/ci/check-asm.sh."

if [ -n "$MARKDOWN" ]; then
    {
        printf '### Lookup timings (informational)\n\n'
        printf 'Runner: `%s %s`, compiler `%s`.\n\n' "$(uname -s)" "$(uname -m)" "$CXX"
        printf '`noise` is this revision timed against a **byte-identical copy of its own binary**\n'
        printf 'in the same run: the smallest difference this machine could resolve today.\n'
        printf 'A `head/base` delta below a few times `noise` means nothing.\n'
        printf 'Nothing in this table gates the build -- see `docs/ci.md`.\n\n'
        printf '```\n'
        cat "$WORK/table.txt"
        printf '```\n'
    } > "$MARKDOWN"
    fph_info "wrote $MARKDOWN"
fi

exit 0
