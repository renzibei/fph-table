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
# The file the name resolves to is not the identity either. Under a ccache or
# distcc masquerade directory every compiler name is a link to one wrapper that
# dispatches on argv[0], so two genuinely different compilers share one path and
# one inode. Measured: a masquerade directory whose g++ is gcc 15 and whose
# clang++ is Apple clang 21 made compile-matrix.sh drop clang++ and report "all
# 3 matrix cells passed" for a 6-cell run.
#
# What is compared instead is the compiler's own answer: its target triple and
# its predefined macros, which carry the family, the version and the standard
# library. Two names for one compiler produce the same answer; gcc 13 and gcc 14
# do not, and neither do the two ends of a masquerade.
fph_compiler_identity() {
    cxx=$1
    macros=$(printf '' | "$cxx" -x c++ -E -dM - 2>/dev/null) || macros=""
    if [ -n "$macros" ]; then
        triple=$("$cxx" -dumpmachine 2>/dev/null) || triple=""
        sum=$(printf '%s\n' "$macros" | LC_ALL=C sort | cksum | awk '{ print $1 "-" $2 }')
        printf 'macros:%s:%s\n' "$triple" "$sum"
        return 0
    fi
    # A compiler that will not report its macros still has to be told apart from
    # the others, so fall back to the file it resolves to.
    resolved=$(command -v "$cxx" 2>/dev/null) || resolved=$cxx
    printf 'path:%s\n' "$resolved"
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

# fph_report_only -- is this run reporting rather than gating?
#
# Set by the workflow when the commit under test has already landed on the
# default branch: every push to it, and a manual run on it. Such a run carries
# no pull request and so no labels. Without this, merging a pull request whose
# gate was signed off turns master red on the very next run: the push re-measures
# the same difference and finds no label to waive it. The manual case is the same
# state reached by hand, and was red until the workflow counted it too.
#
# It covers a measured difference and nothing else. A measurement that could not
# be taken -- a probe that will not build against this revision, a compiler that
# is not installed, an empty disassembly -- fails whatever the event.
fph_report_only() {
    case "${FPH_CI_REPORT_ONLY:-}" in
        1|true|TRUE|yes) return 0 ;;
    esac
    return 1
}

# fph_base_side_unbuildable <gate> <label> <base> -- the base revision will not
# compile this revision's probe.
#
# The probe sources always come from this revision, so this is what a pull
# request that adds public API and exercises it in a probe looks like. Nothing
# can be compared, and without a way through, such a pull request cannot land.
#
# Unlike the other ways a measurement fails, this one is expected on the push
# that merges such a pull request: the base is then the master before the merge,
# which by definition does not have the new API. Reproduced -- without the
# report-only branch below, merging it turns master red with exit 2.
#
# Two things have to be true before a caller may reach this, and both are
# properties of the caller rather than of anything checked here:
#
#   the head side has already been built and measured, so the compiler and the
#   probe are known to work and the failure can only be the base tree. A gate
#   that builds the base side first turns a broken probe and a broken compiler
#   into this, and this into exit 0;
#
#   the base tree came out of fph_materialise_base, which counts the files it
#   extracted against the ref's own tree, so a truncated extraction is not
#   passed off as a base that predates the change.
fph_base_side_unbuildable() {
    gate=$1; label=$2; base=$3
    if reason=$(fph_gate_waived "$label"); then
        fph_announce warning "$gate did not run" \
            "the probe builds and runs against this revision but not against $base, so nothing was compared. Signed off by $reason."
        exit 0
    fi
    if fph_report_only; then
        fph_announce warning "$gate did not run" \
            "the probe builds and runs against this revision but not against $base, so nothing was compared. This run reports an already-landed commit, and the base predates the change."
        exit 0
    fi
    fph_error "the probe built from this revision does not compile against $base"
    fph_error "the probe sources always come from this revision, so a base side that will not"
    fph_error "build means this change adds or renames API the base does not have. Nothing"
    fph_error "was compared. Either:"
    fph_error "  * land the API first and add the probe's use of it in a later pull request, or"
    fph_error "  * say that this pull request cannot be compared, with the $label label"
    exit 2
}
