#!/bin/sh
# check-asm.sh -- the machine code of the lookup path must not change.
# See docs/ci.md for what this gates and why.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

GATE="lookup asm"
LABEL=allow-lookup-asm-change

usage() {
    cat <<'EOF'
check-asm.sh -- the machine code of the lookup path must not change.

  tests/ci/check-asm.sh                       # against the merge base
  tests/ci/check-asm.sh --base master --cxx g++
  tests/ci/check-asm.sh --base-include DIR    # compare against a tree on disk
  tests/ci/check-asm.sh --allow-change        # sign off a deliberate change

Disassembles tests/ci/asm_probe.cpp against the head and base include trees, in
this job with this compiler, and compares them symbol by symbol.

  identical      -> pass
  anything else  -> fail, and print the instruction-level diff

Signing off a deliberate change needs the allow-lookup-asm-change pull request
label, or --allow-change locally.
EOF
}

BASE_REF=""
BASE_INCLUDE=""
CXX_LIST=""
ALLOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF=$2; shift 2 ;;
        --base-include) BASE_INCLUDE=$2; shift 2 ;;
        --cxx) CXX_LIST="$CXX_LIST $2"; shift 2 ;;
        --allow-change) ALLOW=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$CXX_LIST" ] || CXX_LIST=${FPH_CI_CXX:-c++}
[ "$ALLOW" = "1" ] && FPH_CI_ALLOW_CHANGE=1
export FPH_CI_ALLOW_CHANGE=${FPH_CI_ALLOW_CHANGE:-0}

HEAD_INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}

WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT
trap 'rm -rf "$WORK"; exit 143' TERM

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
    BASE_LABEL="$BASE_REF"
else
    [ -d "$BASE_INCLUDE" ] || { fph_error "no such include tree: $BASE_INCLUDE"; exit 2; }
    BASE_LABEL="$BASE_INCLUDE"
fi

# Splits a normalised disassembly into "<symbol>\t<instruction>" lines.
#
# Two things are dropped, both of them noise rather than signal:
#
#   the symbol's own address -- so that one symbol changing length does not
#   make every symbol after it look different;
#
#   nop padding -- objdump attributes the alignment padding before a function
#   to the function BEFORE it, so shortening one symbol by four bytes silently
#   rewrites the tail of its neighbour. Measured on x86-64/gcc: a four-byte
#   change in fphprobe_dm_count showed up as changes in fphprobe_dms_find and
#   fphprobe_mms_find too. No instruction other than the nop family has "nop"
#   in its mnemonic, so this cannot hide real work.
SPLIT='
/^(TARGET|[0-9a-fA-F]+) <.*>:$/ {
    sym = $0
    sub(/^(TARGET|[0-9a-fA-F]+) </, "", sym)
    sub(/>:$/, "", sym)
    next
}
/nop/ { next }
sym != "" { print sym "\t" $0 }
'

overall=0
measured=0

for cxx in $CXX_LIST; do
    if ! command -v "$cxx" >/dev/null 2>&1; then
        # A compiler the workflow asked for and the runner does not have means
        # the cell did not run. Reporting that as a pass would be reporting a
        # measurement that was never taken.
        fph_error "$cxx is not on PATH, so nothing was disassembled"
        overall=2
        continue
    fi

    fph_info "lookup-path disassembly: $cxx"
    fph_info "  head : $HEAD_INCLUDE"
    fph_info "  base : $BASE_LABEL"

    $FPH_NICE "$SELF_DIR/asmdump.sh" "$BASE_INCLUDE" "$WORK/base.raw" "$cxx" > /dev/null
    $FPH_NICE "$SELF_DIR/asmdump.sh" "$HEAD_INCLUDE" "$WORK/head.raw" "$cxx" > /dev/null

    awk "$SPLIT" "$WORK/base.raw" > "$WORK/base.sym"
    awk "$SPLIT" "$WORK/head.raw" > "$WORK/head.sym"

    if [ ! -s "$WORK/head.sym" ] || [ ! -s "$WORK/base.sym" ]; then
        fph_error "the disassembly came out empty; objdump may not understand this object"
        exit 2
    fi

    measured=$((measured + 1))

    if cmp -s "$WORK/base.sym" "$WORK/head.sym"; then
        fph_info "  result: identical ($(wc -l < "$WORK/head.sym" | tr -d ' ') instructions)"
        fph_info ""
        continue
    fi

    cut -f1 "$WORK/base.sym" | sort -u > "$WORK/base.names"
    cut -f1 "$WORK/head.sym" | sort -u > "$WORK/head.names"
    if ! cmp -s "$WORK/base.names" "$WORK/head.names"; then
        fph_info "  symbols only in base:"
        comm -23 "$WORK/base.names" "$WORK/head.names" | sed 's/^/    /'
        fph_info "  symbols only in head:"
        comm -13 "$WORK/base.names" "$WORK/head.names" | sed 's/^/    /'
    fi

    longer=0
    shorter=0
    reordered=0
    printf '  %-34s %8s %8s %8s\n' symbol base head delta
    while IFS= read -r sym; do
        awk -F'\t' -v s="$sym" '$1 == s { print $2 }' "$WORK/base.sym" > "$WORK/b.one"
        awk -F'\t' -v s="$sym" '$1 == s { print $2 }' "$WORK/head.sym" > "$WORK/h.one"
        if cmp -s "$WORK/b.one" "$WORK/h.one"; then
            continue
        fi
        bn=$(wc -l < "$WORK/b.one" | tr -d ' ')
        hn=$(wc -l < "$WORK/h.one" | tr -d ' ')
        printf '  %-34s %8s %8s %+8d\n' "$sym" "$bn" "$hn" "$((hn - bn))"
        if [ "$hn" -gt "$bn" ]; then
            longer=$((longer + 1))
        elif [ "$hn" -lt "$bn" ]; then
            shorter=$((shorter + 1))
        else
            reordered=$((reordered + 1))
        fi
    done < "$WORK/head.names"

    fph_info ""
    fph_info "  instruction-level diff (base -> head):"
    diff -u "$WORK/base.sym" "$WORK/head.sym" | sed 's/^/    /' | head -200 || true
    fph_info ""

    if reason=$(fph_gate_waived "$LABEL"); then
        fph_announce warning "$GATE waived" \
            "the lookup path's machine code changed under $cxx and was signed off by $reason. The diff is in the log."
        fph_info ""
        continue
    fi

    fph_error "the lookup path changed under $cxx: $longer symbol(s) longer, $reordered same length but different, $shorter shorter"
    fph_error "a shorter lookup path is not automatically an improvement: a static instruction"
    fph_error "count is not a speed proxy, so it needs the same sign-off as a longer one."
    fph_error "if the change is intended, sign it off with:"
    fph_error "  * the pull request label  $LABEL"
    fph_error "  * tests/ci/check-asm.sh --allow-change   (locally)"
    overall=1
done

if [ "$measured" -eq 0 ]; then
    fph_error "no compiler was usable, so nothing was disassembled and nothing was checked"
    exit 2
fi

exit "$overall"
