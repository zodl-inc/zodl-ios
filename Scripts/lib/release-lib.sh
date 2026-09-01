# shellcheck shell=bash
#
# Shared helpers for the release scripts. Source this; do not execute it.
#
#   . "$(dirname "$0")/lib/release-lib.sh"
#
# Everything here is either a pure text transform or a preflight predicate, so
# that Scripts/test/release_lib.bats can exercise it without a network, a git
# remote, or a GitHub token.
#
# Written for bash 3.2, which is what macOS ships.

# Paths, relative to the repository root.
# shellcheck disable=SC2034  # PBXPROJ is consumed by the sourcing scripts.
PBXPROJ="secant.xcodeproj/project.pbxproj"
# The version bump is delegated rather than reimplemented. This script selects
# non-test targets from the project's object graph instead of by name, edits
# atomically, and lints the result before replacing the file -- none of which a
# sed over the pbxproj would preserve.
SET_VERSION_TOOL=".claude/skills/update-app-version/scripts/set_version.py"

# Set by each subcommand's argument parsing.
DRY_RUN="${DRY_RUN:-false}"

# ------------------------------------------------------------------ output

step() { echo; echo "==> $*"; }

die() {
    echo "error: $1" >&2
    shift
    while [ $# -gt 0 ]; do echo "       $1" >&2; shift; done
    exit 1
}

warn() {
    echo "warning: $1" >&2
    shift
    while [ $# -gt 0 ]; do echo "         $1" >&2; shift; done
}

# A precondition that only a real run has to satisfy: fatal normally, advisory
# under --dry-run. Reserved for checks nothing in the dry run itself depends on,
# so that a rehearsal still reports the problem rather than refusing to start.
# A check the dry run does depend on must stay fatal: silencing it there only
# relocates the failure to a message that blames the wrong thing.
die_unless_dry_run() {
    if [ "$DRY_RUN" = "true" ]; then
        warn "$@"
    else
        die "$@"
    fi
}

# Run a command, or describe it under --dry-run. Only state-changing commands
# go through this: preflight reads run unconditionally, so a dry run still
# reports what it found rather than what it assumed.
#
# Named run_cmd rather than the obvious `run` because bats defines its own
# `run`, and a library that shadows it silently swallows the exit status of
# every assertion in its own test suite.
run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        # %q per argument, so the description is the command: `git commit -m
        # Bump version ...` unquoted names a different command than the one a
        # real run executes.
        printf '  would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# ----------------------------------------------------------------- versions

# Semver ordering as a filter. GNU `sort -V` ranks 3.11.0-rc.1 *above* 3.11.0,
# which is backwards: a pre-release precedes its release. Mapping '-' to '~'
# fixes it, because sort -V treats '~' as lower than the empty string.
version_sort() { sed 's/-/~/' | sort -V | sed 's/~/-/'; }

# True when $1 <= $2 under that ordering.
version_le() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | version_sort | head -1)" = "$1" ]
}

# A release tag is exactly X.Y.Z, which is also what linear-release.yml triggers
# on. Matching that shape rather than a leading digit is what keeps beta4-rc2,
# release-baseline-2026-08-08 and test-0.0.1-42 out of the running when the
# previous release is detected.
RELEASE_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# The release tags reachable from a revision, oldest first. Only reachable tags
# are candidates: a tag on a line this revision does not descend from is not a
# release it can succeed. grep exits 1 when nothing matches, which pipefail
# would escalate into killing the caller under set -e -- an empty list is an
# answer here, not a failure.
release_tags_merged_into() {
    git tag --list --merged "$1" | { grep -E "$RELEASE_TAG_RE" || true; } | version_sort
}

# The newest release tag in the repository, reachable or not. Empty when no
# release has ever been tagged.
newest_release_tag() {
    git tag --list | { grep -E "$RELEASE_TAG_RE" || true; } | version_sort | tail -1
}

# owner/repo from any form of GitHub remote URL: scp-style ssh, ssh://, or
# https, with or without a .git suffix.
repo_slug_from_url() {
    printf '%s\n' "$1" | sed -E \
        -e 's|\.git$||' \
        -e 's|^[a-z+]+://||' \
        -e 's|^[^/@]+@||' \
        -e 's|^[^/:]+[:/]||'
}

# ---------------------------------------------------------------- CHANGELOG

