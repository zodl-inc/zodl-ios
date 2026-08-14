#!/usr/bin/env bash
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh --variant <v> --ref <ref> --version <X.Y.Z> --build <n> [options]

  --variant     ios-internal | ios-testnet | ios-appstore | ios-internal-testnet |
                mac-internal | mac-internal-dmg | mac-testnet | mac-testnet-dmg
  --submit-review  ios-appstore only: submit the build to App Review after upload;
                   without --ref, submits a build already on App Store Connect
  --ref         branch, tag, or commit SHA to build (optional with --submit-review)
  --version     marketing version you intend to ship (X.Y.Z)
  --build       build number (integer)
  --dry-run     run all preflight checks, then stop before building
  -y, --yes     skip the confirmation prompt
  --skip-tests  skip the unit-test step
  -h, --help    show this help
EOF
}

VARIANT="" ; REF="" ; VERSION="" ; BUILD=""
DRY_RUN=false ; YES=false ; SKIP_TESTS=false ; SUBMIT_REVIEW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2" ; shift 2 ;;
    --ref) REF="$2" ; shift 2 ;;
    --version) VERSION="$2" ; shift 2 ;;
    --build) BUILD="$2" ; shift 2 ;;
    --submit-review) SUBMIT_REVIEW=true ; shift ;;
    --dry-run) DRY_RUN=true ; shift ;;
    -y|--yes) YES=true ; shift ;;
    --skip-tests) SKIP_TESTS=true ; shift ;;
    -h|--help) usage ; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2 ; usage >&2 ; exit 2 ;;
  esac
done

for pair in "variant:$VARIANT" "version:$VERSION" "build:$BUILD"; do
  name="${pair%%:*}" ; val="${pair#*:}"
  if [[ -z "$val" ]]; then echo "error: --$name is required" >&2 ; usage >&2 ; exit 2 ; fi
done

if [[ -z "$REF" && "$SUBMIT_REVIEW" != true ]]; then
  echo "error: --ref is required (omit it only with --submit-review)" >&2 ; usage >&2 ; exit 2
fi
if [[ "$SUBMIT_REVIEW" == true && "$VARIANT" != "appstore" ]]; then
  echo "error: --submit-review requires --variant appstore" >&2 ; usage >&2 ; exit 2
fi

FASTLANE="${FASTLANE_CMD:-bundle exec fastlane}"
exec $FASTLANE release \
  variant:"$VARIANT" ref:"$REF" version:"$VERSION" build:"$BUILD" \
  dry_run:"$DRY_RUN" yes:"$YES" skip_tests:"$SKIP_TESTS" submit_review:"$SUBMIT_REVIEW"
