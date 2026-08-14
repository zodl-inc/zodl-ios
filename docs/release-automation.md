# Release automation (local fastlane)

Build, sign, and submit any ZODL iOS or macOS variant from your Mac with one command. It
signs with the same Xcode identity you already use to Archive by hand, so **no
signing keys are stored in the repo or anywhere new**. A fail-closed *preflight*
reconciles what you ask for against git, the project, and App Store Connect, and
refuses to build on any mismatch.

`fastlane/README.md` is the one-screen quick reference.

## How it fits together

| Piece | Role |
|---|---|
| `Scripts/release.sh`, `Scripts/bump.sh` | GNU-style CLI wrappers you run |
| `fastlane/Fastfile` | the `release` and `bump` lanes |
| `fastlane/lib/zodl/` | pure preflight logic (unit-tested) |
| `fastlane/spec/*_test.rb` | tests for that logic (see [Tests](#tests-and-project-files)) |
| `git worktree` (temporary) | each build runs against a clean checkout of the exact ref |

You call the wrappers; they run `bundle exec fastlane`; fastlane gathers facts,
runs the preflight, then builds in a throwaway worktree and uploads to App Store
Connect. (Running fastlane *without* bundler is rejected, so everyone uses the
pinned gem versions.)

## Prerequisites & first-time setup

### A. Set up a fresh Mac (the toolchain — once per machine)

```bash
# 1. Xcode — install from the App Store, then point the CLI tools at it and
#    accept the licence. Your Xcode must match the version in .xcode-version.
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# 2. Homebrew (https://brew.sh)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. rbenv + ruby-build, and wire rbenv into your shell (zsh shown)
brew install rbenv ruby-build
echo 'eval "$(rbenv init - zsh)"' >> ~/.zshrc
exec zsh                 # reload the shell so rbenv is active

# 4. Ruby — `rbenv install` with no argument reads .ruby-version and installs
#    exactly that version (4.0.5). Then refresh shims.
cd <path-to>/zodl-ios
rbenv install            # installs the version pinned in .ruby-version
rbenv rehash

# 5. Project gems. Bundler ships with Ruby; `bundle install` automatically
#    fetches the bundler version pinned in Gemfile.lock, then the gems.
bundle install

# 6. Build-output formatter and DMG tooling. xcbeautify — required: the fastlane
#    lanes pin it as the xcodebuild log formatter (the xcpretty fallback predates
#    Swift Testing and would silently swallow its test output). create-dmg builds
#    the drag-to-Applications disk image for the mac DMG variants.
brew install xcbeautify create-dmg

# 7. (optional) the test runner for the wrapper scripts
brew install bats-core
```

`bats-core` is "Bash Automated Testing System" — it provides the `bats` command
used to run `Scripts/test/release_args.bats`. It is **only** needed to run those
tests; you do not need it to build or ship.

### B. Secrets and inputs (per machine, but not committed)

1. **App Store Connect API key.** As an **Account Holder or Admin**, in App Store
   Connect → *Users and Access* → **Integrations** → *App Store Connect API*
   (Team Keys):
   - Click **+**, name the key, set the role to **App Manager** (enough to upload
     builds and read build numbers), and **Generate**.
   - Copy the **Key ID** (next to the key) and the **Issuer ID** (top of the page).
   - Click **Download API Key** to get `AuthKey_<KEYID>.p8`. **You can only
     download it once** — Apple keeps no copy; if lost, revoke and create a new one.

   Put the `.p8` in `fastlane/` (it's gitignored, so it won't be committed) and
   reference it by filename — `ASC_KEY_FILEPATH` is resolved relative to the
   `fastlane/` directory. An absolute path anywhere also works. Then:
   ```bash
   cp fastlane/.env.example fastlane/.env
   # set ASC_KEY_ID (the Key ID), ASC_ISSUER_ID (the Issuer ID), and
   # ASC_KEY_FILEPATH — e.g. just AuthKey_<KEYID>.p8 when the key is in fastlane/
   ```
   `fastlane/.env` and `*.p8` are gitignored — they are never committed.
2. **Partner keys.** Put `PartnerKeys.plist` at `secant/Resources/PartnerKeys.plist`
   (gitignored; required to build).
3. **Signing certificates.** The tooling reuses identities from your login
   keychain; it does not create or manage certificates. Baseline: you must
   already be able to Archive and upload from Xcode by hand (automatic signing,
   team `RLPRR8CPQG`). Required per variant:

   | Variant(s) | Certificate(s) needed in the keychain |
   |---|---|
   | `ios-internal`, `ios-testnet`, `ios-appstore` (iOS) | **Apple Distribution** |
   | `mac-internal`, `mac-testnet` (macOS TestFlight) | **Apple Distribution** + **Mac Installer Distribution** (signs the uploaded `.pkg`) |
   | `mac-internal-dmg`, `mac-testnet-dmg` (macOS DMG, outside the App Store) | **Developer ID Application** |

   Apple Distribution and Mac Installer Distribution can be created by any team
   **Admin** (Xcode → Settings → Accounts → Manage Certificates…, or the
   developer portal). Developer ID Application can only be created by the
   **Account Holder** — the hand-off flow is documented in
   [docs/macos/DEVELOPER_ID_CERTIFICATE.md](macos/DEVELOPER_ID_CERTIFICATE.md).
   Notarization (part of the DMG flow) needs **no certificate** — it
   authenticates with the same App Store Connect API key from step 1.

### C. Quick check

```bash
bundle exec rake test        # tooling logic passes
./Scripts/release.sh --help  # wrapper runs
```

## The variants

Build numbers are validated against the variant's own App Store Connect train
(app record + platform). The two mac flavors install side by side — different
bundle ids, different `.app` names, different DMG names.

| `--variant` | Scheme | App Store Connect app | Goes to |
|---|---|---|---|
| `ios-internal` | `zodl-internal` | `co.electriccoin.secant-testnet` (iOS) | TestFlight |
| `ios-testnet` | `zodl-testnet` | `co.ecc.zashi-testnet` (iOS) | TestFlight |
| `ios-appstore` | `zodl-AppStore` | `co.electriccoin.secant-mainnet` (iOS) | App Store |
| `mac-internal` | `zodlmac-internal` | `co.electriccoin.secant-testnet` (macOS) | TestFlight |
| `mac-testnet` | `zodlmac-testnet` | `co.ecc.zashi-testnet` (macOS) | TestFlight |
| `mac-internal-dmg` | `zodlmac-internal` | — (no upload) | notarized DMG in `build/` |
| `mac-testnet-dmg` | `zodlmac-testnet` | — (no upload) | notarized DMG in `build/` |
| `ios-internal-testnet` | — | both iOS TestFlight apps | builds `ios-internal` then `ios-testnet`, running tests once |

DMG artifacts land at `build/ZODL-<flavor>-<version>-<build>.dmg` (e.g.
`build/ZODL-testnet-3.7.1-7.dmg`) — signed, notarized, stapled, with a
drag-to-Applications window.

## Everyday use — the release flow

**You do not need to check out the branch you want to build.** Pass it to `--ref`
(a branch, tag, or commit); the script fetches from `origin`, resolves it (it
tries `<ref>` and then `origin/<ref>`), and builds it in an isolated `git
worktree`. Your current checkout and working changes are left untouched.

**1. Start a new version (in `main`).** Set and commit the marketing version, push,
then cut the release branch:

```bash
./Scripts/bump.sh --version 3.8.0 --build 1 --target ios   # edits the project + commits
git push                                                    # push the bump commit on main
git checkout -b release/3.8.0
git push -u origin release/3.8.0
```

**2. Build the TestFlight pair** from the release branch — note you can run this
from any checkout, e.g. while still on `main`:

```bash
./Scripts/release.sh --variant ios-internal-testnet --ref release/3.8.0 --version 3.8.0 --build 1
```

**3. Need a fix?** Commit and push it on `release/3.8.0`, then rebuild with the next
build number:

```bash
./Scripts/release.sh --variant ios-internal-testnet --ref release/3.8.0 --version 3.8.0 --build 2
```

**4. Ship to the App Store** when you're happy:

```bash
./Scripts/release.sh --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 1
```

`ios-appstore` is its own App Store Connect app, so its build numbers are a separate
sequence — start from wherever that app left off.

#### Submitting to App Review with `--submit-review`

After the build is uploaded and App Store Connect has processed it, you can submit it for review:

With `--ref` (build in one go, then submit):
```bash
./Scripts/release.sh --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 1 --submit-review
```

Without `--ref` (submit an already-uploaded build):
```bash
./Scripts/release.sh --variant ios-appstore --version 3.8.0 --build 1 --submit-review
```

Submitting to App Review:
- Creates the App Store version record if missing, or adopts an existing one in an editable state (PREPARE_FOR_SUBMISSION, developer-rejected, rejected, metadata-rejected, invalid-binary), renaming it if needed
- Copies promotional text from the live version into any localization that doesn't have one yet (manually entered text is kept, never overwritten)
- Writes What's New for every enabled App Store localization from `secant/Resources/WhatsNew/whatsNew*.json` in your **current checkout** (the entry matching `--version` — run `/update-whatsnew` first and commit; note this uses your local working tree, not the ref being built)
- Attaches the requested build, replacing a wrong one
- Submits with manual release — you still press Release in App Store Connect after approval
- Reads back promotional text and What's New per locale from App Store Connect and warns loudly if promotional text is empty where a copy was planned (this is **non-fatal and fixable in App Store Connect without a new review** — edit the missing text directly in ASC and save)

The submission fails if: a version is already submitted/in review (cancel in App Store Connect first), a version is approved-awaiting-release (release it first), the requested version is already live, or any enabled App Store localization lacks a What's New entry for the version.

**macOS builds** work the same way — pick the variant:

```bash
# TestFlight (internal = mainnet, testnet = testnet network):
./Scripts/release.sh --variant mac-internal --ref ironwood-testnet-demo --version 3.7.1 --build 8
# Notarized DMG for distribution outside the App Store:
./Scripts/release.sh --variant mac-testnet-dmg --ref ironwood-testnet-demo --version 3.7.1 --build 8
```

## Always check first with `--dry-run`

Add `--dry-run` to run every preflight check and print the reconciliation summary
**without building** — the cheap way to confirm your intent is correct:

```bash
./Scripts/release.sh --variant ios-appstore --ref release/3.8.0 --version 3.8.0 --build 1 --dry-run
```

The preflight blocks the build if: the version doesn't match the **built
target's** `MARKETING_VERSION` (targets are versioned independently — macOS
does not track iOS) or the `release/X.Y.Z` branch; the build number duplicates
or regresses the variant's own App Store Connect train (DMG variants have no
train — only positivity is checked); the ref isn't on `origin`;
`PartnerKeys.plist` is missing/invalid; Xcode doesn't match `.xcode-version`;
a required signing identity is missing (named per variant — see the
certificate matrix above); or the local `../ZcashLightClientKit` checkout is
missing or its FFI lacks the platform's slice (macOS requires a lipo-verified
universal slice). It *warns* on a build-number gap, an uncommitted working
tree, or a dirty SDK checkout.

