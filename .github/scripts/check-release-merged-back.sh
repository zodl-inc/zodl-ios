#!/usr/bin/env bash
#
# Check that every tagged release/ branch has been merged back into its
# maintenance line, and forward down to main.
#
# Usage: check-release-merged-back.sh [pr-base] [pr-ref]
#
#   pr-base   branch a pending change targets; that branch is then evaluated
#             as it would be with the change applied. Omit to check the
#             branches as they stand.
#   pr-ref    the pending change; defaults to HEAD (refs/pull/N/merge in CI).
#
# A release/X.Y.Z branch counts as released only once a release-shaped tag
# (X.Y.Z) points at its tip that is not older than the version in the branch
# name. A branch prepare-release.sh has freshly cut still points at the
# PREVIOUS release's tag, so it is skipped as in-flight until its own tag
# lands. The maintenance line comes from the tag rather than the branch name,
# and both maint/X.Y.x and maint/vX.Y.x spellings of a line are recognised.
#
# Branches resolve under refs/remotes/$REMOTE, which defaults to origin -- what
# CI checks out. Set REMOTE to run this against a local clone whose canonical
# remote has another name, and run `git fetch` first.
#
# Exit codes: 0 = every checked branch is merged back; 1 = advisory findings
# (a tagged release missing from a branch it should be in); 2 = the check
# could not run at all -- refs unreadable, git failing -- which callers must
# not report as a clean result.

set -euo pipefail

PR_BASE="${1:-}"
PR_REF="${2:-HEAD}"
REMOTE="${REMOTE:-origin}"

# RELEASE_TAG_RE, version_sort and version_le come from the release library,
# so the tag shapes this check recognises are the ones the release tooling
# actually cuts.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Scripts/lib/release-lib.sh
. "${SCRIPT_DIR}/../../Scripts/lib/release-lib.sh"

say() {
  printf '%s\n' "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}

# An infrastructure failure: the check could not run. Distinct from findings
# (exit 1) so a caller that treats findings as advisory does not also
# swallow a broken run as green.
infra_fail() {
  say ":stop_sign: the merged-back check could not run: $1"
  echo "error: $1" >&2
  exit 2
}

# Is $1 an ancestor of $2? Status 1 means genuinely not an ancestor; anything
# above 1 means git could not answer (an unresolvable ref, a broken repo),
# which must not be mistaken for a finding.
in_branch() {
  local rc=0
  git merge-base --is-ancestor "$1" "$2" || rc=$?
  [ "$rc" -le 1 ] || infra_fail "git merge-base --is-ancestor '$1' '$2' failed (exit ${rc})"
  return "$rc"
}

# The pending change, resolved once up front: a bad ref argument is an
# infrastructure problem, not a property of any release branch.
PR_SHA=''
if [ -n "$PR_BASE" ]; then
  if ! PR_SHA="$(git rev-parse -q --verify "${PR_REF}^{commit}")"; then
    infra_fail "cannot resolve pr-ref '${PR_REF}'"
  fi
fi

# Maintenance lines in version order, then main. The repo has carried both
# maint/X.Y.x and maint/vX.Y.x spellings, so every maint/* branch is collected
# and ordered by the version it carries, v or no v.
# Enumerated through a checked substitution: a for-each-ref failure must be a
# loud infrastructure error, not an empty chain.
if ! maint_refs="$(git for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/${REMOTE}/maint/*")"; then
  infra_fail "listing refs/remotes/${REMOTE}/maint/* failed"
fi
sorted_maint="$(printf '%s\n' "$maint_refs" | while IFS= read -r b; do
  [ -n "$b" ] || continue
  key="${b#maint/}"
  key="${key#v}"
  printf '%s %s\n' "$key" "$b"
done | sort -k1,1 -V | cut -d' ' -f2)"
CHAIN=()
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  CHAIN+=("$ref")
done <<< "$sorted_maint"
CHAIN+=('main')

