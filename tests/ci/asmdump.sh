#!/bin/sh
# asmdump.sh <include-dir> <out.txt> [compiler]
#
# Disassembles the lookup-path symbols with addresses normalised away, so two
# revisions can be compared with plain diff.
#
# What is normalised is only what moves when unrelated code changes size:
# instruction addresses, branch and call targets, <symbol+offset> operands, and
# %rip-relative displacements.
#
# Immediates are NOT normalised. Masks, shift amounts, struct field offsets and
# hash constants all appear as hex, and they are the content of the lookup path
# rather than noise about where it landed: `and $0x1,%eax` -> `and $0x3,%eax` is
# a different table. Both disassemblers keep the two apart -- GNU objdump writes
# immediates as `$0x1` and displacements as `0x10(%rdi)` while branch targets are
# bare hex, and llvm-objdump writes immediates as `#0x1` while targets carry the
# `0x` on their own.
set -eu
INC="$1"; OUT="$2"; CC="${3:-c++}"
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM

# Exit 3, distinct from every other failure here, so that check-asm.sh can tell
# "this include tree cannot build the probe" from "objdump said nothing".
if ! $CC -std=c++17 -O2 -DNDEBUG -I"$INC" -c "$DIR/asm_probe.cpp" -o "$TMP/probe.o"; then
    printf 'error: the asm probe does not compile against %s\n' "$INC" >&2
    exit 3
fi
objdump -d --no-show-raw-insn "$TMP/probe.o" > "$TMP/raw.txt"

sed -E \
    -e 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//' \
    -e 's/<[^>]*\+0x[0-9a-f]+>/<SYM>/g' \
    -e 's/-?0x[0-9a-f]+\(%rip\)/RIPREL(%rip)/g' \
    -e 's/(^|[[:space:]])(0x)?[0-9a-f]+([[:space:]]*<)/\1TARGET\3/g' \
    -e 's/(^|[[:space:]])(#|;)[[:space:]]*(0x)?[0-9a-f]+[[:space:]]*(<)/\1\2 TARGET \4/g' \
    -e 's/^(j[a-z]+|b|bl|b\.[a-z]+|call|cb[nz]+|tb[nz]+)([[:space:]]+)(0x)?[0-9a-f]{2,}$/\1\2TARGET/' \
    "$TMP/raw.txt" \
  | grep -vE '^$|file format|Disassembly of section' > "$OUT"

if [ ! -s "$OUT" ]; then
    printf 'error: %s produced no disassembly for %s\n' "$(command -v objdump)" "$INC" >&2
    exit 2
fi

wc -l < "$OUT"
