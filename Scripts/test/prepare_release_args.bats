#!/usr/bin/env bats
#
# Tests for prepare-release.sh's argument handling. Every case here either is
# rejected at parsing or dies in read-only preflight (against a remote that
# cannot exist, under --dry-run), so the suite touches neither the network nor
# any repository state.

setup() {
  PREPARE="$BATS_TEST_DIRNAME/../prepare-release.sh"
}

# --- dispatch ---------------------------------------------------------------

@test "--help exits 0 and lists the subcommands" {
  run "$PREPARE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ./Scripts/prepare-release.sh <subcommand>"* ]]
  [[ "$output" == *"start"* ]]
}

@test "no subcommand exits non-zero with usage" {
  run "$PREPARE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: ./Scripts/prepare-release.sh <subcommand>"* ]]
}

@test "an unknown subcommand is named in the error" {
  run "$PREPARE" finish upstream 3.11.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand 'finish'"* ]]
}

# --- start ------------------------------------------------------------------

@test "start --help exits 0 and documents the arguments" {
  run "$PREPARE" start --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ./Scripts/prepare-release.sh start"* ]]
  [[ "$output" == *"<remote>"* ]]
  [[ "$output" == *"--previous"* ]]
}

@test "start with no arguments asks for a remote and a version" {
  run "$PREPARE" start
  [ "$status" -ne 0 ]
  [[ "$output" == *"start needs a remote and a version"* ]]
}

@test "start with only a remote asks for a version" {
  run "$PREPARE" start upstream
  [ "$status" -ne 0 ]
  [[ "$output" == *"start needs a remote and a version"* ]]
}

@test "an unknown option is named in the error" {
  run "$PREPARE" start --bogus x upstream 3.11.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option '--bogus'"* ]]
}

@test "a version that is not X.Y.Z is rejected" {
  for bad in 3.11 3.11.0-rc.1 three 3.11.0.1; do
    run "$PREPARE" start upstream "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not in X.Y.Z form"* ]]
  done
}

# A leading v is stripped before validation, so `v3.11.0` means 3.11.0 and is
# accepted -- it reaches the preconditions rather than the version check. The
# remote deliberately cannot exist and --dry-run is set, so the run dies in
# preflight (dirty tree or unknown remote, depending on the checkout) without
# touching anything; the non-zero status is asserted, not assumed.
@test "a leading v is stripped rather than rejected" {
  run "$PREPARE" start --dry-run bats-no-such-remote v3.11.0
  [ "$status" -ne 0 ]
  [[ "$output" != *"is not in X.Y.Z form"* ]]
  [[ "$output" == *"Checking preconditions"* ]]
}

# Confirm the rejection message names the value actually checked, not the
# argument as typed.
@test "a rejected version is reported without its stripped v" {
  run "$PREPARE" start upstream v3.11
  [ "$status" -ne 0 ]
  [[ "$output" == *"version '3.11' is not in X.Y.Z form"* ]]
}

@test "a non-integer build number is rejected" {
  run "$PREPARE" start --build one upstream 3.11.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"build 'one' is not an integer"* ]]
}

@test "an option missing its value is rejected rather than swallowing the next argument" {
  run "$PREPARE" start --issue
  [ "$status" -ne 0 ]
  [[ "$output" == *"--issue needs an issue number"* ]]

  run "$PREPARE" start --previous
  [ "$status" -ne 0 ]
  [[ "$output" == *"--previous needs a tag"* ]]

  run "$PREPARE" start --build
  [ "$status" -ne 0 ]
  [[ "$output" == *"--build needs a build number"* ]]
}