# True when the Unreleased section carries at least one entry. The section is
# subdivided into `### Added` / `### Changed` / ... headings, so a bullet is
# what counts as an entry -- an empty `### Fixed` left behind by a previous
# release is not one. Entries are written as part of the commit that makes each
# change, so an empty section means they were forgotten, which is far more
# likely than a genuinely invisible release.
changelog_unreleased_nonempty() {
    awk '
        /^## \[Unreleased\]/ { f = 1; next }
        f && /^## /          { exit }
        f && /^[-*] /        { found = 1 }
        END { exit !found }
    ' "$1"
}

# Insert a dated release heading below `## [Unreleased]`, leaving the entries
# where they are. `## [Unreleased]` itself stays, and becomes empty. Never
# generates text.
promote_changelog() {
    local file="$1" version="$2" date="$3" tmp
    tmp="$(mktemp)"
    if ! awk -v ver="$version" -v date="$date" '
        !changed && /^## \[Unreleased\]/ {
            print
            print ""
            print "## [" ver "] - " date
            changed = 1
            next
        }
        { print }
        END { if (!changed) exit 1 }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # Overwrite in place rather than mv: mktemp files are 0600, and the
    # CHANGELOG keeps whatever mode it already has. The write's status must
    # decide the function's -- left bare, the rm below would mask a failed
    # (or truncated) write as a successful promotion.
    if ! cat "$tmp" > "$file"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

# True when the file already carries a heading for this version, in either the
# current `## [X.Y.Z] - DATE` form or the legacy `## X.Y.Z build N (DATE)` one.
# Both are published history, so a second heading for the same version must not
# be introduced.
changelog_has_version() {
    local escaped
    # The version is interpolated into a regex, so its dots must not match
    # arbitrary characters: 3.10.2 would otherwise find a heading for 3x10y2.
    escaped="$(printf '%s\n' "$2" | sed 's/\./\\./g')"
    grep -qE "^## (\[${escaped}\]|${escaped}( |\$))" "$1"
}

# ------------------------------------------------------------------ project

# Set MARKETING_VERSION and CURRENT_PROJECT_VERSION for every non-test target.
set_project_version() {
    python3 "$SET_VERSION_TOOL" set --marketing "$1" --build "$2"
}

# ----------------------------------------------------------------- preflight

require_clean_tree() {
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        die "the working tree has uncommitted changes." \
            "Commit or stash them before releasing."
    fi
}

require_remote() {
    if ! git remote get-url "$1" >/dev/null 2>&1; then
        die "no such remote '$1'." "Available remotes: $(git remote | tr '\n' ' ')"
    fi
}

# $1 names how to report a failure, defaulting to `die`. Callers whose
# --dry-run path makes no authenticated call pass `die_unless_dry_run`, so a
# rehearsal reports the problem instead of refusing to run.
require_gh_auth() {
    local report="${1:-die}"
    if ! command -v gh >/dev/null 2>&1; then
        "$report" "the GitHub CLI (gh) is not installed." \
            "See https://cli.github.com/"
        return
    fi
    if ! gh auth status >/dev/null 2>&1; then
        "$report" "gh is not authenticated." "Run: gh auth login"
    fi
}

# The version bump reads the Xcode project's object graph through plutil, which
# ships with macOS only. Reported the same way as gh authentication: advisory
# under --dry-run, which changes no versions, so the rest of the plan can still
# be rehearsed from a machine that could never carry it out.
require_version_tool() {
    local report="${1:-die}"
    if [ ! -f "$SET_VERSION_TOOL" ]; then
        "$report" "${SET_VERSION_TOOL} is missing." \
            "It sets MARKETING_VERSION and CURRENT_PROJECT_VERSION for every non-test target."
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        "$report" "python3 is not installed; ${SET_VERSION_TOOL} cannot run."
        return
    fi
    if ! command -v plutil >/dev/null 2>&1; then
        "$report" "plutil was not found, so the version bump cannot run here." \
            "It reads the Xcode project's object graph, and ships with macOS only." \
            "Cut the release from a Mac."
    fi
}

# The repository a remote points at. Everything reaching GitHub goes through
# this rather than a hardcoded slug, so a rehearsal against a fork stays inside
# the fork instead of reaching the canonical repository.
repo_for_remote() { repo_slug_from_url "$(git remote get-url "$1")"; }
