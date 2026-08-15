# Shared helpers for the tests/ci scripts. Sourced, not executed.
#
# Everything here is POSIX sh so the same scripts run on a GitHub Linux runner,
# a GitHub macOS runner and a developer laptop without modification.

# Root of the checkout, derived from this file's location, so the scripts work
# no matter which directory they are invoked from.
FPH_CI_DIR=$(cd "$(dirname "$0")" && pwd)
FPH_ROOT=$(cd "$FPH_CI_DIR/../.." && pwd)
export FPH_CI_DIR FPH_ROOT

# nice(1) by default: these scripts are also run on interactive machines.
FPH_NICE=${FPH_NICE:-"nice -n 19"}

fph_info()  { printf '%s\n' "$*"; }
fph_note()  { printf 'note: %s\n' "$*"; }
fph_warn()  { printf 'warning: %s\n' "$*" >&2; }
fph_error() { printf 'error: %s\n' "$*" >&2; }

fph_rule() { printf -- '------------------------------------------------------------\n'; }

# fph_default_compilers -- the compilers to use when the caller names none.
# Deliberately conservative: only compilers that exist on this machine.
fph_default_compilers() {
    for c in c++ g++ clang++ g++-15 g++-14 g++-13; do
        if command -v "$c" >/dev/null 2>&1; then printf '%s\n' "$c"; fi
    done | awk '!seen[$0]++'
}

# fph_platform_tag -- identifies the baseline file that applies here.
# Allocation counts and struct sizes are properties of a (libstdc++ vs libc++,
# pointer size, arch) combination, so baselines are stored per platform rather
# than pretending one number fits all.
fph_platform_tag() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    printf '%s-%s\n' "$os" "$arch"
}

# fph_toolchain_tag <compiler> -- names the baseline file that applies here.
# Measured: gcc 13 and clang 18 on the same Linux box agree exactly (same
# libstdc++), while macOS/libc++ disagrees with both, and gcc 13 disagrees with
# gcc 15. So the tag has to name the compiler and its major version, not just
# the platform.
fph_toolchain_tag() {
    cxx=$1
    banner=$("$cxx" --version 2>/dev/null | head -1)
    case "$banner" in
        *"Apple clang"*) family=appleclang ;;
        *clang*)         family=clang ;;
        *"Free Software Foundation"*|*g++*|*GCC*|*gcc*) family=gcc ;;
        *)               family=$(basename "$cxx" | tr -cd 'A-Za-z0-9') ;;
    esac
    version=$(printf '%s' "$banner" | tr ' ' '\n' |
              grep -m1 -E '^[0-9]+\.[0-9]+' | cut -d. -f1)
    [ -n "$version" ] || version=unknown
    printf '%s-%s%s\n' "$(fph_platform_tag)" "$family" "$version"
}

# fph_mktempdir -- portable mktemp -d, removed by the caller's trap.
fph_mktempdir() { mktemp -d "${TMPDIR:-/tmp}/fphci.XXXXXX"; }

# fph_git_worktree_at <ref> <dir> -- materialise <ref> at <dir>.
# Used to build the merge base in the same job, with the same compiler, as the
# head revision. Falls back to `git archive` when a worktree cannot be added
# (for example when the ref is already checked out somewhere).
fph_git_worktree_at() {
    ref=$1; dir=$2
    if git -C "$FPH_ROOT" worktree add --detach "$dir" "$ref" >/dev/null 2>&1; then
        printf 'worktree\n'
        return 0
    fi
    mkdir -p "$dir"
    if git -C "$FPH_ROOT" archive "$ref" | tar -x -C "$dir"; then
        printf 'archive\n'
        return 0
    fi
    return 1
}

fph_git_worktree_release() {
    dir=$1
    git -C "$FPH_ROOT" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
}
