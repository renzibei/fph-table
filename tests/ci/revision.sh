# Shared "build this revision and the one it is based on, side by side" logic.
# Sourced by check-asm.sh and check-counters.sh, never executed on its own.
#
# The whole point of comparing against the merge base built in the same job,
# rather than against a number committed to the repository, is that a compiler
# upgrade moves both sides at once and therefore cannot fail a pull request that
# did not change anything. A checked-in number cannot tell the two apart.

# fph_resolve_base_ref [explicit] -- decide which revision to compare against.
#
# Order of preference:
#   1. the argument, if given
#   2. $FPH_CI_BASE_REF          -- what the workflow sets from the PR payload
#   3. merge-base with origin/master, then master
#   4. HEAD~1                    -- so a local `git commit; check` loop works
fph_resolve_base_ref() {
    explicit=${1:-}
    if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
    if [ -n "${FPH_CI_BASE_REF:-}" ]; then printf '%s\n' "$FPH_CI_BASE_REF"; return 0; fi
    for candidate in origin/master master origin/main main; do
        if git -C "$FPH_ROOT" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
            if base=$(git -C "$FPH_ROOT" merge-base HEAD "$candidate" 2>/dev/null); then
                # Comparing HEAD against itself is a no-op, not an error: it just
                # means the branch has not diverged yet.
                printf '%s\n' "$base"
                return 0
            fi
        fi
    done
    if git -C "$FPH_ROOT" rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1; then
        printf '%s\n' "$(git -C "$FPH_ROOT" rev-parse HEAD~1)"
        return 0
    fi
    return 1
}

# fph_materialise_base <ref> <dir> -- put <ref>'s include/ tree at <dir>.
# Only include/ is used: the probes and the scripts always come from the head
# revision, so that a base revision predating tests/ci can still be measured.
fph_materialise_base() {
    ref=$1; dir=$2
    mkdir -p "$dir"
    if git -C "$FPH_ROOT" archive "$ref" include | tar -x -C "$dir" 2>/dev/null; then
        return 0
    fi
    fph_error "cannot extract include/ from $ref"
    return 1
}

# fph_change_allowed <commit-marker> <pr-label> -- is an intentional change
# signed off?
#
# Three ways to say yes, all of them visible in the pull request:
#   * the workflow passes --allow-change (which it sets from a PR label)
#   * FPH_CI_PR_LABELS contains the label
#   * any commit message on the branch contains the marker
#
# A gate nobody can override gets disabled instead of used, so the override is
# part of the design rather than a hole in it.
fph_change_allowed() {
    marker=$1
    label=$2
    if [ "${FPH_CI_ALLOW_CHANGE:-0}" = "1" ]; then
        printf 'flag\n'; return 0
    fi
    case " ${FPH_CI_PR_LABELS:-} " in
        *" $label "*) printf 'label\n'; return 0 ;;
    esac
    if [ -n "${FPH_CI_BASE_REF:-}" ]; then
        range="$FPH_CI_BASE_REF..HEAD"
    else
        range="-1"
    fi
    if git -C "$FPH_ROOT" log $range --format=%B 2>/dev/null | grep -qF "$marker"; then
        printf 'commit-message\n'; return 0
    fi
    return 1
}
