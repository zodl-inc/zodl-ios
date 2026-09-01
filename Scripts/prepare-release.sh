#!/usr/bin/env bash
#
# prepare-release.sh: cut a release for review.
#
#   start  Cut release/X.Y.Z from the previous release tag and candidate/X.Y.Z
#          from the revision being released, promote the CHANGELOG, record the
#          new version, and open a pull request from candidate into release.
#          That PR's diff is exactly what users receive relative to the previous
#          release, with none of the intervening history.
#
# Building and uploading is a separate concern, handled by Scripts/release.sh
# against candidate/X.Y.Z. Tagging and the back-merge stay manual for now.
#
# Run `./Scripts/prepare-release.sh <subcommand> --help` for the options of
# each phase.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=Scripts/lib/release-lib.sh
. "Scripts/lib/release-lib.sh"

usage() {
    cat <<'EOF'
Usage: ./Scripts/prepare-release.sh <subcommand> [options]

Subcommands:
  start  Cut the release branches, record the version, and open the pull request.

Run `./Scripts/prepare-release.sh start --help` for details.
EOF
}

usage_start() {
    cat <<'EOF'
Usage: ./Scripts/prepare-release.sh start [options] <remote> <version> [<revision>]

Creates release/X.Y.Z from the previous release tag and pushes it; creates
candidate/X.Y.Z from the revision being released; promotes the CHANGELOG's
Unreleased section; records the version in the Xcode project; and opens a pull
request from the candidate branch into the release branch.

Basing the release branch on the previous release tag is what makes the pull
request worth reviewing: its diff is exactly what users receive relative to the
last release, rather than the intervening development history.

Arguments:
  <remote>    git remote for the repository being released, e.g. upstream
  <version>   version being released, e.g. 3.11.0
  <revision>  commit or branch holding the changes to release
              (default: current HEAD)

Options:
  --issue <N>       release tracking issue, referenced from the PR body.
  --build <N>       build number to record alongside the version (default: 1).
                    Build numbers are a per-variant App Store Connect sequence,
                    and Scripts/release.sh passes its own --build at archive
                    time, so this is only the project's recorded starting point.
  --previous <tag>  base the release branch on this tag rather than the detected
                    one. Use when the newest tag reachable from <revision> is not
                    the release you are following.
  --dry-run         print what would happen and change nothing.
EOF
}

# --------------------------------------------------------------------- start

