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

# Resolved now, acted on after the head side has been disassembled. "There was
# nothing to compare against" is a pass without a measurement, and this script
# does not hand one out before this revision's own side has been shown to build.
HAVE_BASE=1
BASE_LABEL=""
if [ -z "$BASE_INCLUDE" ]; then
    set +e
    BASE_REF=$(fph_resolve_base_ref "$BASE_REF"); resolved=$?
    set -e
    case "$resolved" in
        0) fph_materialise_base "$BASE_REF" "$WORK/base" || exit 2
           BASE_INCLUDE="$WORK/base/include"
           BASE_LABEL="$BASE_REF" ;;
        3) HAVE_BASE=0 ;;
        *) fph_error "cannot work out what to compare against; pass --base or --base-include"
           exit 2 ;;
    esac
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

# Everything after the symbol name, which is the whole instruction. llvm-objdump
# separates the mnemonic from its operands with a tab of its own, so taking one
# field here compares mnemonics and ignores every operand: the failure summary
# for `and x10, x8, #0x1` -> `#0x3` came out as an empty table and "0 longer, 0
# same length but different, 0 shorter".
#
# That was a macOS-only defect. GNU objdump writes a space there, so on the Linux
# cells one field was already the whole instruction and they reported the change
# correctly; the gate failed on all three cells either way, and what was wrong on
# macOS was the summary that says which symbols moved.
INSTRUCTION='$1 == s { sub(/^[^\t]*\t/, ""); print }'

# dump <side> <include-dir> <out> <label> -- disassemble one side, and say which
# side it was when it fails. asmdump.sh exits 3 for a compile failure.
dump() {
    set +e
    $FPH_NICE "$SELF_DIR/asmdump.sh" "$2" "$3" "$cxx" > "$WORK/dump.log" 2>&1
    dump_status=$?
    set -e
    [ "$dump_status" -eq 0 ] && return 0
    sed 's/^/  /' "$WORK/dump.log" | head -30
    if [ "$dump_status" -eq 3 ] && [ "$1" = base ]; then
        fph_base_side_unbuildable "$GATE" "$LABEL" "$4"
    fi
    fph_error "the $1 side ($4) produced no disassembly under $cxx"
    exit 2
}

overall=0
measured=0
no_base=0

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

    # This revision first, always. The base side is the one with a way through
    # -- fph_base_side_unbuildable, which a label or a push turns into exit 0 --
    # and it is only entitled to that when this revision's side has already
    # built with this compiler and this probe. Measured, with the base side
    # first: a syntax error in asm_probe.cpp, and a compiler wrapper that failed
    # every invocation, each came out as "the base predates the change" and
    # exit 0 on a push, and as a request for the allow-lookup-asm-change label
    # on a pull request -- after which every later run reported green having
    # disassembled nothing. asm_probe.cpp is compiled by nothing but this gate,
    # so no other job would have caught it.
    dump head "$HEAD_INCLUDE" "$WORK/head.raw" "this revision"

    # Announced after the loop, not here, and carried on rather than broken out
    # of: leaving the loop at all would drop a compiler this job asked for and
    # did not find, which is a cell that never ran and has to outrank "there was
    # nothing to compare against". Measured with `break` here: --cxx c++ --cxx
    # nosuch-c++ with no base exited 0 and never looked at the second name,
    # while the same two in the other order exited 2. The remaining compilers
    # still have their head side disassembled, which is what shows each of them
    # can build the probe at all.
    if [ "$HAVE_BASE" = 0 ]; then
        no_base=1
        continue
    fi

    fph_info "  base : $BASE_LABEL"
    dump base "$BASE_INCLUDE" "$WORK/base.raw" "$BASE_LABEL"

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
        awk -F'\t' -v s="$sym" "$INSTRUCTION" "$WORK/base.sym" > "$WORK/b.one"
        awk -F'\t' -v s="$sym" "$INSTRUCTION" "$WORK/head.sym" > "$WORK/h.one"
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

    if fph_report_only; then
        fph_announce warning "$GATE: reported, not gated" \
            "the lookup path's machine code changed under $cxx. This run reports a commit that has already landed, so it does not gate. The diff is in the log."
        fph_info ""
        continue
    fi

    fph_error "the lookup path changed under $cxx: $longer symbol(s) longer, $reordered same length but different, $shorter shorter"
    fph_error "a shorter lookup path is not automatically an improvement: a static instruction"
    fph_error "count is not a speed proxy, so it needs the same sign-off as a longer one."
    fph_error "if the change is intended, sign it off with:"
    fph_error "  * the pull request label  $LABEL   -- adding it starts a new run"
    fph_error "  * tests/ci/check-asm.sh --allow-change   (locally)"
    overall=1
done

if [ "$no_base" = 1 ]; then
    # The head side disassembled, so the probe, the compiler and objdump all
    # work; there is simply no predecessor to compare them against.
    [ "$overall" -eq 0 ] || exit "$overall"
    fph_no_base "$GATE"
    exit 0
fi

if [ "$measured" -eq 0 ]; then
    fph_error "no compiler was usable, so nothing was disassembled and nothing was checked"
    exit 2
fi

exit "$overall"
