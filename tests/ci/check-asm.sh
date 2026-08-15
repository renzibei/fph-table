#!/bin/sh
# check-asm.sh -- the lookup path must not get longer.
#
#   tests/ci/check-asm.sh                       # against the merge base
#   tests/ci/check-asm.sh --base master --cxx g++
#   tests/ci/check-asm.sh --allow-change        # sign off a deliberate change
#
# This project's first priority is lookup performance, and a CI runner cannot
# measure that: the noise floor on a shared machine swamps the effect sizes
# that matter. The machine code of the lookup symbols can be compared exactly,
# though, and it is what actually determines the cost.
#
# Method: disassemble tests/ci/asm_probe.cpp built against the head include tree
# and against the base include tree, IN THE SAME JOB WITH THE SAME COMPILER, and
# compare the two symbol by symbol. Because both sides move together, upgrading
# the compiler cannot fail a pull request that changed nothing -- which is why
# there is no checked-in disassembly baseline.
#
# Verdicts:
#   identical            -> pass, quietly
#   every change shorter -> pass, and say by how much
#   anything else        -> fail, print the instruction-level diff
#
# Overriding: --allow-change, or the `allow-lookup-asm-change` pull request
# label, or [allow-asm-change] in a commit message.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/revision.sh"

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
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$CXX_LIST" ] || CXX_LIST=${FPH_CI_CXX:-c++}
[ "$ALLOW" = "1" ] && FPH_CI_ALLOW_CHANGE=1
export FPH_CI_ALLOW_CHANGE=${FPH_CI_ALLOW_CHANGE:-0}

HEAD_INCLUDE=${FPH_CI_INCLUDE:-$FPH_ROOT/include}

WORK=$(fph_mktempdir)
trap 'rm -rf "$WORK"' EXIT INT TERM

if [ -z "$BASE_INCLUDE" ]; then
    if ! BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); then
        fph_error "cannot work out what to compare against; pass --base or --base-include"
        exit 2
    fi
    fph_materialise_base "$BASE_REF" "$WORK/base"
    BASE_INCLUDE="$WORK/base/include"
    BASE_LABEL="$BASE_REF"
else
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
/^[0-9a-fA-F]+ <.*>:$/ {
    sym = $0
    sub(/^[0-9a-fA-F]+ </, "", sym)
    sub(/>:$/, "", sym)
    next
}
/nop/ { next }
sym != "" {
    line = $0
    # asmdump.sh rewrites 0x... to HEX before it gets to its <sym+0x..> rule,
    # so on GNU objdump the rule never fires and a residual absolute address
    # survives in comments like "lea HEX(%rip),%rsi  # 212 <fphprobe_x+HEX>".
    # That address moves whenever anything before it changes size. Finish the
    # normalisation here rather than editing asmdump.sh, which is shared with
    # the out-of-tree harness and must keep producing comparable output.
    gsub(/<[^>]*\+HEX>/, "<SYM>", line)
    gsub(/[0-9a-f]+ <SYM>/, "TARGET <SYM>", line)
    print sym "\t" line
}
'

overall=0

for cxx in $CXX_LIST; do
    if ! command -v "$cxx" >/dev/null 2>&1; then
        fph_warn "skipping $cxx: not on PATH"
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

    cut -f1 "$WORK/base.sym" | sort -u > "$WORK/base.names"
    cut -f1 "$WORK/head.sym" | sort -u > "$WORK/head.names"

    verdict=identical
    if ! cmp -s "$WORK/base.sym" "$WORK/head.sym"; then
        verdict=changed
    fi

    if [ "$verdict" = identical ]; then
        fph_info "  result: identical ($(wc -l < "$WORK/head.sym" | tr -d ' ') instructions)"
        fph_info ""
        continue
    fi

    structural=0
    if ! cmp -s "$WORK/base.names" "$WORK/head.names"; then
        structural=1
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
        case "$sym" in
            fphprobe_sizeof_*)
                # A sizeof probe is a one-instruction "return N". If its body
                # moved, the table object changed size. check-sizeof.sh reports
                # the number; here it is simply disqualifying.
                structural=1 ;;
        esac
        if [ "$hn" -gt "$bn" ]; then
            longer=$((longer + 1))
        elif [ "$hn" -lt "$bn" ]; then
            shorter=$((shorter + 1))
        else
            reordered=$((reordered + 1))
        fi
    done < "$WORK/head.names"

    fph_info ""
    if [ "$structural" -eq 0 ] && [ "$longer" -eq 0 ] && [ "$reordered" -eq 0 ] \
            && [ "$shorter" -gt 0 ]; then
        fph_info "  result: the lookup path got SHORTER in $shorter symbol(s); nothing got longer"
        fph_info "  (pass -- this is an improvement, no sign-off needed)"
        fph_info ""
        continue
    fi

    fph_info "  instruction-level diff (base -> head):"
    diff -u "$WORK/base.sym" "$WORK/head.sym" | sed 's/^/    /' | head -200 || true
    fph_info ""

    if reason=$(fph_change_allowed '[allow-asm-change]' allow-lookup-asm-change); then
        fph_warn "the lookup path changed and the change is signed off (via $reason)"
        fph_warn "the diff above is what was accepted"
        fph_info ""
        continue
    fi

    fph_error "the lookup path changed under $cxx: $longer symbol(s) longer, $reordered same length but different, $shorter shorter, structural=$structural"
    fph_error "this project's first priority is lookup performance, so this is a failure by default."
    fph_error "if the change is intended and justified, sign it off with one of:"
    fph_error "  * the pull request label  allow-lookup-asm-change"
    fph_error "  * [allow-asm-change] in a commit message"
    fph_error "  * tests/ci/check-asm.sh --allow-change   (locally)"
    overall=1
done

exit "$overall"
