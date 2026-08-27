#!/usr/bin/env bats
# Tests for Scripts/update-sdk-pin.sh — the build-phase capture script.

setup() {
    SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ROOT="$(mktemp -d)"
    export SDK_PIN_REPO_ROOT="$ROOT"
    export SDK_PIN_PBXPROJ="$ROOT/project.pbxproj"
    export SDK_PIN_FILE="$ROOT/.sdk-pin"
}

teardown() {
    rm -rf "$ROOT"
    rm -rf "${ROOT%/*}/zodl-swift-wallet-sdk"
}

write_local_pbxproj() {
    cat > "$SDK_PIN_PBXPROJ" <<'EOF'
/* Begin XCLocalSwiftPackageReference section */
		3464A8FA303C3A54005A09AD /* XCLocalSwiftPackageReference "../zodl-swift-wallet-sdk" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = "../zodl-swift-wallet-sdk";
		};
/* End XCLocalSwiftPackageReference section */
EOF
}

write_remote_pbxproj() {
    printf '/* no local SDK reference */\n' > "$SDK_PIN_PBXPROJ"
}

make_sdk_checkout() {
    # The pbxproj points one level above the repo root, mirror that layout.
    SDK_DIR="$ROOT/../zodl-swift-wallet-sdk"
    rm -rf "$SDK_DIR"
    git init -q "$SDK_DIR"
    git -C "$SDK_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    SDK_SHA="$(git -C "$SDK_DIR" rev-parse HEAD)"
}

@test "local mode, clean checkout: writes HEAD sha" {
    write_local_pbxproj
    make_sdk_checkout
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ "$(tr -d '[:space:]' < "$SDK_PIN_FILE")" = "$SDK_SHA" ]
}

@test "local mode, dirty checkout: appends -dirty" {
    write_local_pbxproj
    make_sdk_checkout
    touch "$SDK_DIR/uncommitted"
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ "$(tr -d '[:space:]' < "$SDK_PIN_FILE")" = "${SDK_SHA}-dirty" ]
}

@test "remote mode: empties the pin file" {
    write_remote_pbxproj
    printf 'deadbeef\n' > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SDK_PIN_FILE" ]
}

@test "no change: file is not rewritten" {
    write_local_pbxproj
    make_sdk_checkout
    "$SCRIPTS_DIR/update-sdk-pin.sh"
    touch -t 202001010000 "$SDK_PIN_FILE"
    before="$(stat -f %m "$SDK_PIN_FILE")"
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ "$(stat -f %m "$SDK_PIN_FILE")" = "$before" ]
}

@test "local mode, missing sibling: warns, exits 0, pin untouched" {
    write_local_pbxproj
    printf 'keepme\n' > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ "$(tr -d '[:space:]' < "$SDK_PIN_FILE")" = "keepme" ]
    [[ "$output" == *warning* ]]
}

@test "parsing: unquoted relativePath also works" {
    cat > "$SDK_PIN_PBXPROJ" <<'EOF'
			relativePath = "../zodl-swift-wallet-sdk";
EOF
    make_sdk_checkout
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ "$(tr -d '[:space:]' < "$SDK_PIN_FILE")" = "$SDK_SHA" ]
}

@test "parsing: other local packages are ignored" {
    cat > "$SDK_PIN_PBXPROJ" <<'EOF'
			relativePath = "../some-other-package";
EOF
    printf 'stale\n' > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/update-sdk-pin.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SDK_PIN_FILE" ]
}
