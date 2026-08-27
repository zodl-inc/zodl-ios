#!/bin/bash
# Records which SDK commit the app builds against into .sdk-pin.
#
# Runs as the "Update SDK Pin" build phase on every app target. Reads the
# committed pbxproj to decide the mode:
#   local SDK reference  -> pin = sibling checkout's HEAD ("-dirty" appended
#                           while its working tree has uncommitted changes)
#   remote SDK reference -> pin file is emptied
# Writes only when the content actually changes, and never fails the build:
# capture is best-effort, CI validation (setup-sdk-companion.sh) enforces.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SDK_PIN_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PBXPROJ="${SDK_PIN_PBXPROJ:-$REPO_ROOT/secant.xcodeproj/project.pbxproj}"
PIN_FILE="${SDK_PIN_FILE:-$REPO_ROOT/.sdk-pin}"

source "$SCRIPT_DIR/sdk-pin-common.sh"

warn() { echo "warning: update-sdk-pin: $*" >&2; }

if [ ! -f "$PBXPROJ" ]; then
    warn "project file not found at $PBXPROJ; leaving pin untouched"
    exit 0
fi

rel_path="$(sdk_local_relative_path "$PBXPROJ")"

new_content=""
if [ -n "$rel_path" ]; then
    sdk_dir="$REPO_ROOT/$rel_path"
    if ! command -v git > /dev/null 2>&1; then
        warn "git not available; leaving pin untouched"
        exit 0
    fi
    if ! sha="$(git -C "$sdk_dir" rev-parse HEAD 2> /dev/null)"; then
        warn "no SDK git checkout at $sdk_dir; leaving pin untouched"
        exit 0
    fi
    if [ -n "$(git -C "$sdk_dir" status --porcelain 2> /dev/null)" ]; then
        sha="${sha}-dirty"
    fi
    new_content="$sha"
fi

current="$(read_pin "$PIN_FILE")"
if [ "$current" = "$new_content" ]; then
    exit 0
fi

if [ -n "$new_content" ]; then
    printf '%s\n' "$new_content" > "$PIN_FILE"
else
    : > "$PIN_FILE"
fi
echo "update-sdk-pin: recorded '${new_content:-<empty>}' in $(basename "$PIN_FILE")"
exit 0
