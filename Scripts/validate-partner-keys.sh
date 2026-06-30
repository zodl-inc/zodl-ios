#!/bin/bash
#
# validate-partner-keys.sh
#
# Fails an Xcode *archive* build when secant/Resources/PartnerKeys.plist is
# missing, malformed, or missing any required key. No-op for normal builds.
#
# The REQUIRED_KEYS list mirrors the `Constants` enum in
# secant/Sources/Dependencies/PartnerKeys/PartnerKeys.swift — keep them in sync.

# Run only during Product -> Archive. Xcode sets ACTION=install for archive
# builds; normal build / Run set ACTION=build.
if [ "${ACTION:-}" != "install" ]; then
    exit 0
fi

# SRCROOT is exported by Xcode. Default to the repo root so the script can be
# run by hand (and by the test harness) outside Xcode.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLIST="${SRCROOT}/secant/Resources/PartnerKeys.plist"

# Each key must be present, of type String, and non-empty. testSeed is
# #if DEBUG-only and intentionally excluded from archive validation.
REQUIRED_KEYS="flexaPublishableKey flexaPublishableTestKey nearKey cmcKey nearFeeDepositAddress nearAPIKey"

errors=()

if [ ! -f "$PLIST" ]; then
    errors+=("file not found at ${PLIST}")
elif ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    errors+=("not a valid property list")
else
    for key in $REQUIRED_KEYS; do
        if plutil -extract "$key" xml1 -o - "$PLIST" 2>/dev/null | grep -q "<string>"; then
            value="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null)"
            if [ -z "$(printf '%s' "$value" | tr -d '[:space:]')" ]; then
                errors+=("key '${key}' is empty")
            fi
        elif plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1; then
            errors+=("key '${key}' is not a String")
        else
            errors+=("missing key '${key}'")
        fi
    done
fi

if [ "${#errors[@]}" -gt 0 ]; then
    for e in "${errors[@]}"; do
        echo "error: PartnerKeys.plist: ${e}"
    done
    echo "error: PartnerKeys.plist is invalid — archive aborted (see messages above)."
    exit 1
fi

echo "PartnerKeys.plist OK — all required keys present."
exit 0