# The body of the pull request. It has to carry enough context that a reviewer
# arriving cold knows what they are looking at and why the base branch looks
# the way it does.
start_pr_body() {
    local version="$1" prev_tag="$2" issue="$3"
    if [ -n "$issue" ]; then
        printf 'Release tracking issue: #%s.\n\n' "$issue"
    fi
    cat <<EOF
Release \`${version}\`, following \`${prev_tag}\`.

The base of this pull request is \`release/${version}\`, which starts out
identical to \`${prev_tag}\`. Its diff is therefore exactly what users receive
relative to the last release, rather than the intervening development history.

On top of the released content this branch carries:

- the CHANGELOG's Unreleased section, promoted to \`## [${version}]\`;
- \`MARKETING_VERSION\` and \`CURRENT_PROJECT_VERSION\`, set across every
  non-test target.

## Do not merge before the build has shipped

TestFlight and App Store builds for this release are made from
\`candidate/${version}\`, the head of this pull request:

    ./Scripts/release.sh --variant internal-testnet --ref candidate/${version} \\
        --version ${version} --build <n>

Fixes found in testing land on \`candidate/${version}\` and appear here. This
pull request stays a **draft** while builds are in progress; marking it ready
for review is part of declaring the release final, and merging it is what makes
it final. Tag \`release/${version}\` afterwards, then merge it back into
\`maint/v${version%.*}.x\` and forward to \`main\` so the tag stays reachable.
EOF
}

cmd_start() {
    local previous="" issue="" build="1" remote version revision rev_sha prev_tag newest_tag
    local release_branch candidate_branch b today pr_body_file changelog_at_rev
    local -a positional
    positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)    issue="${2:?--issue needs an issue number}"; shift 2 ;;
            --build)    build="${2:?--build needs a build number}"; shift 2 ;;
            --previous) previous="${2:?--previous needs a tag}"; shift 2 ;;
            --dry-run)  DRY_RUN=true; shift ;;
            -h|--help)  usage_start; return 0 ;;
            --*)        usage_start >&2; die "unknown option '$1'" ;;
            *)          positional+=("$1"); shift ;;
        esac
    done

    if [ "${#positional[@]}" -lt 2 ]; then
        usage_start >&2
        die "start needs a remote and a version."
    fi
    if [ "${#positional[@]}" -gt 3 ]; then
        usage_start >&2
        die "unexpected argument '${positional[3]}'."
    fi
    remote="${positional[0]}"
    version="${positional[1]#v}"
    revision="${positional[2]:-HEAD}"

    if ! printf '%s\n' "$version" | grep -qE "$RELEASE_TAG_RE"; then
        die "version '${version}' is not in X.Y.Z form."
    fi
    if ! printf '%s\n' "$build" | grep -qE '^[0-9]+$'; then
        die "build '${build}' is not an integer."
    fi

    step "Checking preconditions"
    require_clean_tree
    require_remote "$remote"
    # Advisory under --dry-run: a dry run reaches GitHub nowhere and changes no
    # versions, so an unauthenticated rehearsal on a machine without plutil can
    # still show the whole plan.
    require_gh_auth die_unless_dry_run
    require_version_tool die_unless_dry_run

    GH_REPO="$(repo_for_remote "$remote")"
    export GH_REPO
    echo "  repository: ${GH_REPO}"

    echo "  fetching ${remote} ..."
    if ! git fetch --tags "$remote" >/dev/null 2>&1; then
        die "git fetch ${remote} failed." \
            "Every check below compares against ${remote}; running them on" \
            "stale refs would report agreement that does not exist."
    fi

    rev_sha="$(git rev-parse --verify "${revision}^{commit}")"
    echo "  releasing the content of ${revision} ($(git rev-parse --short "$rev_sha"))"

    if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
        die "${version} is already tagged; pick a new version."
    fi

    step "Determining the release base"
    if [ -n "$previous" ]; then
        prev_tag="$previous"
        if ! git rev-parse -q --verify "refs/tags/${prev_tag}" >/dev/null; then
            die "no such tag '${prev_tag}'."
        fi
        # The release branch starts at this tag and the PR diff is everything
        # between it and the revision -- meaningless, and silently destructive
        # in the merge, unless the tag is part of the revision's history.
        if ! git merge-base --is-ancestor "refs/tags/${prev_tag}" "$rev_sha"; then
            die "--previous ${prev_tag} is not an ancestor of ${revision}." \
                "The release branch must start from a commit the revision builds on." \
                "Merge the ${prev_tag} release back into the line you are cutting from first."
        fi
        echo "  using --previous ${prev_tag}"
    else
        prev_tag="$(release_tags_merged_into "$rev_sha" | tail -1)"
        if [ -z "$prev_tag" ]; then
            die "no release tags are reachable from ${revision}." \
                "Pass --previous <tag> to say which release this follows."
        fi
        newest_tag="$(newest_release_tag)"
        if [ "$newest_tag" != "$prev_tag" ]; then
            die "the newest release tag is ${newest_tag}, but it is not reachable from ${revision}." \
                "Cutting over ${prev_tag} would silently drop what ${newest_tag} shipped." \
                "Merge release/${newest_tag} back into its line first (the Release Merged" \
                "Back check reports this), or pass --previous to choose the base deliberately."
        fi
        echo "  newest release reachable from ${revision}: ${prev_tag}"
    fi

    if version_le "$version" "$prev_tag"; then
        die "${version} does not come after ${prev_tag}."
    fi

    release_branch="release/${version}"
    candidate_branch="candidate/${version}"
    for b in "$release_branch" "$candidate_branch"; do
        if git rev-parse -q --verify "refs/heads/${b}" >/dev/null; then
            die "branch ${b} already exists locally." \
                "This usually means a previous 'start' for ${version} stopped before its" \
                "single push near the end -- nothing is on ${remote} until then. Delete the" \
                "local leftovers and re-run:" \
                "" \
                "  git branch -D ${release_branch} ${candidate_branch}"
        fi
        # Checked separately from the local branches: this checkout no longer
        # having them says nothing about the remote, where a completed (or
        # merely PR-less) run leaves both.
        if git ls-remote --exit-code --heads "$remote" "refs/heads/${b}" >/dev/null 2>&1; then
            die "branch ${b} already exists on ${remote}." \
                "A previous 'start' for ${version} pushed it -- the branches are pushed" \
                "together, so its twin is there too. If only the pull request is missing," \
                "open it by hand (see start_pr_body for the body text); otherwise delete" \
                "both branches on ${remote} and re-run."
        fi
    done

    step "Checking the CHANGELOG"
    # Both guards read CHANGELOG.md as it stands at the revision being
    # released -- the content the promotion will operate on -- never the
    # working tree, which is an unrelated checkout when <revision> is explicit
    # (and under --dry-run is never switched at all).
    changelog_at_rev="$(mktemp)"
    if ! git show "${rev_sha}:CHANGELOG.md" > "$changelog_at_rev" 2>/dev/null; then
        rm -f "$changelog_at_rev"
        die "CHANGELOG.md does not exist at ${revision}."
    fi
    if changelog_has_version "$changelog_at_rev" "$version"; then
        rm -f "$changelog_at_rev"
        die "CHANGELOG.md at ${revision} already carries a heading for ${version}." \
            "Published headings are the historical record of what shipped;" \
            "a second one for the same version must not be added."
    fi
    if ! changelog_unreleased_nonempty "$changelog_at_rev"; then
        rm -f "$changelog_at_rev"
        die "the Unreleased section of CHANGELOG.md at ${revision} has no entries." \
            "Every user-visible change needs one before release."
    fi
    rm -f "$changelog_at_rev"
    echo "  the Unreleased section has entries to promote"

    echo
    echo "  ${release_branch}    <- ${prev_tag}  (PR base)"
    echo "  ${candidate_branch}  <- ${revision}  (release prep goes here)"

    step "Creating ${release_branch} from ${prev_tag}"
    run_cmd git branch "$release_branch" "refs/tags/${prev_tag}"

    step "Creating ${candidate_branch} from ${revision}"
    run_cmd git switch -c "$candidate_branch" "$rev_sha"

    step "Promoting the CHANGELOG"
    today="$(date +%Y-%m-%d)"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  would insert '## [${version}] - ${today}' below '## [Unreleased]'"
    else
        if ! promote_changelog CHANGELOG.md "$version" "$today"; then
            die "CHANGELOG.md has no '## [Unreleased]' heading to promote." \
                "Nothing has been pushed. To retry: git switch -, then" \
                "git branch -D ${release_branch} ${candidate_branch}, fix, and re-run."
        fi
        echo "  ## [${version}] - ${today}"
    fi
    run_cmd git add CHANGELOG.md
    run_cmd git commit -m "Promote CHANGELOG for ${version}"

    step "Recording version ${version} (${build})"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  would set MARKETING_VERSION and CURRENT_PROJECT_VERSION for every non-test target"
    else
        if ! set_project_version "$version" "$build"; then
            # Leave the tree as the CHANGELOG commit left it, so the re-run
            # described below starts clean.
            git checkout -- "$PBXPROJ"
            die "${SET_VERSION_TOOL} failed; ${PBXPROJ} is unchanged." \
                "Its own message above says which target or key is at fault." \
                "Nothing has been pushed. To retry: git switch -, then" \
                "git branch -D ${release_branch} ${candidate_branch}, fix, and re-run."
        fi
        if git diff --quiet -- "$PBXPROJ"; then
            # set_version.py rewrites unconditionally and reports success even
            # when every value already matched; committing nothing would kill
            # the script with only git's own "nothing to commit" as a clue.
            die "the project is already at ${version} (${build}); there is no bump to commit." \
                "The revision already carries this release's version -- re-releasing a prior" \
                "candidate's content needs a fresh version or build number." \
                "Nothing has been pushed. To retry: git switch -, then" \
                "git branch -D ${release_branch} ${candidate_branch}."
        fi
    fi
    run_cmd git add "$PBXPROJ"
    run_cmd git commit -m "Bump version to ${version} (${build})"

    step "Pushing ${release_branch} and ${candidate_branch}"
    # One atomic push, only after every piece of local work has succeeded:
    # either both branches land on ${remote} or neither does, so no failure
    # above or below leaves the remote half-prepared.
    run_cmd git push --atomic -u "$remote" "$release_branch" "$candidate_branch"

    step "Opening the pull request"
    pr_body_file="$(mktemp)"
    start_pr_body "$version" "$prev_tag" "$issue" > "$pr_body_file"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  would open a draft PR ${candidate_branch} -> ${release_branch} on ${GH_REPO}"
        [ -n "$issue" ] && echo "  body would reference issue #${issue}"
        rm -f "$pr_body_file"
    elif gh pr create --repo "$GH_REPO" \
            --base "$release_branch" --head "$candidate_branch" \
            --title "Release ${version}" \
            --draft \
            --body-file "$pr_body_file"; then
        rm -f "$pr_body_file"
    else
        # Opening the pull request is the last step; both branches are already
        # on the remote by this point. Detect the failure explicitly, rather
        # than letting set -e abort with only gh's own output, so the operator
        # knows not to re-push and can open it by hand.
        die "opening the pull request failed." \
            "${release_branch} and ${candidate_branch} are already pushed to ${remote} --" \
            "they do not need re-pushing. Open the pull request by hand:" \
            "" \
            "  gh pr create --repo ${GH_REPO} \\" \
            "      --base ${release_branch} --head ${candidate_branch} \\" \
            "      --title \"Release ${version}\" --draft \\" \
            "      --body-file ${pr_body_file}" \
            "" \
            "(the PR body is already written out at ${pr_body_file})"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        cat <<EOF

Dry run: nothing was changed. ${release_branch} and ${candidate_branch} were
not created, nothing was pushed to ${remote}, and no pull request was opened.
The working tree is untouched -- ${candidate_branch} is not checked out.

A real run would leave a draft pull request open whose diff is exactly what
users get over ${prev_tag}.
EOF
    else
        cat <<EOF

Done. ${release_branch} and ${candidate_branch} are on ${remote}, a draft pull
request is open, and ${candidate_branch} is checked out here.

Review the PR diff: it is exactly what users get over ${prev_tag}. Build from
${candidate_branch}, not from ${release_branch}, which is still ${prev_tag}:

  ./Scripts/release.sh --variant internal-testnet --ref ${candidate_branch} \\
      --version ${version} --build ${build}

Mark the pull request ready for review and merge it once the release is final,
then tag ${release_branch} and merge it back into maint/v${version%.*}.x and
forward to main, so the tag stays reachable from a live branch.
EOF
    fi
}

# ------------------------------------------------------------------ dispatch

main() {
    if [ $# -lt 1 ]; then
        usage >&2
        exit 1
    fi
    case "$1" in
        start)     shift; cmd_start "$@" ;;
        -h|--help) usage ;;
        *)         usage >&2; die "unknown subcommand '$1'" ;;
    esac
}

main "$@"
