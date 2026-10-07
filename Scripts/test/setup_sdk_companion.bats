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
    if [ -n "${HTTP_PID:-}" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
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

@test "local mode + malformed pin with tag-like annotation: fails" {
    write_local_pbxproj
    printf 'garbage some-tag\n' > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"40-character"* ]]
}

@test "local mode + tagged pin, validate-only: ok with sha-only pin output" {
    write_local_pbxproj
    make_origin
    printf '%s some-tag\n' "$PIN_SHA" > "$SDK_PIN_FILE"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    grep -q '^mode=local$' "$GITHUB_OUTPUT"
    grep -q "^pin=$PIN_SHA$" "$GITHUB_OUTPUT"
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
    abs_path_value="$(sed -n 's/^sdk_abs_path=//p' "$GITHUB_OUTPUT")"
    [[ "$abs_path_value" != *"/../"* ]]
    [ "$abs_path_value" = "$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$ROOT/../zodl-swift-wallet-sdk")" ]
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

# These cases run real Git over loopback HTTP. Removing credential isolation
# makes the recording helper receive get/store/erase, and removing per-process
# authentication prevents the private fetch and maint/* durability check.
make_authenticated_origin() {
    make_origin
    git -C "$ORIGIN" update-ref refs/heads/maint/fixture "$PIN_SHA"
    export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    export CREDENTIAL_EVENTS="$ROOT/credential-events"
    export PROMPT_EVENTS="$ROOT/prompt-events"
    export GIT_ARGV_EVENTS="$ROOT/git-argv"
    export CURL_ARGV_EVENTS="$ROOT/curl-argv"
    : > "$CREDENTIAL_EVENTS"
    : > "$PROMPT_EVENTS"
    : > "$GIT_ARGV_EVENTS"
    : > "$CURL_ARGV_EVENTS"
    cat > "$ROOT/credential-helper" <<'HELPER'
#!/bin/bash
printf '%s\n' "$1" >> "$CREDENTIAL_EVENTS"
cat > /dev/null
if [ "$1" = get ] && [ "${CREDENTIAL_PASSWORD:-}" != empty ]; then
    printf 'username=x-access-token\npassword=%s\n' "${CREDENTIAL_PASSWORD:-fixture-token}"
fi
HELPER
    cat > "$ROOT/askpass" <<'ASKPASS'
#!/bin/bash
printf 'prompt\n' >> "$PROMPT_EVENTS"
printf 'fixture-token\n'
ASKPASS
    chmod +x "$ROOT/credential-helper" "$ROOT/askpass"
    git config --file "$GIT_CONFIG_GLOBAL" credential.helper "$ROOT/credential-helper"
    export GIT_ASKPASS="$ROOT/askpass"
    export SSH_ASKPASS="$ROOT/askpass"
    export GITHUB_TOKEN=fixture-token
    export HTTP_EVENTS="$ROOT/http-events"
    python3 "$BATS_TEST_DIRNAME/fixtures/sdk_git_http.py" "$ORIGIN" "$ROOT/http-port" "$HTTP_EVENTS" "${1:-allow}" &
    HTTP_PID=$!
    for _ in {1..100}; do
        [ ! -e "$ROOT/http-port" ] || break
        sleep 0.05
    done
    [ -s "$ROOT/http-port" ]
    SDK_REPO_URL="http://127.0.0.1:$(cat "$ROOT/http-port")/fixture/sdk.git"
    SDK_API_URL="http://127.0.0.1:$(cat "$ROOT/http-port")/repos/fixture/sdk"
    export SDK_REPO_URL SDK_API_URL
    # Record argv at the process boundary, while still running real Git.
    FIXTURE_GIT="$(command -v git)"
    FIXTURE_CURL="$(command -v curl)"
    export FIXTURE_GIT FIXTURE_CURL
    mkdir "$ROOT/bin"
    cat > "$ROOT/bin/git" <<'GIT'
#!/bin/bash
printf '%s\n' "$@" >> "$GIT_ARGV_EVENTS"
exec "$FIXTURE_GIT" "$@"
GIT
    cat > "$ROOT/bin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_ARGV_EVENTS"
exec "$FIXTURE_CURL" "$@"
CURL
    chmod +x "$ROOT/bin/git" "$ROOT/bin/curl"
    export PATH="$ROOT/bin:$PATH"
    printf '%s\n' "$PIN_SHA" > "$SDK_PIN_FILE"
}

assert_credentials_untouched() {
    if [ -s "$CREDENTIAL_EVENTS" ]; then
        printf 'Unexpected credential helper operations: %s\n' "$(tr '\n' ' ' < "$CREDENTIAL_EVENTS")"
        return 1
    fi
    if [ -s "$PROMPT_EVENTS" ]; then
        printf 'Unexpected credential prompt\n'
        return 1
    fi
}

assert_no_secret_artifacts() {
    local secret_pattern='fixture-token|eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg=='
    if printf '%s' "$output" | grep -E -q "$secret_pattern"; then
        echo "Unexpected secret in command output"
        return 1
    fi
    if grep -E -q "$secret_pattern" "$GIT_ARGV_EVENTS" "$CURL_ARGV_EVENTS" "$GITHUB_OUTPUT"; then
        echo "Unexpected secret in process arguments or Actions outputs"
        return 1
    fi
    if [ -d "$ROOT/../zodl-swift-wallet-sdk/.git" ] &&
        grep -R -E -q "$secret_pattern" "$ROOT/../zodl-swift-wallet-sdk/.git"; then
        echo "Unexpected secret in checkout artifacts"
        return 1
    fi
    if grep -E -q "$secret_pattern" "$GIT_CONFIG_GLOBAL"; then
        echo "Unexpected secret in inherited Git config"
        return 1
    fi
}

@test "authenticated fetch leaves inherited credentials untouched and secrets transient" {
    write_local_pbxproj
    make_authenticated_origin
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$ROOT/../zodl-swift-wallet-sdk" rev-parse HEAD)" = "$PIN_SHA" ]
    assert_credentials_untouched
    assert_no_secret_artifacts
    # Hand-derived Basic auth for x-access-token:fixture-token.
    grep -q 'Basic eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg==' "$HTTP_EVENTS"
}