With `--submit-review`, the dry run also verifies the build's existence and processing state on App Store Connect, the version record's state, and that every enabled App Store localization has a What's New entry for the version.

## Command reference

```
Scripts/release.sh --variant <v> --ref <ref> --version <X.Y.Z> --build <n> [options]
  --variant       ios-internal | ios-testnet | ios-appstore | ios-internal-testnet |
                  mac-internal | mac-internal-dmg | mac-testnet | mac-testnet-dmg
  --ref           branch, tag, or commit to build (optional with --submit-review)
  --version       marketing version you intend to ship (X.Y.Z)
  --build         build number (integer)
  --dry-run       run checks, then stop before building
  --yes           skip the confirmation prompt
  --skip-tests    skip the unit-test step
  --submit-review submit to App Review after upload (ios-appstore only)
  -h, --help

Scripts/bump.sh --version <X.Y.Z> --build <n> --target <target|ios|mac|all>
  --target      an Xcode target name (e.g. zodlmac-testnet), 'ios' (all iOS app targets),
                'mac' (all macOS app targets), or 'all' (every app target) —
                targets are versioned independently
```

## Troubleshooting (preflight messages)

| Message | Fix |
|---|---|
| `version … does not match project MARKETING_VERSION …` | Run `bump` scoped to the variant's target first (e.g. `--target zodlmac-internal` for mac variants), or pass the version that target is actually at. |
| `build N already exists` / `is lower than the latest build` | Pick a higher number — check that variant's app in App Store Connect / TestFlight. With `--submit-review`, you can instead drop `--ref` to submit that already-uploaded build. |
| `ref is not on origin` | `git push` the branch or commit first. |
| `Could not resolve ref …` | The branch/tag/commit isn't on `origin` or locally — push or fetch it. |
| `PartnerKeys.plist is missing or invalid` | Place a valid plist at `secant/Resources/PartnerKeys.plist` (see `Scripts/validate-partner-keys.sh`). |
| `Xcode version does not match .xcode-version` | Switch Xcode (e.g. `xcodes select`) to the pinned version, or update `.xcode-version`. |
| `missing signing identity in keychain: '<name>'` | Create/import that certificate (see the certificate matrix in section B). |
| `Run through bundler …` | Use `./Scripts/release.sh` / `./Scripts/bump.sh` (or `bundle exec fastlane …`), not bare `fastlane`. |
| TestFlight build stuck on *Missing Compliance* | Set `ITSAppUsesNonExemptEncryption` so the build clears export compliance automatically. |
| `build … not found on App Store Connect — pass --ref` | The build was never uploaded: add `--ref` to build it, or fix `--build`. |
| `build … is still processing` | App Store Connect is still processing the upload — retry in a few minutes. |
| `already submitted for review` | Cancel the submission in App Store Connect, or wait for the review to finish. |
| `approved and awaiting release` | Release the approved version in App Store Connect first. |
| `whatsNew….json has no entry for version …` | Run `/update-whatsnew` for this version and commit the result. |
| `version … is already live` | That version shipped — bump with `Scripts/bump.sh` and build the next one. |

## Tests and project files

The `fastlane/spec/*_test.rb` files are **tests for the release tooling itself**,
not for the app. They are minitest unit tests covering the preflight decision
logic in `fastlane/lib/zodl/` (version parsing, the variant table, build-number
validation, and the full reconciliation). The app's own tests are the Swift
`zodlTests` suite and are unrelated.

These tests are **not run automatically** today — there is no CI hook for them yet
(a possible future addition). Run them by hand:

```bash
bundle exec rake test                 # Ruby preflight logic (minitest)
bats Scripts/test/release_args.bats   # wrapper arg parsing (needs bats-core)
```
