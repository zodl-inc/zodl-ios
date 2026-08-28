#!/usr/bin/env bats
#
# Tests for the pure text transforms and predicates in Scripts/lib/release-lib.sh.
# Nothing here needs a network, a git remote, or a GitHub token.

setup() {
  # shellcheck source=Scripts/lib/release-lib.sh
  . "$BATS_TEST_DIRNAME/../lib/release-lib.sh"
  FIXTURE="$BATS_TEST_TMPDIR/CHANGELOG.md"
}

# --- version ordering -------------------------------------------------------

@test "version_sort orders by version, not lexically" {
  run bash -c ". '$BATS_TEST_DIRNAME/../lib/release-lib.sh'; printf '3.9.5\n3.10.2\n3.10.0\n' | version_sort"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3.9.5" ]
  [ "${lines[1]}" = "3.10.0" ]
  [ "${lines[2]}" = "3.10.2" ]
}

@test "version_sort ranks a pre-release below its release" {
  run bash -c ". '$BATS_TEST_DIRNAME/../lib/release-lib.sh'; printf '3.11.0\n3.11.0-rc.1\n' | version_sort"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3.11.0-rc.1" ]
  [ "${lines[1]}" = "3.11.0" ]
}

@test "version_le compares across a two-digit minor" {
  run version_le 3.9.5 3.10.0
  [ "$status" -eq 0 ]
  run version_le 3.10.0 3.9.5
  [ "$status" -ne 0 ]
}

@test "version_le is true for equal versions" {
  run version_le 3.10.2 3.10.2
  [ "$status" -eq 0 ]
}

# --- release tag shape ------------------------------------------------------

@test "RELEASE_TAG_RE accepts X.Y.Z and rejects the repo's non-release tags" {
  for good in 3.10.2 2.4.4 3.9.5; do
    echo "$good" | grep -qE "$RELEASE_TAG_RE"
  done
  for bad in beta4-rc2 release-baseline-2026-08-08 test-0.0.1-42 3.10 v3.10.2 3.10.2-rc.1; do
    run bash -c "echo '$bad' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\$'"
    [ "$status" -ne 0 ]
  done
}

# --- remote URL parsing -----------------------------------------------------

@test "repo_slug_from_url handles every GitHub remote form" {
  [ "$(repo_slug_from_url 'git@github.com:zodl-inc/zodl-ios.git')" = "zodl-inc/zodl-ios" ]
  [ "$(repo_slug_from_url 'https://github.com/zodl-inc/zodl-ios.git')" = "zodl-inc/zodl-ios" ]
  [ "$(repo_slug_from_url 'https://github.com/zodl-inc/zodl-ios')" = "zodl-inc/zodl-ios" ]
  [ "$(repo_slug_from_url 'ssh://git@github.com/zodl-inc/zodl-ios.git')" = "zodl-inc/zodl-ios" ]
}

# --- CHANGELOG --------------------------------------------------------------

write_changelog() {
  cat > "$FIXTURE"
}

@test "changelog_unreleased_nonempty is true when the section has entries" {
  write_changelog <<'EOF'
# Changelog

## [Unreleased]

### Added
- [MOB-1] Something users can see.

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  run changelog_unreleased_nonempty "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "changelog_unreleased_nonempty is false for an empty section" {
  write_changelog <<'EOF'
# Changelog

## [Unreleased]

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  run changelog_unreleased_nonempty "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "changelog_unreleased_nonempty is false for bare subsection headings" {
  write_changelog <<'EOF'
# Changelog

## [Unreleased]

### Added

### Fixed

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  run changelog_unreleased_nonempty "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "changelog_unreleased_nonempty does not see the previous release's entries" {
  write_changelog <<'EOF'
# Changelog

## [Unreleased]

## [3.10.2] - 2026-08-27
- [MOB-1] Shipped already.
EOF
  run changelog_unreleased_nonempty "$FIXTURE"
  [ "$status" -ne 0 ]
}

