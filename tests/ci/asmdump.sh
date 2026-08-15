#!/bin/sh
# asmdump.sh <include-dir> <out.txt> [compiler]
# Disassembles the lookup-path symbols with addresses/offsets normalized away,
# so two revisions can be compared with plain diff.
set -e
INC="$1"; OUT="$2"; CC="${3:-c++}"
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
$CC -std=c++17 -O2 -DNDEBUG -I"$INC" -c "$DIR/asm_probe.cpp" -o "$TMP/probe.o"
objdump -d --no-show-raw-insn "$TMP/probe.o" \
  | sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//' \
  | sed -E 's/0x[0-9a-f]+/HEX/g' \
  | sed -E 's/<[^>]*\+0x[0-9a-f]+>/<SYM>/g' \
  | sed -E 's/^([a-z][a-z0-9.]*[[:space:]]+)[0-9a-f]{2,}([[:space:]]*<)/\1TARGET\2/' \
  | sed -E 's/^(j[a-z]+|b|bl|b\.[a-z]+|call|cb[nz]+|tb[nz]+)([[:space:]]+)[0-9a-f]{2,}$/\1\2TARGET/' \
  | grep -vE '^$|file format|Disassembly of section' > "$OUT"
rm -rf "$TMP"
wc -l < "$OUT"
