#!/bin/bash
# Shared helpers for the SDK pin tooling (update-sdk-pin.sh,
# setup-sdk-companion.sh). The pin file (.sdk-pin) records the
# zodl-swift-wallet-sdk commit the app was last built against: a 40-hex sha,
# "<sha>-dirty", or empty (remote SDK mode).

# Prints the relativePath of the local SDK package reference, or nothing when
# the project references the SDK remotely. relativePath keys appear only in
# XCLocalSwiftPackageReference entries of a pbxproj, so a whole-file scan is
# safe; the basename filter keeps other local packages from matching.
sdk_local_relative_path() {
    local pbxproj="$1"
    sed -n 's/^[[:space:]]*relativePath = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' "$pbxproj" |
        while IFS= read -r p; do
            if [ "$(basename "$p")" = "zodl-swift-wallet-sdk" ]; then
                printf '%s\n' "$p"
                return 0
            fi
        done
}

# Prints the pin file's content with all whitespace stripped; empty when the
# file is missing or blank.
read_pin() {
    local pin_file="$1"
    [ -f "$pin_file" ] || return 0
    tr -d '[:space:]' < "$pin_file"
}
