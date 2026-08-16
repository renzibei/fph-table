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

# fph_toolchain_tag <compiler> -- names the toolchain a measurement came from.
# Measured: gcc 13 and clang 18 on the same Linux box agree exactly (same
# libstdc++), while macOS/libc++ disagrees with both, and gcc 13 disagrees with
# gcc 15. So the tag has to name the compiler and its major version.
#
# Read from the compiler's own predefined macros rather than from the --version
# banner. Ubuntu's `c++` prints "c++ (Ubuntu 13.3.0-...) 13.3.0", which names
# neither gcc nor GCC, and `c++` is what CONTRIBUTING.md tells contributors to
# run. Fails rather than guessing.
fph_toolchain_tag() {
    cxx=$1
    macros=$(printf '' | "$cxx" -x c++ -E -dM - 2>/dev/null) || macros=""
    family=""
    version=""
    if printf '%s\n' "$macros" | grep -q '^#define __apple_build_version__'; then
        family=appleclang
        version=$(printf '%s\n' "$macros" | awk '$2 == "__clang_major__" { print $3 }')
    elif printf '%s\n' "$macros" | grep -q '^#define __clang__'; then
        family=clang
        version=$(printf '%s\n' "$macros" | awk '$2 == "__clang_major__" { print $3 }')
    elif printf '%s\n' "$macros" | grep -q '^#define __GNUC__'; then
        family=gcc
        version=$(printf '%s\n' "$macros" | awk '$2 == "__GNUC__" { print $3 }')
    fi
    if [ -z "$family" ] || [ -z "$version" ]; then
        fph_error "cannot identify the compiler $cxx from its predefined macros"
        return 1
    fi
    printf '%s-%s%s\n' "$(fph_platform_tag)" "$family" "$version"
}

# fph_compiler_identity <compiler> -- which compiler this name actually is.
#
# The name is not the identity, and neither is the --version banner: on macOS
# `c++`, `g++` and `clang++` are three hardlinks to one Apple clang, and on
# Ubuntu `c++`, `g++` and `g++-13` all reach one gcc through /etc/alternatives
# while each printing its own name in the banner. A matrix that dedupes by
# either reports cells it never ran.
#
# The inode of the binary after following symlinks is the same for every name
# that reaches the same file, and different for genuinely different compilers.
fph_compiler_identity() {
    cxx=$1
    resolved=$(command -v "$cxx" 2>/dev/null) || { printf '%s\n' "$cxx"; return 0; }
    inode=$(ls -iL "$resolved" 2>/dev/null | awk '{ print $1; exit }')
    if [ -n "$inode" ]; then
        printf 'inode:%s\n' "$inode"
    else
        printf 'path:%s\n' "$resolved"
    fi
}

# fph_mktempdir -- portable mktemp -d, removed by the caller's trap.
fph_mktempdir() { mktemp -d "${TMPDIR:-/tmp}/fphci.XXXXXX"; }

# fph_gate_waived <label> -- has this gate been signed off for this run?
#
# Two channels, both of which need write access to the repository:
#   * the pull request label, visible in the pull request header
#   * --allow-change on a local run, which sets FPH_CI_ALLOW_CHANGE
#
# FPH_CI_PR_LABELS is the JSON array the workflow takes from the event payload,
# so the match is on a whole label and not on a substring of a longer name.
fph_gate_waived() {
    label=$1
    if [ "${FPH_CI_ALLOW_CHANGE:-0}" = "1" ]; then
        printf -- '--allow-change\n'
        return 0
    fi
    case "${FPH_CI_PR_LABELS:-}" in
        *"\"$label\""*) printf 'the %s label\n' "$label"; return 0 ;;
    esac
    return 1
}

# fph_announce <level> <title> <message> -- say something that survives a green
# check. GitHub renders ::warning:: on the run and the step summary on the
# pull request's checks tab, so neither needs the log opening.
fph_announce() {
    level=$1; title=$2; message=$3
    printf '::%s title=%s::%s\n' "$level" "$title" "$message"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf -- '- **%s** — %s\n' "$title" "$message" >> "$GITHUB_STEP_SUMMARY"
    fi
}
