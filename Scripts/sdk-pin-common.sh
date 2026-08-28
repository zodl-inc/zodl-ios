#!/bin/bash
# Shared helpers for the SDK pin tooling (update-sdk-pin.sh,
# setup-sdk-companion.sh). The pin file (.sdk-pin) records the
# zodl-swift-wallet-sdk commit the app was last built against: a 40-hex sha,
# "<sha>-dirty", or empty (remote SDK mode). A clean pin may carry a trailing
# annotation, "<sha> <tag>", when the pinned commit has an exact-match tag —
# purely informational, never present on a "-dirty" pin.
#
# The first whitespace-separated field of the pin file is the machine truth:
# it's the only part any consumer (setup-sdk-companion.sh, CI) reads or
# trusts. Anything after it is a human-readable annotation and must never be
# parsed as part of the sha/dirty value.
#   read_pin      -> first field only (what consumers should use)
#   read_pin_line -> full first line, trimmed (for write-on-change diffing)

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

# Prints the machine-read value of the pin file: the first whitespace-
# separated field of the first line only, ignoring any trailing tag
# annotation. Empty when the file is missing or blank.
read_pin() {
    local pin_file="$1"
    [ -f "$pin_file" ] || return 0
    awk 'NR==1 {print $1; exit}' "$pin_file"
}

# Prints the pin file's full first line with leading/trailing whitespace
# trimmed (sha and, when present, its tag annotation). Used to detect changes
# worth rewriting the file for — e.g. a tag appearing later on the same sha.
# Empty when the file is missing or blank.
read_pin_line() {
    local pin_file="$1"
    [ -f "$pin_file" ] || return 0
    awk 'NR==1 {print; exit}' "$pin_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
