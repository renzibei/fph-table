# Shared "build this revision and the one it is based on, side by side" logic.
# Sourced by the gate scripts, never executed on its own.

# fph_resolve_base_ref [explicit] -- decide which revision to compare against.
#
# Order of preference:
#   1. the argument, if given    -- a revision, used exactly as written
#   2. $FPH_CI_BASE_REF          -- a revision; the workflow sets it on a push
#   3. $FPH_CI_BASE_BRANCH       -- a branch; the merge base with it. The
#                                   workflow sets it on a pull request.
#   4. the merge base with origin/master, then master
#   5. HEAD~1, when the merge base above is HEAD itself
#
# Prints the resolved sha and returns 0. Returns 3 for "no base was named",
# which the caller announces and finishes without a measurement. Returns 1 when
# a base WAS named and cannot be found, or names this same revision: either is a
# broken configuration rather than an absent predecessor, and it fails.
#
# On a pull request the base has to be the merge base and not the base sha from
# the event payload. That sha is a snapshot taken when the payload was written,
# while refs/pull/N/merge is recomputed whenever the target branch moves, so as
# soon as master advances the two disagree and the gate charges the pull request
# with master's change. Reproduced: a comment-only pull request failed the asm
# gate for a mask change that had landed on master after it was opened.
#
# A base that resolves to HEAD measures nothing: building the same revision
# twice produces an identical result whatever the revision contains. What that
# means depends on who chose it. Worked out here, it is reported as 3 and the
# gate announces that it had nothing to compare against. Named by a person or by
# the workflow, it is a broken configuration and fails, the same way a named base
# that does not exist does. Reproduced: a manual run on master with `base:
# master` in the dispatch form. actions/checkout makes a local master at HEAD,
# so the name resolved to this same revision, and every gate announced "no
# revision to compare against ... expected only on the first push of a branch"
# and exited 0 having measured nothing.
#
# The one exception, for either channel, is a dirty working tree: there the head
# side is the files on disk and the base side is HEAD, which is a real
# comparison, and that is the local edit-and-check loop.
fph_resolve_base_ref() {
    explicit=${1:-}
    candidate=""
    named=0

    if [ -n "$explicit" ]; then
        candidate=$explicit
        named=1
    elif [ -n "${FPH_CI_BASE_REF:-}" ]; then
        candidate=$FPH_CI_BASE_REF
        named=1
    elif [ -n "${FPH_CI_BASE_BRANCH:-}" ]; then
        # A checkout has the branch as a remote-tracking ref, not a local one.
        for probe in "origin/$FPH_CI_BASE_BRANCH" "$FPH_CI_BASE_BRANCH"; do
            if git -C "$FPH_ROOT" rev-parse --verify --quiet "$probe" >/dev/null 2>&1; then
                if candidate=$(git -C "$FPH_ROOT" merge-base HEAD "$probe" 2>/dev/null); then
                    break
                fi
                candidate=""
            fi
        done
        if [ -z "$candidate" ]; then
            fph_error "no merge base between HEAD and the base branch $FPH_CI_BASE_BRANCH"
            return 1
        fi
    else
        for probe in origin/master master origin/main main; do
            if git -C "$FPH_ROOT" rev-parse --verify --quiet "$probe" >/dev/null 2>&1; then
                if candidate=$(git -C "$FPH_ROOT" merge-base HEAD "$probe" 2>/dev/null); then
                    break
                fi
                candidate=""
            fi
        done
        # On master itself the merge base IS HEAD, which measures nothing. The
        # useful comparison there is the commit before, which is also what a
        # local `git commit; check` loop wants. Not when the tree is dirty:
        # there HEAD is the right base and the edits on disk are the head side.
        if [ -z "$candidate" ] ||
                { [ "$candidate" = "$(git -C "$FPH_ROOT" rev-parse HEAD 2>/dev/null)" ] &&
                  git -C "$FPH_ROOT" diff --quiet HEAD -- include 2>/dev/null; }; then
            if git -C "$FPH_ROOT" rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1; then
                candidate=HEAD~1
            fi
        fi
    fi

    # A push that creates a branch reports an all-zero "before" sha; nothing at
    # all is what a repository with a single commit resolves to.
    case "$candidate" in
        ''|0000000000000000000000000000000000000000) return 3 ;;
    esac

    if ! sha=$(git -C "$FPH_ROOT" rev-parse --verify --quiet "$candidate^{commit}" 2>/dev/null); then
        fph_error "the base revision $candidate is not in this checkout"
        fph_error "a named base that cannot be found is a broken configuration, not an absent one"
        return 1
    fi

    if [ "$sha" = "$(git -C "$FPH_ROOT" rev-parse HEAD 2>/dev/null)" ] &&
            git -C "$FPH_ROOT" diff --quiet HEAD -- include 2>/dev/null; then
        if [ "$named" = 1 ]; then
            fph_error "the base $candidate is this same revision, so there is nothing to compare"
            fph_error "a checkout puts the branch you are on at HEAD, so naming that branch -- master,"
            fph_error "on a manual run of the workflow on master -- names this revision. Name a"
            fph_error "revision that is not HEAD (a sha, HEAD~1, origin/master from a branch), or"
            fph_error "leave it empty and let the script take the merge base, and on master the"
            fph_error "commit before"
            return 1
        fi
        return 3
    fi

    printf '%s\n' "$sha"
    return 0
}

