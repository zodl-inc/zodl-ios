#!/usr/bin/env bats
# Tests for Scripts/setup-sdk-companion.sh — CI-side pin validation + fetch.

setup() {
    SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ROOT="$(mktemp -d)"
    export SDK_PIN_REPO_ROOT="$ROOT"
    export SDK_PIN_PBXPROJ="$ROOT/project.pbxproj"
    export SDK_PIN_FILE="$ROOT/.sdk-pin"
    export GITHUB_OUTPUT="$ROOT/gh_output"
    unset SDK_PIN_DURABILITY_CHECK || true
}

teardown() {
    rm -rf "$ROOT" "$ROOT-origin"
    # The fetch target is a sibling of $ROOT; since mktemp dirs share a
    # parent, that path is the same across every test (and every bats run)
    # in this suite. Clean it unconditionally so a fetch-failure test that
    # leaves a half-initialized checkout behind (or a prior run's leftovers)
    # can't pollute the next test — mirrors update_sdk_pin.bats's teardown.
    rm -rf "${ROOT%/*}/zodl-swift-wallet-sdk"
}

write_local_pbxproj() {
    printf '\t\t\trelativePath = "../zodl-swift-wallet-sdk";\n' > "$SDK_PIN_PBXPROJ"
    # relativePath resolves against the repo root, so the fetch target is a
    # sibling of $ROOT — keep fixtures inside mktemp space.
}

write_remote_pbxproj() { printf '/* remote */\n' > "$SDK_PIN_PBXPROJ"; }

make_origin() {
    # A bare origin the script can fetch an arbitrary sha from over file://.
    src="$(mktemp -d)"
    git init -q "$src"
    git -C "$src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
    git -C "$src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
    PIN_SHA="$(git -C "$src" rev-parse HEAD)"
    ORIGIN="$ROOT-origin"
    git clone -q --bare "$src" "$ORIGIN"
    # GitHub allows fetching any reachable sha; local file:// needs opt-in.
    git -C "$ORIGIN" config uploadpack.allowAnySHA1InWant true
    export SDK_REPO_URL="file://$ORIGIN"
    rm -rf "$src"
}

@test "remote mode + empty pin: ok, mode=remote" {
    write_remote_pbxproj
    : > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    grep -q '^mode=remote$' "$GITHUB_OUTPUT"
}

@test "remote mode + nonempty pin: fails" {
    write_remote_pbxproj
    printf '%040d\n' 0 > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
}

@test "local mode + empty pin: fails with instructions" {
    write_local_pbxproj
    : > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"Update SDK Pin"* ]]
}

@test "local mode + dirty pin: fails" {
    write_local_pbxproj
    printf '%040d-dirty\n' 0 > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 1 ]
    [[ "$output" == *uncommitted* ]]
}

@test "local mode + malformed pin: fails" {
    write_local_pbxproj
    printf 'main\n' > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"40-character"* ]]
}

@test "local mode + valid pin, validate-only: ok with outputs, no fetch" {
    write_local_pbxproj
    make_origin
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    grep -q '^mode=local$' "$GITHUB_OUTPUT"
    grep -q "^pin=$PIN_SHA$" "$GITHUB_OUTPUT"
    grep -q '^sdk_path=../zodl-swift-wallet-sdk$' "$GITHUB_OUTPUT"
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
}

@test "full mode: fetches the pinned sha to the pbxproj path" {
    write_local_pbxproj
    make_origin
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$ROOT/../zodl-swift-wallet-sdk" rev-parse HEAD)" = "$PIN_SHA" ]
    rm -rf "$ROOT/../zodl-swift-wallet-sdk"
}

@test "full mode: unreachable sha fails" {
    write_local_pbxproj
    make_origin
    printf '%040d\n' 1 > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch"* ]]
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
}

@test "full mode: failed fetch self-heals" {
    write_local_pbxproj
    make_origin
    printf '%040d\n' 1 > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$ROOT/../zodl-swift-wallet-sdk" rev-parse HEAD)" = "$PIN_SHA" ]
    rm -rf "$ROOT/../zodl-swift-wallet-sdk"
}

@test "full mode: existing checkout at the pin is reused" {
    write_local_pbxproj
    make_origin
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    "$SCRIPTS_DIR/setup-sdk-companion.sh"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present"* ]]
    rm -rf "$ROOT/../zodl-swift-wallet-sdk"
}

@test "full mode: existing non-matching directory is refused" {
    write_local_pbxproj
    make_origin
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    mkdir -p "$ROOT/../zodl-swift-wallet-sdk"
    touch "$ROOT/../zodl-swift-wallet-sdk/random"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *refusing* ]]
    rm -rf "$ROOT/../zodl-swift-wallet-sdk"
}
