#!/usr/bin/env bats
#
# Tests for prepare-release.sh's start flow beyond argument parsing, run
# against a COPY of the script inside a throwaway repository whose `upstream`
# remote is the repository itself. Everything runs under --dry-run, so the
# suite needs no network, no GitHub auth, and mutates nothing -- and because
# the copy anchors to the sandbox checkout, the real repository is never
# touched even if an assertion is wrong.

setup() {
  SB="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SB/Scripts/lib"
  cp "$BATS_TEST_DIRNAME/../prepare-release.sh" "$SB/Scripts/prepare-release.sh"
  cp "$BATS_TEST_DIRNAME/../lib/release-lib.sh" "$SB/Scripts/lib/release-lib.sh"
  START="$SB/Scripts/prepare-release.sh"
  git init -q -b main "$SB"
  cd "$SB"
  git config tag.gpgsign false
  git remote add upstream .
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n- [MOB-1] entry\n' > CHANGELOG.md
  git add .
  git -c user.name=t -c user.email=t@t commit -q -m base
  git tag 0.1.0
}

sandbox_commit() {
  git add .
  git -c user.name=t -c user.email=t@t commit -q -m "$1"
}

@test "an unreachable newer release tag stops an auto-detected cut" {
  git checkout -q -b side
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m divergent
  git tag 0.1.1
  git checkout -q main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
  run "$START" start --dry-run upstream 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"newest release tag is 0.1.1"* ]] || false
  [[ "$output" == *"not reachable"* ]] || false
}

@test "--previous must be an ancestor of the revision" {
  git checkout -q -b side
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m divergent
  git tag 0.1.1
  git checkout -q main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
  run "$START" start --dry-run --previous 0.1.1 upstream 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"--previous 0.1.1 is not an ancestor of HEAD"* ]] || false
}

@test "a clean dry run rehearses the whole cut and changes nothing" {
  run "$START" start --dry-run upstream 0.2.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest release reachable from HEAD: 0.1.0"* ]] || false
  [[ "$output" == *"Dry run: nothing was changed"* ]] || false
  # The rehearsal must describe the atomic shape of a real run: one push
  # carrying both branches, after all local work, then a draft PR.
  [[ "$output" == *"would run: git push --atomic -u upstream release/0.2.0 candidate/0.2.0"* ]] || false
  [[ "$output" == *"would open a draft PR candidate/0.2.0 -> release/0.2.0"* ]] || false
  # Nothing mutated: no branches, tree clean, HEAD still on main.
  [ -z "$(git status --porcelain)" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
  run git rev-parse -q --verify refs/heads/release/0.2.0
  [ "$status" -ne 0 ]
}

@test "the empty-Unreleased guard reads the revision, not the working tree" {
  # First commit: CHANGELOG whose Unreleased section is empty.
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n' > CHANGELOG.md
  sandbox_commit "empty unreleased"
  EMPTY_SHA="$(git rev-parse HEAD)"
  # HEAD moves on; the checkout has entries again.
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n- [MOB-2] newer entry\n' > CHANGELOG.md
  sandbox_commit "entries again"
  run "$START" start --dry-run upstream 0.2.0 "$EMPTY_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unreleased section of CHANGELOG.md at ${EMPTY_SHA} has no entries"* ]] || false
}

@test "the existing-heading guard reads the revision, not the working tree" {
  # First commit: CHANGELOG that already carries the version being cut.
  printf '# Changelog\n\n## [Unreleased]\n\n- [MOB-1] entry\n\n## [0.2.0] - 2026-01-01\n- old\n' > CHANGELOG.md
  sandbox_commit "already has 0.2.0"
  HAS_SHA="$(git rev-parse HEAD)"
  # HEAD moves on; the checkout no longer mentions 0.2.0.
  printf '# Changelog\n\n## [Unreleased]\n\n- [MOB-1] entry\n' > CHANGELOG.md
  sandbox_commit "heading gone"
  run "$START" start --dry-run upstream 0.2.0 "$HAS_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already carries a heading for 0.2.0"* ]] || false
}
