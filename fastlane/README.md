# Release automation (local fastlane)

Build, sign, and submit ZODL iOS variants from your Mac. Signs with your existing
Xcode identity — no keys are stored in the repo or anywhere new.

## One-time setup

1. Ruby is pinned by `.ruby-version` (4.0.5); install it with `rbenv install` if needed.
2. `bundle install`
3. `brew install bats-core` (only needed to run the wrapper tests)
4. Create an App Store Connect API key (App Store Connect → Users and Access →
   Integrations), download the `.p8`, then `cp fastlane/.env.example fastlane/.env`
   and fill in `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_FILEPATH`.
5. Put `PartnerKeys.plist` at `secant/Resources/PartnerKeys.plist`.
6. Ensure your Xcode matches `.xcode-version`.

## Commands

Build a variant:

    ./Scripts/release.sh --variant appstore --ref release/3.8.0 --version 3.8.0 --build 3

`--variant` is one of `internal`, `testnet`, `appstore`, or `internal-testnet`
(builds internal then testnet, running tests once). `--ref` is any branch, tag,
or commit.

Dry run (all checks, no build):

    ./Scripts/release.sh --variant appstore --ref release/3.8.0 --version 3.8.0 --build 3 --dry-run

Bump the marketing version + build (the deliberate version-change step, run in `main`):

    ./Scripts/bump.sh --version 3.8.0 --build 1

Other flags: `--yes` (skip confirmation), `--skip-tests`, `--help`.

## What it checks before building

Preflight reconciles your declared `--version` / `--build` / `--variant` / `--ref`
against git, the project, and App Store Connect, and refuses to build on any
mismatch: wrong version (vs the project `MARKETING_VERSION` and the release
branch), a duplicate or regressing build number (checked against the variant's
own App Store Connect app), an unpushed ref, a missing/invalid `PartnerKeys.plist`,
the wrong Xcode, or no distribution signing identity. Run with `--dry-run` to see
it without building.

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