@test "promote_changelog inserts a dated heading and keeps Unreleased" {
  write_changelog <<'EOF'
# Changelog

## [Unreleased]

### Added
- [MOB-1] Something users can see.

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  run promote_changelog "$FIXTURE" 3.11.0 2026-08-27
  [ "$status" -eq 0 ]
  run cat "$FIXTURE"
  [[ "$output" == *"## [Unreleased]"* ]]
  [[ "$output" == *"## [3.11.0] - 2026-08-27"* ]]
  # The entries stay where they are; only a heading is inserted above them.
  [ "$(grep -n '## \[3.11.0\]' "$FIXTURE" | cut -d: -f1)" -lt \
    "$(grep -n 'MOB-1' "$FIXTURE" | cut -d: -f1)" ]
  [ "$(grep -n '## \[Unreleased\]' "$FIXTURE" | cut -d: -f1)" -lt \
    "$(grep -n '## \[3.11.0\]' "$FIXTURE" | cut -d: -f1)" ]
}

@test "promote_changelog generates no text of its own" {
  write_changelog <<'EOF'
## [Unreleased]

### Added
- [MOB-1] Exactly this line.
EOF
  promote_changelog "$FIXTURE" 3.11.0 2026-08-27
  [ "$(grep -c 'MOB-1' "$FIXTURE")" -eq 1 ]
  [ "$(grep -c '^- ' "$FIXTURE")" -eq 1 ]
}

@test "promote_changelog fails and leaves the file alone without an Unreleased heading" {
  write_changelog <<'EOF'
# Changelog

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  before="$(cat "$FIXTURE")"
  run promote_changelog "$FIXTURE" 3.11.0 2026-08-27
  [ "$status" -ne 0 ]
  [ "$(cat "$FIXTURE")" = "$before" ]
}

@test "promote_changelog only promotes once" {
  write_changelog <<'EOF'
## [Unreleased]

- [MOB-1] entry

## [Unreleased]
EOF
  promote_changelog "$FIXTURE" 3.11.0 2026-08-27
  [ "$(grep -c '## \[3.11.0\]' "$FIXTURE")" -eq 1 ]
}

@test "changelog_has_version recognises both heading formats" {
  write_changelog <<'EOF'
## [Unreleased]

## [3.10.2] - 2026-08-27
- newer

## 3.7.3 build 1 (2026-07-12)
- older
EOF
  run changelog_has_version "$FIXTURE" 3.10.2
  [ "$status" -eq 0 ]
  run changelog_has_version "$FIXTURE" 3.7.3
  [ "$status" -eq 0 ]
  run changelog_has_version "$FIXTURE" 3.11.0
  [ "$status" -ne 0 ]
}

@test "changelog_has_version does not match a version that is a prefix of another" {
  write_changelog <<'EOF'
## [Unreleased]

## [3.10.20] - 2026-08-27
- newer
EOF
  run changelog_has_version "$FIXTURE" 3.10.2
  [ "$status" -ne 0 ]
}

# --- project versions -------------------------------------------------------

@test "project_marketing_version reads the value from a pbxproj" {
  cat > "$BATS_TEST_TMPDIR/project.pbxproj" <<'EOF'
		buildSettings = {
			CURRENT_PROJECT_VERSION = 1;
			MARKETING_VERSION = 3.10.2;
		};
EOF
  [ "$(project_marketing_version "$BATS_TEST_TMPDIR/project.pbxproj")" = "3.10.2" ]
}

# --- dry-run plumbing -------------------------------------------------------

@test "run_cmd executes normally and only describes under DRY_RUN" {
  DRY_RUN=false
  run run_cmd echo hello
  [ "$output" = "hello" ]

  DRY_RUN=true
  run run_cmd echo hello
  [[ "$output" == *"would run: echo hello"* ]]
  [[ "$output" != "hello" ]]
}

# The library must not define a function named `run`: bats provides its own,
# and shadowing it makes every `run <helper>` assertion in this file silently
# stop capturing a status.
@test "the library does not shadow bats' run helper" {
  [ "$(type -t run)" = "function" ]
  run true
  [ "$status" -eq 0 ]
  run false
  [ "$status" -eq 1 ]
}

@test "die_unless_dry_run warns under DRY_RUN and exits otherwise" {
  DRY_RUN=true
  run die_unless_dry_run "not fatal here"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: not fatal here"* ]]

  run bash -c ". '$BATS_TEST_DIRNAME/../lib/release-lib.sh'; DRY_RUN=false; die_unless_dry_run 'fatal here'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: fatal here"* ]]
}
