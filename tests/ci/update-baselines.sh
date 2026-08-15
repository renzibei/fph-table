#!/bin/sh
# update-baselines.sh -- move a recorded number on purpose.
#
#   tests/ci/update-baselines.sh              # everything, for this toolchain
#   tests/ci/update-baselines.sh --sizeof
#   tests/ci/update-baselines.sh --counters
#   tests/ci/update-baselines.sh --counters --cxx g++-13
#
# This exists because a gate nobody can deliberately update is a gate that gets
# deleted. Run it, look at `git diff`, and commit the new numbers together with
# the change that justifies them -- the diff is the record of what the change
# cost and is the thing a reviewer should read.
#
# What each file is:
#
#   baselines/sizeof.txt
#       Exact sizes of every container. Compared for equality in both
#       directions. Identical on every LP64 target measured, so there is one
#       file rather than one per platform.
#
#   baselines/counters-<toolchain>.txt
#       Allocation counts, bytes, peak footprint and key copy/move counts for
#       fixed workloads. Compared as upper bounds. These are NOT portable: the
#       library's parameter search draws from std::uniform_int_distribution,
#       whose sequence differs between libstdc++ and libc++ and even between
#       gcc versions, so each file records the toolchain it came from and is
#       only used when that toolchain matches. Pull request CI does not use
#       these files at all -- it measures the merge base in the same job. They
#       are for checking a working tree locally, and as a written record of
#       what construction currently costs.
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib.sh"

DO_SIZEOF=0
DO_COUNTERS=0
CXX=${FPH_CI_CXX:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --sizeof) DO_SIZEOF=1; shift ;;
        --counters) DO_COUNTERS=1; shift ;;
        --cxx) CXX=$2; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) fph_error "unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$DO_SIZEOF" -eq 0 ] && [ "$DO_COUNTERS" -eq 0 ]; then
    DO_SIZEOF=1
    DO_COUNTERS=1
fi

if [ -z "$CXX" ]; then
    CXX=$(fph_default_compilers | head -1)
fi
[ -n "$CXX" ] || { fph_error "no C++ compiler found"; exit 2; }

if [ "$DO_SIZEOF" -eq 1 ]; then
    "$SELF_DIR/check-sizeof.sh" --cxx "$CXX" --update
fi

if [ "$DO_COUNTERS" -eq 1 ]; then
    tag=$(fph_toolchain_tag "$CXX")
    out="$SELF_DIR/baselines/counters-$tag.txt"
    "$SELF_DIR/check-counters.sh" --cxx "$CXX" --write "$out"
fi

fph_info ""
fph_info "now read the diff and commit it with the change that justifies it:"
fph_info "  git diff -- tests/ci/baselines/"
