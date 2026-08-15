#!/bin/sh
# perf-report.sh -- wall-clock lookup timings, as a REPORT, never as a gate.
#
#   tests/ci/perf-report.sh                       # against the merge base
#   tests/ci/perf-report.sh --base master --rounds 7
#   tests/ci/perf-report.sh --markdown out.md     # also write a summary table
#
# Always exits 0, and is not a gate. Read docs/ci.md before believing a number.
#
# The trick that makes the output readable: three arms are timed, not two.
#
#   base     the merge base, built here with this compiler
#   head     this revision, built here with this compiler
#   control  a byte-identical copy of the head binary
#
# `control` differs from `head` by nothing whatsoever, so head-vs-control is a
# direct measurement of this machine's noise floor during this very run. It is
# printed next to head-vs-base, together with the threshold it implies, so that
# a reader can check a difference instead of being told what it means.
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
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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

# If the lookup path's machine code is byte-identical to the base revision then
# no timing difference below can be real, whatever the numbers say. Ask the
# deterministic check rather than leaving the reader to infer it: a timing
# verdict that contradicts identical machine code is noise being dressed up as
# a finding, and it teaches people to ignore this report.
asm_identical=0
if [ "$have_base" = 1 ] && [ -x "$SELF_DIR/check-asm.sh" ]; then
    if "$SELF_DIR/check-asm.sh" --base "$BASE_REF" --cxx "$CXX" > "$WORK/asm.log" 2>&1 \
            && grep -q "result: identical" "$WORK/asm.log"; then
        asm_identical=1
        fph_info "  lookup asm: identical to $BASE_REF -- no delta below can be real"
    fi
fi
fph_rule

# The table states the threshold rather than a verdict. A verdict cannot be
# checked; a threshold can, from the two columns next to it.
awk -v have_base="$have_base" -v status="$WORK/status.txt" '
{
    arm = $1; scen = $2; v = $3 + 0
    key = arm "/" scen
    if (!(key in best) || v < best[key]) best[key] = v
    seen[scen] = 1
}
END {
    n = 0
    for (s in seen) order[++n] = s
    # deterministic ordering without asort(), which is a gawk extension
    for (i = 1; i < n; i++)
        for (j = i + 1; j <= n; j++)
            if (order[j] < order[i]) { t = order[i]; order[i] = order[j]; order[j] = t }

    # Noise is a property of the machine during this run, not of one scenario.
    # head and control are the same bytes, so every scenario measures the same
    # thing; when one of them happens to come out tight that is luck, not the
    # runner going quiet for that scenario. Take the worst seen and hold every
    # row to it, or a scenario with a lucky control sets itself a threshold no
    # real measurement could clear.
    worst = 0
    for (i = 1; i <= n; i++) {
        s = order[i]
        h = best["head/" s] / 1000.0
        c = best["control/" s] / 1000.0
        nz = (h > 0) ? (c - h) / h * 100.0 : 0
        if (nz < 0) nz = -nz
        noise[s] = nz
        if (nz > worst) worst = nz
    }
    threshold = worst * 4
    if (threshold < 1.0) threshold = 1.0

    printf "%-14s %12s %12s %12s %10s %9s %10s\n",
           "scenario", "base ns", "head ns", "control ns",
           "head/base", "noise", "threshold"

    above = 0
    names = ""
    for (i = 1; i <= n; i++) {
        s = order[i]
        h = best["head/" s] / 1000.0
        c = best["control/" s] / 1000.0
        b = have_base ? best["base/" s] / 1000.0 : 0

        if (have_base && b > 0) {
            delta = (h - b) / b * 100.0
            ad = delta < 0 ? -delta : delta
            if (ad > threshold) {
                above++
                names = names (above > 1 ? ", " : "") s
            }
            printf "%-14s %12.3f %12.3f %12.3f %+9.2f%% %8.2f%% %9.2f%%\n",
                   s, b, h, c, delta, noise[s], threshold
        } else {
            printf "%-14s %12s %12.3f %12.3f %10s %8.2f%% %10s\n",
                   s, "-", h, c, "-", noise[s], "-"
        }
    }
    print "above " above > status
    print "names " names > status
    printf "threshold %.2f\n", threshold > status
}
' "$WORK/samples.txt" | tee "$WORK/table.txt"

above=$(awk '$1 == "above" { print $2 }' "$WORK/status.txt")
names=$(awk '$1 == "names" { $1 = ""; sub(/^ /, ""); print }' "$WORK/status.txt")
threshold=$(awk '$1 == "threshold" { print $2 }' "$WORK/status.txt")

if [ "$have_base" -eq 0 ]; then
    lead="No base revision to compare against; head timings only."
elif [ "$above" -eq 0 ]; then
    lead="No lookup timing differences above the noise floor."
elif [ "$above" -eq 1 ]; then
    lead="$names is above the ${threshold}% threshold."
else
    lead="$above scenarios are above the ${threshold}% threshold: $names."
fi
if [ "$asm_identical" -eq 1 ]; then
    lead="The lookup machine code is byte-identical to $BASE_REF. $lead"
fi

fph_rule
fph_info "$lead"
fph_info "\"noise\" is head measured against a byte-identical copy of itself in this same run."
fph_info "\"threshold\" is four times the largest noise seen this run, floored at 1%."
fph_info "Nothing here fails a build. Lookup cost is gated by tests/ci/check-asm.sh"
fph_info "and, on Linux, tests/ci/check-callgrind.sh."

if [ -n "$MARKDOWN" ]; then
    # Nothing above the threshold means there is nothing to read, so the table
    # is folded away and the first line is the whole report.
    open=""
    close=""
    if [ "$above" -eq 0 ]; then
        open='<details>\n<summary>numbers</summary>\n\n'
        close='\n</details>\n'
    fi
    {
        printf '### Lookup timings (informational)\n\n'
        printf '%s\n\n' "$lead"
        printf "$open"
        printf 'Runner: `%s %s`, compiler `%s`.\n\n' "$(uname -s)" "$(uname -m)" "$CXX"
        printf '```\n'
        cat "$WORK/table.txt"
        printf '```\n\n'
        printf '`noise` is this revision timed against a **byte-identical copy of its own\n'
        printf 'binary** in the same run. `threshold` is four times the largest `noise` seen\n'
        printf 'this run, pooled across scenarios and floored at 1%%; a `head/base` delta\n'
        printf 'below it is not a measurement.\n'
        printf 'Nothing in this table gates the build -- see `docs/ci.md`.\n'
        printf "$close"
    } > "$MARKDOWN"
    fph_info "wrote $MARKDOWN"
fi

exit 0