@test "durability checks private maint branches without touching inherited credentials" {
    write_local_pbxproj
    make_authenticated_origin
    export SDK_PIN_DURABILITY_CHECK=1
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    assert_credentials_untouched
    assert_no_secret_artifacts
    [[ "$output" != *"::warning::"* ]]
    grep -q '/compare/maint/fixture' "$HTTP_EVENTS"
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
}

@test "rejected fetch auth cannot read or erase inherited credentials and cleans up" {
    write_local_pbxproj
    make_authenticated_origin deny
    export CREDENTIAL_PASSWORD=wrong-fixture-password
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch"* ]]
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "rejected durability auth cannot read or erase inherited credentials" {
    write_local_pbxproj
    make_authenticated_origin deny
    export CREDENTIAL_PASSWORD=wrong-fixture-password
    export SDK_PIN_DURABILITY_CHECK=1
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "anonymous denied fetch never invokes inherited askpass and cleans up" {
    write_local_pbxproj
    make_authenticated_origin deny
    unset GITHUB_TOKEN
    export CREDENTIAL_PASSWORD=empty
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
    # Check prompts first so the RED output identifies the askpass regression.
    [ ! -s "$PROMPT_EVENTS" ] || { echo "Unexpected credential prompt"; return 1; }
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "composite action passes a credential-free SDK URL to the setup script" {
    mkdir -p "$ROOT/Scripts"
    cat > "$ROOT/Scripts/setup-sdk-companion.sh" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$SDK_REPO_URL" > "$GITHUB_OUTPUT"
SCRIPT
    chmod +x "$ROOT/Scripts/setup-sdk-companion.sh"
    # Execute the composite run block, substituting the Actions expression
    # exactly as a full-mode runner would, with only a synthetic token.
    python3 - "$SCRIPTS_DIR/../.github/actions/setup-sdk-companion/action.yml" "$ROOT/action-run" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().split("      run: |\n", 1)[1]
body = "\n".join(line[8:] for line in source.splitlines())
Path(sys.argv[2]).write_text(body.replace("${{ inputs.validate-only }}", "false"))
PYTHON
    export SDK_REPO=fixture/sdk
    export GITHUB_TOKEN=fixture-token
    cd "$ROOT"
    run bash "$ROOT/action-run"
    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = 'https://github.com/fixture/sdk.git' ]
}

@test "durability API Bearer authentication stays out of process arguments" {
    write_local_pbxproj
    make_authenticated_origin
    export SDK_PIN_DURABILITY_CHECK=1
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" != *"::warning::"* ]]
    assert_no_secret_artifacts
    grep -q 'Bearer fixture-token' "$HTTP_EVENTS"
}

@test "durability API denial warns without exposing credentials" {
    write_local_pbxproj
    make_authenticated_origin api-deny
    export SDK_PIN_DURABILITY_CHECK=1
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    assert_no_secret_artifacts
}

@test "malformed token fails fetch without exposing its raw or encoded value" {
    write_local_pbxproj
    make_authenticated_origin
    export GITHUB_TOKEN=$'fixture-token\nextra-header'
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch"* ]]
    [ ! -e "$ROOT/../zodl-swift-wallet-sdk" ]
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "inherited Git tracing cannot persist tokens during a fresh checkout" {
    write_local_pbxproj
    make_authenticated_origin
    export GIT_TRACE2_EVENT="$ROOT/git-trace"
    export GIT_TRACE2_ENV_VARS=GITHUB_TOKEN,SDK_GIT_AUTH_HEADER
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    if [ -e "$ROOT/git-trace" ] &&
        grep -E -q 'fixture-token|eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg==' "$ROOT/git-trace"; then
        echo "Unexpected raw or encoded credential in inherited Git trace"
        return 1
    fi
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "inherited curl config cannot trace the durability API Bearer token" {
    write_local_pbxproj
    make_authenticated_origin
    export SDK_PIN_DURABILITY_CHECK=1
    export CURL_HOME="$ROOT/curl-home"
    mkdir "$CURL_HOME"
    printf 'trace-ascii = "%s"\n' "$ROOT/curl-trace" > "$CURL_HOME/.curlrc"
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" != *"::warning::"* ]]
    if [ -e "$ROOT/curl-trace" ] && grep -q 'fixture-token' "$ROOT/curl-trace"; then
        echo "Unexpected credential in inherited curl trace"
        return 1
    fi
    assert_credentials_untouched
    assert_no_secret_artifacts
}

@test "malformed token cannot reach the durability API or leak in a warning" {
    write_local_pbxproj
    make_authenticated_origin
    export GITHUB_TOKEN=$'fixture-token\rheader'
    export SDK_PIN_DURABILITY_CHECK=1
    run "$SCRIPTS_DIR/setup-sdk-companion.sh" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    assert_credentials_untouched
    assert_no_secret_artifacts
    [ ! -e "$HTTP_EVENTS" ]
}


@test "inherited Git tracing cannot persist tokens while reusing a checkout" {
    write_local_pbxproj
    make_authenticated_origin
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    export GIT_TRACE2_EVENT="$ROOT/git-trace"
    export GIT_TRACE2_ENV_VARS=GITHUB_TOKEN,SDK_GIT_AUTH_HEADER
    run "$SCRIPTS_DIR/setup-sdk-companion.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present"* ]]
    if [ -e "$ROOT/git-trace" ] &&
        grep -E -q 'fixture-token|eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg==' "$ROOT/git-trace"; then
        echo "Unexpected raw or encoded credential in inherited Git trace"
        return 1
    fi
    assert_credentials_untouched
    assert_no_secret_artifacts
}
