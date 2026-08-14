#!/usr/bin/env bats

setup() {
  export FASTLANE_CMD=echo
  RELEASE="$BATS_TEST_DIRNAME/../release.sh"
}

@test "translates GNU flags to fastlane key:value" {
  run "$RELEASE" --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"release variant:ios-appstore ref:release/3.8.0 version:3.8.0 build:3"* ]]
}

@test "forwards --dry-run as dry_run:true" {
  run "$RELEASE" --variant ios-testnet --ref main --version 3.8.0 --build 1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry_run:true"* ]]
}

@test "forwards --yes as yes:true" {
  run "$RELEASE" --variant internal --ref main --version 3.8.0 --build 1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes:true"* ]]
}

@test "forwards -y as yes:true" {
  run "$RELEASE" --variant internal --ref main --version 3.8.0 --build 1 -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes:true"* ]]
}

@test "missing --build exits 2" {
  run "$RELEASE" --variant ios-appstore --ref main --version 3.8.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--build is required"* ]]
}

@test "unknown flag exits 2" {
  run "$RELEASE" --variant ios-appstore --bogus x
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints usage" {
  run "$RELEASE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: Scripts/release.sh"* ]]
}

@test "forwards --submit-review as submit_review:true" {
  run "$RELEASE" --variant appstore --ref release/3.8.0 --version 3.8.0 --build 3 --submit-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"submit_review:true"* ]]
}

@test "--submit-review works without --ref" {
  run "$RELEASE" --variant appstore --version 3.8.0 --build 3 --submit-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref: version:3.8.0"* ]]
  [[ "$output" == *"submit_review:true"* ]]
}

@test "missing --ref without --submit-review exits 2" {
  run "$RELEASE" --variant appstore --version 3.8.0 --build 3
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ref is required"* ]]
}

@test "--submit-review with non-appstore variant exits 2" {
  run "$RELEASE" --variant internal --ref main --version 3.8.0 --build 3 --submit-review
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --variant appstore"* ]]
}

@test "--submit-review with internal-testnet exits 2" {
  run "$RELEASE" --variant internal-testnet --version 3.8.0 --build 3 --submit-review
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --variant appstore"* ]]
}