# fph_no_base <gate> -- there is nothing to compare against.
#
# This is the one sanctioned way for a gate to finish without a measurement, and
# it happens on exactly one path: a push whose predecessor does not exist or is
# this same revision. Push-triggered runs report a commit that has already
# landed, so they cannot hold anything back anyway. It is announced rather than
# passed over quietly.
fph_no_base() {
    fph_announce warning "$1 did not run" \
        "no revision to compare against, so nothing was measured. This is expected only on the first push of a branch."
}

# fph_materialise_base <ref> <dir> -- put <ref>'s include/ tree at <dir>.
# Only include/ is used: the probes and the scripts always come from the head
# revision, so that a base revision predating tests/ci can still be measured.
#
# What comes out is checked, because a base tree that is short of a file or has
# one truncated does not announce itself: it fails to compile, and a base side
# that fails to compile is what the gates read as "this change adds API the base
# does not have" -- a warning and exit 0 on a push. Reproduced by cutting the
# archive stream short: tar exited 1 with meta_fph_table.h half written, the old
# `|| :` dropped that status, the directory was not empty so the tree check
# passed, and the counter gate reported "the base predates the change" and
# exited 0.
#
#   * git archive's status, taken on its own rather than through a pipeline,
#     where the shell reports only the last command
#   * the end-of-archive marker, so the stream is known to be whole
#   * tar's status, both listing and extracting, likewise
#   * every member the archive says it holds arrived on disk
#
# The expected count is the archive's own manifest, not `git ls-tree`. What has
# to arrive is what git archive decided to emit, and the two disagree for three
# reasons that are nobody's mistake. Each reproduced, each with a complete and
# correct extraction that the ls-tree count called incomplete:
#
#   a symlink under include/ -- mode 120000. It arrives as a symlink, and the
#   old `find -type f` did not count it: 3 expected, 2 arrived;
#
#   a submodule under include/ -- mode 160000. git archive materialises a
#   gitlink as an empty directory and no file at all: 3 expected, 2 arrived;
#
#   `export-ignore` in .gitattributes on a path under include/ -- which the
#   archive omits on purpose: 3 expected, 2 arrived.
#
# None of the three could be waived. This runs before the gates consult a label,
# --allow-change or report-only, so every one of them was an unwaivable exit 2
# on every pull request and every push, with a message blaming the runner. Worse,
# the pull request that ADDS the symlink stays green -- the head side is a plain
# checkout and never comes through here -- so the failure starts on the next
# commit and does not stop. Counting what the archive holds cannot disagree with
# what the archive emitted.
#
# A manifest on its own would be weaker than what it replaces, because it
# describes only the bytes that arrived: measured, a stream cut at a member
# boundary (3072 bytes, after a.h's last data block and before b.h's header)
# left bsdtar happy on both the listing and the extraction, and the manifest
# then agreed with the disk at one file each. Exit 0, and a base tree with a
# header missing. So completeness is checked where it belongs, on the stream:
# a tar ends with an end-of-archive marker of zero blocks, and git archive pads
# that to a full 10240-byte record, so a cut anywhere in the members leaves
# something other than zeroes in the last block. Measured on the same four cuts:
# 180, 102, 102 and 7 non-zero bytes in the final 1024.
#
# The acceptance direction is unchanged:
#
#   a truncated stream       -- git archive's status, the end-of-archive marker,
#                               then tar's status on the listing and the
#                               extraction
#   an empty extraction      -- the directory check below, and want == 0
#   a case collision         -- two names differing only in case on a
#                               case-insensitive filesystem: the manifest holds
#                               two members and one file arrives
#
# Not a content check: the extracted tree is allowed to differ from this
# revision's, since that difference is the whole point of the comparison.
fph_materialise_base() {
    ref=$1; dir=$2
    mkdir -p "$dir"
    if ! git -C "$FPH_ROOT" archive --format=tar "$ref" include \
            >"$dir/base.tar" 2>"$dir/archive.err"; then
        fph_error "git archive could not read include/ out of $ref"
        sed 's/^/  /' "$dir/archive.err" >&2
        return 1
    fi
    # The end-of-archive marker: a whole tar ends in zero blocks, and git pads
    # them out to a full record, so every complete archive ends in at least 1024
    # zero bytes and a cut stream does not. Counted through tr rather than read
    # into a variable, because a command substitution drops NUL bytes itself.
    if [ "$(tail -c 1024 "$dir/base.tar" | tr -d '\000' | wc -c | tr -d ' ')" != "0" ]; then
        fph_error "the archive of include/ from $ref stops without its end-of-archive marker"
        fph_error "the stream was cut short, so nothing was compared. This is a broken extraction,"
        fph_error "not a difference between revisions"
        return 1
    fi
    # Read back before extracting: this is the list of members that have to be
    # on disk afterwards. Both GNU tar and bsdtar print a directory member with
    # a trailing slash and hide the pax global header git writes first, and that
    # header is not under include/ in either case, so the prefix and the slash
    # between them select exactly the members that must become a file or a link.
    if ! tar -t -f "$dir/base.tar" >"$dir/manifest.txt" 2>"$dir/list.err"; then
        fph_error "the archive of include/ from $ref cannot be read back"
        sed 's/^/  /' "$dir/list.err" >&2
        return 1
    fi
    if ! tar -x -f "$dir/base.tar" -C "$dir" 2>"$dir/tar.err"; then
        fph_error "extracting include/ from $ref failed part way through"
        sed 's/^/  /' "$dir/tar.err" >&2
        return 1
    fi
    rm -f "$dir/base.tar"
    # bsdtar exits 0 on empty input, so on macOS a ref that produces nothing
    # gets this far with an empty directory and a clean status.
    if [ ! -d "$dir/include" ] || [ -z "$(ls -A "$dir/include" 2>/dev/null)" ]; then
        fph_error "extracting include/ from $ref produced nothing"
        return 1
    fi
    want=$(awk '/^include\// && !/\/$/ { n++ } END { print n + 0 }' "$dir/manifest.txt")
    if [ "$want" -eq 0 ]; then
        fph_error "the archive of include/ from $ref holds no file at all, so there is no base tree to compare against"
        return 1
    fi
    got=$(find "$dir/include" \( -type f -o -type l \) | wc -l | tr -d ' ')
    if [ "$want" != "$got" ]; then
        fph_error "the archive of include/ from $ref holds $want file(s) and $got arrived; the base tree is incomplete"
        fph_error "nothing was compared. This is a broken extraction, not a difference between revisions"
        return 1
    fi
    return 0
}
