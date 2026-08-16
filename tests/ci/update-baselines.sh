#!/bin/sh
# update-baselines.sh -- move a recorded number on purpose.
# See docs/ci.md for what the baseline is and when to move it.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"

usage() {
    cat <<'EOF'
update-baselines.sh -- move a recorded number on purpose.

  tests/ci/update-baselines.sh
  tests/ci/update-baselines.sh --sizeof
  tests/ci/update-baselines.sh --sizeof --cxx g++-13

There is one recorded number: tests/ci/baselines/sizeof.txt, the exact size and
alignment of every container. It is compared for equality in both directions and
is identical on every LP64 target measured, so there is one file and not one per
platform.

The other gates record nothing. They build the base revision in the same job and
compare against that, because the counts they produce differ between standard
libraries and between compiler versions and so cannot be written down once.

Run this, read `git diff -- tests/ci/baselines/`, and commit the new numbers
with the change that justifies them.
EOF
}

DO_SIZEOF=0
CXX=${FPH_CI_CXX:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --sizeof) DO_SIZEOF=1; shift ;;
        --cxx) CXX=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

DO_SIZEOF=1

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }

if [ "$DO_SIZEOF" -eq 1 ]; then
    "$SELF_DIR/check-sizeof.sh" --cxx "$CXX" --update
fi

fph_info ""
fph_info "now read the diff and commit it with the change that justifies it:"
fph_info "  git diff -- tests/ci/baselines/"
