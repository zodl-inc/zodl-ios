#!/usr/bin/env bash
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

usage() {
  cat <<'EOF'
Usage: Scripts/bump.sh --version <X.Y.Z> --build <n> --target <t>

  --version   marketing version to set (X.Y.Z)
  --build     build number to set
  --target    an Xcode target name (e.g. zodlmac-testnet), 'ios' (all iOS app
              targets), 'mac' (all macOS app targets), or 'all' (every app
              target). Targets are versioned independently — macOS does not
              track iOS.
  -h, --help  show this help
EOF
}

VERSION="" ; BUILD="" ; TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2" ; shift 2 ;;
    --build) BUILD="$2" ; shift 2 ;;
    --target) TARGET="$2" ; shift 2 ;;
    -h|--help) usage ; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2 ; usage >&2 ; exit 2 ;;
  esac
done

[[ -z "$VERSION" ]] && { echo "error: --version is required" >&2 ; usage >&2 ; exit 2 ; }
[[ -z "$BUILD" ]] && { echo "error: --build is required" >&2 ; usage >&2 ; exit 2 ; }
[[ -z "$TARGET" ]] && { echo "error: --target is required" >&2 ; usage >&2 ; exit 2 ; }

FASTLANE="${FASTLANE_CMD:-bundle exec fastlane}"
exec $FASTLANE bump version:"$VERSION" build:"$BUILD" target:"$TARGET"
