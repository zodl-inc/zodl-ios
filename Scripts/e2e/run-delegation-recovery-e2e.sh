#!/usr/bin/env bash
# End-to-end test of the delegation recovery path on a simulator.
#
# Runs the on-device suite that OPENS THE APP against a corrupted voting
# database and asserts the broadcast secrets came back.
#
# The suite builds and plants that database itself, using the same builder the
# in-process tests use, so this script only has to stand up a simulator and
# report honestly on what the run did.
#
# Recovery has no user-facing trigger: it runs off the launch action the app
# delegate sends, invisibly. So the suite drives `Root` through
# `.didFinishLaunching` with the real recovery client and the real file-backed
# escrow beneath it, and the escrow file on disk is the observable, since a
# fire-and-forget launch returns nothing to assert on.
#
# That distinction is what this script exists to protect. The carver, the
# probe and the escrow are all covered in-process; only an on-device run can
# show that opening the app is what sets them going. A change that unhooked
# recovery from launch would leave every other test green.
#
# The interesting part is the planting. A running app holds an open SQLite
# connection, and when that connection closes SQLite checkpoints and unlinks
# the write-ahead log, which is the only place a cleared round's originals
# survive. So the app is terminated before the copy and the whole three-file
# set is planted together: the main database alone would silently roll back to
# its last checkpoint.
#
# Usage:
#   Scripts/e2e/run-delegation-recovery-e2e.sh [-d "iPhone 17"] [-k]
#
#   -d  simulator device name (default: iPhone 17)
#   -k  keep the simulator booted and the planted files in place afterwards
set -euo pipefail

DEVICE="${DEVICE:-iPhone 17}"
SCHEME="${SCHEME:-zodl-internal}"
PROJECT="secant.xcodeproj"
KEEP=0
# Tests in DelegationRecoveryDeviceE2ETests; bump with the suite.
EXPECTED_TESTS=5

while getopts "d:k" opt; do
    case "$opt" in
        d) DEVICE="$OPTARG" ;;
        k) KEEP=1 ;;
        *) echo "usage: $0 [-d device] [-k]" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
# Kept across runs so CI and repeat local runs do not rebuild from scratch.
# `build/` is already gitignored.
DERIVED="${DERIVED:-$REPO_ROOT/build/e2e-derived-data}"
TEST_LOG="$WORK/test.log"

cleanup() {
    if [ "$KEEP" -eq 0 ]; then
        rm -rf "$WORK"
    else
        echo "keeping work directory: $WORK"
    fi
}
trap cleanup EXIT

say() { printf '\n==> %s\n' "$1"; }

# --- 1. A booted simulator ------------------------------------------------

say "Booting simulator: $DEVICE"
UDID="$(xcrun simctl list devices available \
    | grep -F "$DEVICE (" \
    | head -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"

if [ -z "$UDID" ]; then
    echo "No available simulator named '$DEVICE'." >&2
    echo "Available devices:" >&2
    xcrun simctl list devices available >&2
    exit 1
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

# --- 3. Build and install -------------------------------------------------

say "Building for testing"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    build-for-testing

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -not -path '*Runner*' | head -1)"
if [ -z "$APP" ]; then
    echo "Could not find a built .app under $DERIVED/Build/Products" >&2
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
say "Installing $BUNDLE_ID"
xcrun simctl install "$UDID" "$APP"

# --- 4. Plant the database ------------------------------------------------

# Terminate first. A live connection would be writing underneath the copy, and
# closing it checkpoints the log away.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DOCUMENTS="$CONTAINER/Documents"
mkdir -p "$DOCUMENTS"

# The suite builds and plants its own corrupted database, with the SAME
# builder the in-process tests use, so there is one implementation of the
# fixture rather than a Swift one and a Python one kept in step by hand. That
# also removes the marker file this script used to plant to switch the suite
# from "skip" to "assert": a suite that builds its own data has nothing to gate
# on.
#
# Only the escrow is cleared here, so the counts the run reports mean what they
# say from a known-empty start.
rm -f "$DOCUMENTS/voting-delegation-escrow.json"

