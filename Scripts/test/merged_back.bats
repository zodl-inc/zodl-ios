#!/usr/bin/env bats
#
# Tests for .github/scripts/check-release-merged-back.sh against fixture
# repositories. Remote-tracking refs are planted with git update-ref, so
# nothing here needs a network or a real remote.

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../.github/scripts/check-release-merged-back.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  cd "$REPO"
  git config tag.gpgsign false
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  BASE="$(git rev-parse HEAD)"
}

# One empty commit on the current branch; its sha lands in $SHA.
mkcommit() {
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"
  SHA="$(git rev-parse HEAD)"
}

@test "a maintenance line without the v prefix is the release's own line" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  mkcommit "merge back"
  git update-ref refs/remotes/origin/maint/3.10.x "$SHA"
  git update-ref refs/remotes/origin/main "$SHA"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'is in `maint/3.10.x` and downstream'* ]] || false
  [[ "$output" != *"no longer exists"* ]] || false
}

@test "a released branch missing from its own line fails" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  git update-ref refs/remotes/origin/maint/3.10.x "$BASE"
  git update-ref refs/remotes/origin/main "$BASE"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *'is **not** merged back into `maint/3.10.x`'* ]] || false
}

@test "a freshly cut release branch still pointing at the previous tag is skipped" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.11.0 "$REL"
  mkcommit "merge back"
  git update-ref refs/remotes/origin/maint/v3.10.x "$SHA"
  git update-ref refs/remotes/origin/main "$SHA"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`release/3.11.0` is freshly cut from `3.10.2`'* ]] || false
  [[ "$output" == *"All 1 tagged release branches are merged back"* ]] || false
}

@test "non-release tags neither elect a maintenance line nor mark a release" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git tag 0.0.1-42-mainnet "$REL"
  git tag beta4-rc2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  mkcommit "wip"; W="$SHA"
  git tag beta5-rc1 "$W"
  git update-ref refs/remotes/origin/release/experimental "$W"
  git update-ref refs/remotes/origin/maint/v3.10.x "$W"
  git update-ref refs/remotes/origin/main "$W"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'(`3.10.2`)'* ]] || false
  [[ "$output" != *"v0.0.x"* ]] || false
  [[ "$output" == *'`release/experimental` has no release tag at its tip'* ]] || false
}

@test "a pending merge-back PR into its line is evaluated as merged" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  git update-ref refs/remotes/origin/maint/3.10.x "$BASE"
  git update-ref refs/remotes/origin/main "$BASE"
  git checkout -q -b prmerge "$REL"
  mkcommit "pr merge"
  run "$CHECK" maint/3.10.x prmerge
  [ "$status" -eq 0 ]
  [[ "$output" == *'is in `maint/3.10.x` but has not reached main'* ]] || false
}

@test "maintenance lines are ordered by version across both spellings" {
  mkcommit "release 3.9.5"; REL="$SHA"
  git tag 3.9.5 "$REL"
  git update-ref refs/remotes/origin/release/3.9.5 "$REL"
  mkcommit "on the 3.9 line only"
  git update-ref refs/remotes/origin/maint/3.9.x "$SHA"
  git update-ref refs/remotes/origin/maint/v3.10.x "$BASE"
  git update-ref refs/remotes/origin/maint/3.11.x "$BASE"
  git update-ref refs/remotes/origin/main "$BASE"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'is in `maint/3.9.x` but has not reached maint/v3.10.x, maint/3.11.x, main yet'* ]] || false
}

@test "a git failure is an infrastructure error, not a clean run" {
  mkdir -p "$BATS_TEST_TMPDIR/notarepo"
  cd "$BATS_TEST_TMPDIR/notarepo"
  run "$CHECK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not run"* ]] || false
  [[ "$output" != *"No tagged release branches to check"* ]] || false
}

@test "an unresolvable chain ref is an infrastructure error, not a finding" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  git update-ref refs/remotes/origin/maint/3.10.x "$REL"
  # origin/main deliberately absent: the chain still ends in main, and the
  # old code reported this as a confident (false) verdict about main.
  run "$CHECK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not run"* ]] || false
  [[ "$output" != *"has not reached"* ]] || false
  [[ "$output" != *"is **not** merged back"* ]] || false
}

@test "an unresolvable pr-ref is an infrastructure error" {
  mkcommit "release 3.10.2"; REL="$SHA"
  git tag 3.10.2 "$REL"
  git update-ref refs/remotes/origin/release/3.10.2 "$REL"
  git update-ref refs/remotes/origin/maint/3.10.x "$REL"
  git update-ref refs/remotes/origin/main "$REL"
  run "$CHECK" maint/3.10.x no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve pr-ref"* ]] || false
}
