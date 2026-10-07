#!/bin/bash
# CI-side SDK companion setup: validates .sdk-pin against the committed
# project mode and (unless --validate-only) fetches the SDK repository at the
# pinned commit into the path the Xcode project expects.
#
# Modes (derived from the pbxproj, never stored in the pin):
#   remote (no local SDK reference): pin must be empty; nothing to fetch.
#   local  (XCLocalSwiftPackageReference): pin must be a full 40-hex sha;
#          the SDK is fetched to the reference's relativePath.
#
# Outputs (appended to $GITHUB_OUTPUT when set): mode, pin, sdk_path,
# sdk_abs_path. Exits 1 on any validation or fetch failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SDK_PIN_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PBXPROJ="${SDK_PIN_PBXPROJ:-$REPO_ROOT/secant.xcodeproj/project.pbxproj}"
PIN_FILE="${SDK_PIN_FILE:-$REPO_ROOT/.sdk-pin}"
SDK_REPO_URL="${SDK_REPO_URL:-https://github.com/zodl-inc/zodl-swift-wallet-sdk.git}"
# GitHub API base for the durability check; must name the same repo as SDK_REPO_URL.
SDK_API_URL="${SDK_API_URL:-https://api.github.com/repos/zodl-inc/zodl-swift-wallet-sdk}"

source "$SCRIPT_DIR/sdk-pin-common.sh"

VALIDATE_ONLY=0
case "${1:-}" in
    "") ;;
    --validate-only)
        VALIDATE_ONLY=1
        ;;
    *)
        echo "::error::setup-sdk-companion: unknown option '$1'" >&2
        exit 1
        ;;
esac

fail() {
    echo "::error::setup-sdk-companion: $*" >&2
    exit 1
}

# Like fail, but first removes $abs_path. Only for the fetch sequence below,
# once the pre-existing-directory check has confirmed $abs_path is ours (we
# just created it) — never for the refuse-to-overwrite fail above, which must
# leave a pre-existing directory untouched. Without this, a single transient
# fetch failure would leave a half-initialized checkout behind that the
# refuse-to-overwrite check then treats as a foreign directory forever,
# blocking every later retry in this workspace.
cleanup_and_fail() {
    rm -rf "$abs_path"
    fail "$@"
}

note() { echo "setup-sdk-companion: $*"; }

emit() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

# Network Git commands must never read, store, or erase runner credentials.
# Supply auth only for this repository and process, without putting it in
# argv, persistent config, FETCH_HEAD, or inherited trace output.
# File fixtures need no HTTP auth.
sdk_git() {
    local header="" auth=(-c credential.helper= -c core.askPass=)
    case "$SDK_REPO_URL" in
        http://* | https://*)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                case "$GITHUB_TOKEN" in
                    *$'\r'* | *$'\n'*) return 1 ;;
                esac
                header="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
                auth+=("--config-env=http.${SDK_REPO_URL}.extraHeader=SDK_GIT_AUTH_HEADER")
            fi
            ;;
    esac
    SDK_GIT_AUTH_HEADER="$header" GIT_TERMINAL_PROMPT=0 \
        GIT_TRACE=0 GIT_TRACE_CURL=0 GIT_CURL_VERBOSE=0 \
        GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 \
        GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
        git "${auth[@]}" "$@"
}

# Curl reads the Bearer header from stdin rather than process arguments or a
# temporary file. Disable .curlrc so inherited verbose/trace settings cannot
# print it. Reject line breaks and escape the config string's quotes/backslashes.
sdk_api_compare() {
    local token="${GITHUB_TOKEN:-}"
    case "$token" in
        *$'\r'* | *$'\n'*) return 1 ;;
    esac
    token="${token//\\/\\\\}"
    token="${token//\"/\\\"}"
    {
        if [ -n "$token" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$token"
        fi
    } | curl -q --config - -fsS "$1"
}

# Best-effort: warn when the pin is reachable only from a deletable PR
# branch. Never blocks; only runs when SDK_PIN_DURABILITY_CHECK=1 (the
# validate gate on CI), so tests and builds stay offline.
check_durability() {
    [ "${SDK_PIN_DURABILITY_CHECK:-}" = "1" ] || return 0
    local api="$SDK_API_URL"
    local refs="main"
    refs="$refs $(sdk_git ls-remote --heads "$SDK_REPO_URL" 'maint/*' 2> /dev/null | sed 's|.*refs/heads/||')"
    local ref status
    for ref in $refs; do
        status="$(sdk_api_compare "$api/compare/$ref...$pin" 2> /dev/null |
            sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)"
        case "$status" in
            behind | identical)
                return 0
                ;;
        esac
    done
    echo "::warning::.sdk-pin $pin is not on zodl-swift-wallet-sdk main or any maint/* branch — it lives only on a deletable PR branch. Repoint the pin to the merged sha once the SDK PR lands."
}

[ -f "$PBXPROJ" ] || fail "project file not found at $PBXPROJ"

rel_path="$(sdk_local_relative_path "$PBXPROJ")"
pin="$(read_pin "$PIN_FILE")"

if [ -z "$rel_path" ]; then
    if [ -n "$pin" ]; then
        fail ".sdk-pin contains '$pin' but the project references the SDK remotely. Empty .sdk-pin (a local build's Update SDK Pin phase does it) and commit."
    fi
    emit mode remote
    emit pin ""
    emit sdk_path ""
    emit sdk_abs_path ""
    note "remote SDK mode; nothing to fetch"
    exit 0
fi

case "$pin" in
    "")
        fail "the project references a local SDK at '$rel_path' but .sdk-pin is empty. Build the app once locally so the Update SDK Pin phase records the SDK commit and commit .sdk-pin — or switch the project to the remote SDK."
        ;;
    *-dirty)
        fail ".sdk-pin is '$pin': it was captured against uncommitted SDK changes. Commit and push the SDK work, rebuild the app so the pin refreshes, then commit the updated .sdk-pin."
        ;;
esac
if ! printf '%s' "$pin" | grep -Eq '^[0-9a-f]{40}$'; then
    fail ".sdk-pin must hold a full 40-character lowercase commit sha, got '$pin'."
fi

abs_path="$REPO_ROOT/$rel_path"
# upload-artifact v4 rejects patterns containing '..'; normalize lexically
# (no filesystem dependency — the path may not exist yet in validate-only).
if command -v python3 > /dev/null 2>&1; then
    abs_path="$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$abs_path")"
fi
emit mode local
emit pin "$pin"
emit sdk_path "$rel_path"
emit sdk_abs_path "$abs_path"

check_durability

if [ "$VALIDATE_ONLY" = "1" ]; then
    note "validate-only: mode=local pin=$pin sdk_path=$rel_path"
    exit 0
fi

if [ -e "$abs_path" ]; then
    if head_now="$(git -C "$abs_path" rev-parse HEAD 2> /dev/null)" && [ "$head_now" = "$pin" ]; then
        note "SDK already present at $abs_path @ $pin"
        exit 0
    fi
    fail "$abs_path exists but is not an SDK checkout at $pin; refusing to overwrite it."
fi

mkdir -p "$abs_path"
git init -q "$abs_path" || cleanup_and_fail "git init failed at $abs_path"
if ! sdk_git -C "$abs_path" fetch --depth 1 "$SDK_REPO_URL" "$pin"; then
    cleanup_and_fail "could not fetch $pin from $SDK_REPO_URL — is the pinned commit pushed and still reachable?"
fi
git -C "$abs_path" checkout -q --detach FETCH_HEAD || cleanup_and_fail "checkout of $pin failed"
note "SDK fetched to $abs_path @ $pin"
exit 0
