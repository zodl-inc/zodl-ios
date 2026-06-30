#!/usr/bin/env bash
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh --variant <v> --ref <ref> --version <X.Y.Z> --build <n> [options]

  --variant     internal | testnet | appstore | internal-testnet
  --ref         branch, tag, or commit SHA to build
  --version     marketing version you intend to ship (X.Y.Z)
  --build       build number (integer)
  --dry-run     run all preflight checks, then stop before building
  --yes         skip the confirmation prompt
  --skip-tests  skip the unit-test step
  -h, --help    show this help
EOF
}

VARIANT="" ; REF="" ; VERSION="" ; BUILD=""
DRY_RUN=false ; YES=false ; SKIP_TESTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2" ; shift 2 ;;
    --ref) REF="$2" ; shift 2 ;;
    --version) VERSION="$2" ; shift 2 ;;
    --build) BUILD="$2" ; shift 2 ;;
    --dry-run) DRY_RUN=true ; shift ;;
    --yes) YES=true ; shift ;;
    --skip-tests) SKIP_TESTS=true ; shift ;;
    -h|--help) usage ; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2 ; usage >&2 ; exit 2 ;;
  esac
done

for pair in "variant:$VARIANT" "ref:$REF" "version:$VERSION" "build:$BUILD"; do
  name="${pair%%:*}" ; val="${pair#*:}"
  if [[ -z "$val" ]]; then echo "error: --$name is required" >&2 ; usage >&2 ; exit 2 ; fi
done

FASTLANE="${FASTLANE_CMD:-bundle exec fastlane}"
exec $FASTLANE release \
  variant:"$VARIANT" ref:"$REF" version:"$VERSION" build:"$BUILD" \
  dry_run:"$DRY_RUN" yes:"$YES" skip_tests:"$SKIP_TESTS"
