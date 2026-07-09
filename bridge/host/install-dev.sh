#!/bin/bash
# install-dev.sh — dev install of the Zodl Bridge native-messaging helper.
# Builds the helper, installs it + bridge-config.json, and writes the host
# manifests (allowed_origins pinned to OUR extension ID) for every Chromium
# browser present. Idempotent; --uninstall reverses everything.
#
#   ./install-dev.sh [--bundle-id co.example.zodl] [--uninstall]
set -euo pipefail

HOST_NAME="com.zodl.bridge"
# Derived from the stable dev key checked into bridge/extension/manifest.json.
EXT_ID="nginegnmdihpegemkajmjjeimigdkjma"
INSTALL_DIR="$HOME/Library/Application Support/Zodl/bridge"
BINARY="$INSTALL_DIR/zodl-bridge-host"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BROWSER_DIRS=(
    "$HOME/Library/Application Support/Google/Chrome"
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
    "$HOME/Library/Application Support/Microsoft Edge"
    "$HOME/Library/Application Support/Chromium"
)

BUNDLE_ID=""
APP_PATH=""
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        # Dev: wake by explicit app path — needed when TestFlight + Xcode builds
        # share the bundle id (LaunchServices would wake the bridge-less copy).
        --app-path) APP_PATH="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ $UNINSTALL -eq 1 ]]; then
    for dir in "${BROWSER_DIRS[@]}"; do
        rm -f "$dir/NativeMessagingHosts/$HOST_NAME.json" && echo "removed manifest: $dir" || true
    done
    rm -rf "$INSTALL_DIR"
    echo "uninstalled."
    exit 0
fi

echo "building helper (release)…"
(cd "$SCRIPT_DIR" && swift build -c release --product zodl-bridge-host >/dev/null)

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/.build/release/zodl-bridge-host" "$BINARY"
chmod 755 "$BINARY"

# Deployment facts live next to the binary (BridgeConfig): allowed callers + wake target.
python3 - "$INSTALL_DIR/bridge-config.json" "$EXT_ID" "$BUNDLE_ID" "$APP_PATH" <<'PY'
import json, sys
path, ext_id, bundle_id, app_path = sys.argv[1:5]
config = {"allowedExtensionIDs": [ext_id]}
if bundle_id:
    config["zodlBundleID"] = bundle_id
if app_path:
    config["zodlAppPath"] = app_path
json.dump(config, open(path, "w"), indent=2)
PY
echo "installed: $BINARY (+ bridge-config.json, ext id $EXT_ID${BUNDLE_ID:+, wake $BUNDLE_ID}${APP_PATH:+, wake-path $APP_PATH})"

installed=0
for dir in "${BROWSER_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    mkdir -p "$dir/NativeMessagingHosts"
    python3 - "$dir/NativeMessagingHosts/$HOST_NAME.json" "$HOST_NAME" "$BINARY" "$EXT_ID" <<'PY'
import json, sys
path, name, binary, ext_id = sys.argv[1:5]
json.dump({
    "name": name,
    "description": "Zodl Bridge helper - hands ZIP-321 payment requests to the native Zodl app",
    "path": binary,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{ext_id}/"],
}, open(path, "w"), indent=2)
PY
    echo "manifest → $dir/NativeMessagingHosts/$HOST_NAME.json"
    installed=$((installed + 1))
done

if [[ $installed -eq 0 ]]; then
    echo "NOTE: no Chromium-family browser profile dirs found — no manifests written."
fi
echo "done. Load bridge/extension unpacked (chrome://extensions → Developer mode)."