# The chain entry that is the maintenance line for X.Y ($1), whichever
# spelling the branch uses; the canonical maint/vX.Y.x when the line is gone.
line_for() {
  local want="$1" b key
  for b in ${CHAIN[@]+"${CHAIN[@]}"}; do
    case "$b" in maint/*) ;; *) continue ;; esac
    key="${b#maint/}"
    key="${key#v}"
    if [ "$key" = "${want}.x" ]; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  printf 'maint/v%s.x\n' "$want"
}

# Resolve a chain branch, substituting the pending change when it targets it.
resolve() {
  if [ -n "$PR_BASE" ] && [ "$1" = "$PR_BASE" ]; then
    printf '%s\n' "$PR_SHA"
  else
    printf '%s/%s\n' "$REMOTE" "$1"
  fi
}

if ! release_refs="$(git for-each-ref --sort=v:refname --format='%(refname:lstrip=3)' "refs/remotes/${REMOTE}/release/*")"; then
  infra_fail "listing refs/remotes/${REMOTE}/release/* failed"
fi

say '## Release branches merged back'
say ''

failed=0
checked=0

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  ref="${REMOTE}/${rel}"

  # Only release-shaped tags mark a release: the repo also multi-tags commits
  # with build tags (0.0.1-42-mainnet) and the odd pre-release, and those must
  # not elect a maintenance line. Of several, the newest wins.
  tag="$(git tag --points-at "$ref" | { grep -E "$RELEASE_TAG_RE" || true; } | version_sort | tail -1)"
  if [ -z "$tag" ]; then
    say ":grey_question: \`${rel}\` has no release tag at its tip; not a released branch, skipped."
    continue
  fi

  # A branch prepare-release.sh has cut but not yet released still points at
  # the previous release's tag: every release tag at its tip is older than the
  # version in its own name. It has released nothing yet, so skip it.
  branch_ver="${rel#release/}"
  if printf '%s\n' "$branch_ver" | grep -qE "$RELEASE_TAG_RE"; then
    if [ "$tag" != "$branch_ver" ] && version_le "$tag" "$branch_ver"; then
      say ":grey_question: \`${rel}\` is freshly cut from \`${tag}\` and not yet released; skipped."
      continue
    fi
  fi

  # X.Y.Z -> its maintenance line.
  major="${tag%%.*}"
  rest="${tag#*.}"
  minor="${rest%%.*}"
  maint="$(line_for "${major}.${minor}")"

  # Its own line is the obligation. Anything downstream of it is merge-forward
  # lag, which the merge-forward jobs already track, so it warns rather than
  # fails; otherwise the merge-back PR itself would report red for main.
  # A retired line is simply absent from the chain.
  own=''
  downstream=()
  seen=0
  for b in ${CHAIN[@]+"${CHAIN[@]}"}; do
    if [ "$b" = "$maint" ]; then seen=1; own="$b"; continue; fi
    if [ "$seen" -eq 1 ]; then downstream+=("$b"); fi
  done
  if [ "$seen" -eq 0 ]; then
    own='main'
    downstream=()
    say ":grey_question: \`${rel}\` (\`${tag}\`) belongs to \`${maint}\`, which no longer exists; checking main only."
  fi

  checked=$((checked + 1))

  lagging=()
  for b in ${downstream[@]+"${downstream[@]}"}; do
    if ! in_branch "$ref" "$(resolve "$b")"; then
      lagging+=("$b")
    fi
  done

  if ! in_branch "$ref" "$(resolve "$own")"; then
    failed=1
    say ":x: \`${rel}\` (\`${tag}\`) is **not** merged back into \`${own}\`."
  elif [ "${#lagging[@]}" -ne 0 ]; then
    list="$(printf '%s, ' "${lagging[@]}")"
    say ":warning: \`${rel}\` (\`${tag}\`) is in \`${own}\` but has not reached ${list%, } yet."
  else
    say ":white_check_mark: \`${rel}\` (\`${tag}\`) is in \`${own}\` and downstream."
  fi
done <<< "$release_refs"

say ''

if [ "$checked" -eq 0 ]; then
  say 'No tagged release branches to check.'
  exit 0
fi

if [ "$failed" -eq 0 ]; then
  say "All ${checked} tagged release branches are merged back into their line."
  exit 0
fi

say 'Advisory only. Merge the release branch back into its maintenance line and'
say 'let it flow forward, rather than cherry-picking, so the tag stays reachable.'
exit 1
