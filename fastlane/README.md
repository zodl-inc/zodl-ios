# Release automation (local fastlane)

Build, sign, and submit ZODL iOS and macOS variants from your Mac. Signs with your existing
Xcode identity — no keys are stored in the repo or anywhere new.

## One-time setup

1. Ruby is pinned by `.ruby-version` (4.0.5); install it with `rbenv install` if needed.
2. `bundle install`
3. `brew install xcbeautify create-dmg` (xcbeautify formats xcodebuild output including Swift Testing results; create-dmg builds the drag-to-Applications disk image)
4. `brew install bats-core` (only needed to run the wrapper tests)
5. Create an App Store Connect API key (App Store Connect → Users and Access →
   Integrations), download the `.p8`, then `cp fastlane/.env.example fastlane/.env`
   and fill in `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_FILEPATH`.
6. Put `PartnerKeys.plist` at `secant/Resources/PartnerKeys.plist`.
7. Ensure your Xcode matches `.xcode-version`.

## Commands

Build a variant:

    ./Scripts/release.sh --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 3

`--variant` is one of `ios-internal`, `ios-testnet`, `ios-appstore`, `ios-internal-testnet` (builds ios-internal then ios-testnet, running tests once), `mac-internal`, `mac-internal-dmg`, `mac-testnet`, `mac-testnet-dmg` (macOS → TestFlight or notarized DMG). DMG artifacts land at `build/ZODL-<flavor>-<version>-<build>.dmg` (e.g. `build/ZODL-testnet-3.7.1-7.dmg`). `--ref` is any branch, tag, or commit.

Dry run (all checks, no build):

    ./Scripts/release.sh --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 3 --dry-run

Build, upload, and submit to App Review in one go (`appstore` only):

    ./Scripts/release.sh --variant appstore --ref release/3.8.0 --version 3.8.0 --build 3 --submit-review

Submit a build that is already on App Store Connect (omit `--ref`):

    ./Scripts/release.sh --variant appstore --version 3.8.0 --build 3 --submit-review

Submitting creates (or adopts) the App Store version record, copies promotional
text from the live version into any localization that doesn't have one yet,
writes What's New for every enabled localization from
`secant/Resources/WhatsNew/whatsNew*.json` (the entry matching `--version`),
attaches the build (replacing a wrong one), and submits with manual release —
you still press Release in App Store Connect after approval. It refuses to run
when a version is already in review or approved-but-unreleased.

Bump the marketing version + build (the deliberate version-change step, run in `main`):

    ./Scripts/bump.sh --version 3.8.0 --build 1 --target ios

`--target` scopes the bump and is required: an Xcode target name (e.g.
`zodlmac-internal`), `ios` (all iOS app targets), `mac` (all macOS app targets), or `all`. Targets are
versioned independently — bumping iOS never rewrites the macOS app.

Other flags: `-y` / `--yes` (skip confirmation), `--skip-tests`, `--submit-review` (`appstore` only), `--help`.

## What it checks before building

Preflight reconciles your declared `--version` / `--build` / `--variant` / `--ref`
against git, the project, and App Store Connect, and refuses to build on any
mismatch: wrong version (vs the built target's `MARKETING_VERSION` — targets are
versioned independently, e.g. macOS vs iOS — and the release
branch), a duplicate or regressing build number (checked against the variant's
own App Store Connect app), an unpushed ref, a missing/invalid `PartnerKeys.plist`,
the wrong Xcode, no distribution signing identity, or a local ../ZcashLightClientKit
checkout missing its platform's FFI slice — every variant needs this checkout, not
just macOS. macOS variants additionally require the matching certificates (TestFlight:
Apple Distribution + Mac Installer Distribution; DMG: Developer ID Application). Run with
`--dry-run` to see it without building.

If the project at the built ref references local Swift packages (e.g. a local
`../ZcashLightClientKit` checkout), preflight fails when that directory is
missing and otherwise warns with the package's git state — the build consumes
that checkout as-is (HEAD plus any uncommitted changes), so it is not
reproducible from this repo alone. The throwaway build worktree is created
beside the repo precisely so those relative references resolve to the same
directories Xcode uses.

## Notifications

A finished `release` posts a native macOS notification with a sound, so you can
step away during the build/upload: **Ping** on success (and on a passing
`--dry-run`), **Basso** on failure. It uses the built-in `osascript`
(`display notification`) — nothing extra is installed. (`bump` does not notify.)

The first notification may prompt you to allow notifications for your terminal app
(Terminal, iTerm, …) in System Settings → Notifications — allow it once. Set
`ZODL_NOTIFY=0` to silence them (they are also skipped automatically when `CI` is set).

## Tests

    bundle exec rake test                 # Ruby preflight logic (minitest)
    bats Scripts/test/release_args.bats   # wrapper arg parsing