# --- 4. Drive the recovery ------------------------------------------------

say "Running the on-device recovery suite"
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -only-testing:zodlTests/DelegationRecoveryDeviceE2ETests \
    test-without-building 2>&1 | tee "$TEST_LOG"
STATUS=${PIPESTATUS[0]}
set -e

# --- 5. Report ------------------------------------------------------------

if [ "$STATUS" -ne 0 ]; then
    say "FAILED: recovery did not restore the broadcast delegation"
    exit "$STATUS"
fi

# A green xcodebuild is not evidence the suite ran. If the gate fails to
# engage, every test SKIPS and the run still reports success, which is exactly
# the false pass this check exists to turn into a failure.
PASSED=$(grep -coE 'Test [A-Za-z]+\(\) passed' "$TEST_LOG" || true)
SKIPPED=$(grep -coE 'Test [A-Za-z]+\(\) skipped' "$TEST_LOG" || true)
say "Suite outcome: $PASSED passed, $SKIPPED skipped"
if [ "$SKIPPED" -ne 0 ] || [ "$PASSED" -lt "$EXPECTED_TESTS" ]; then
    echo "The recovery suite did not actually run. Treat this as a failure." >&2
    exit 1
fi

# A count alone cannot tell a renamed test from a deleted one, and the test
# that matters most is the one asserting the LAUNCH restores the secrets.
# Require it by name.
for required in \
    openingTheAppRecoversTheBroadcastDelegationAndEscrowsIt \
    openingTheAppTwiceLeavesTheEscrowUnchanged \
    openingTheAppDoesNotModifyThePlantedFiles \
    everyRecoveredSecretIsACanonicalPallasElement \
    theCorruptedDatabaseWasPlantedInTheContainer
do
    if ! grep -q "Test ${required}() passed" "$TEST_LOG"; then
        echo "Required test did not pass: ${required}" >&2
        echo "Either it failed, or it was renamed and this script was not." >&2
        exit 1
    fi
done

# `test-without-building` reinstalls the app, and the data container is
# migrated to a fresh path. The planted files follow it (the suite's first test
# asserts exactly that), but the shell's earlier handle is stale, so resolve it
# again before looking for what the run wrote.
DOCUMENTS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents"

ESCROW="$DOCUMENTS/voting-delegation-escrow.json"
say "Escrow written by the recovery"
if [ ! -f "$ESCROW" ]; then
    echo "No escrow file, yet the suite passed. Treat this as a failure." >&2
    exit 1
fi
cat "$ESCROW"

# The suite asserts the escrow's contents itself, in
# openingTheAppRecoversTheBroadcastDelegationAndEscrowsIt. This reads the file
# just printed a second time, independently of the test log, so a green log
# and a wrong escrow can never be reported together.
#
# The values are `Fixture.originalRand` and `Fixture.rebuiltRand` in
# CorruptedVotingDatabase.swift: one byte repeated 31 times, then 0x01. Change
# them there and this check fails loudly, which is the intent.
say "Checking the escrow holds the broadcast secrets"
python3 - "$ESCROW" <<'PY'
import base64, json, sys

def secret(byte):
    return bytes([byte] * 31 + [0x01]).hex()

round_id = "4a" * 32
broadcast = {secret(b) for b in (0xA0, 0xA1, 0xA2)}
rebuilt = {secret(b) for b in (0xB0, 0xB1, 0xB2)}

with open(sys.argv[1]) as escrow:
    entries = json.load(escrow)["entries"]
held = {
    base64.b64decode(entry["vanCommRand"]).hex()
    for entry in entries
    if entry["roundId"].lower() == round_id
}

missing = broadcast - held
if missing:
    print(f"escrow is missing broadcast secrets: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
if held & rebuilt:
    print("a rebuilt secret was escrowed as though it were the original", file=sys.stderr)
    sys.exit(1)
print(f"escrow holds all {len(broadcast)} broadcast secrets and none of the rebuilt ones")
PY

if [ "$KEEP" -eq 0 ]; then
    xcrun simctl shutdown "$UDID" || true
fi

say "PASSED: opening the app recovered and escrowed the broadcast delegation"
