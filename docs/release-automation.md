# Release automation (local fastlane)

Build, sign, and submit any ZODL iOS variant from your Mac with one command. It
signs with the same Xcode identity you already use to Archive by hand, so **no
signing keys are stored in the repo or anywhere new**. A fail-closed *preflight*
reconciles what you ask for against git, the project, and App Store Connect, and
refuses to build on any mismatch.

`fastlane/README.md` is the one-screen quick reference.

## How it fits together

| Piece | Role |
|---|---|
| `Scripts/prepare-release.sh` | cuts the release branches and opens the release PR (git + `gh` only) |
| `Scripts/lib/release-lib.sh` | its text transforms and preflight predicates (unit-tested) |
| `Scripts/release.sh`, `Scripts/bump.sh` | GNU-style CLI wrappers you run |
| `fastlane/Fastfile` | the `release` and `bump` lanes |
| `fastlane/lib/zodl/` | pure preflight logic (unit-tested) |
| `fastlane/spec/*_test.rb` | tests for that logic (see [Tests](#tests-and-project-files)) |
| `Scripts/test/*.bats` | tests for the wrapper scripts and the release library |
| `git worktree` (temporary) | each build runs against a clean checkout of the exact ref |
| `.claude/skills/make-builds/` | the `/make-builds` skill — runs a whole release's builds through the wrapper and announces them in Slack (see [Driving a whole run](#driving-a-whole-run-with-make-builds)) |

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

# 6. xcbeautify — required: the fastlane lanes pin it as the xcodebuild log
#    formatter (the xcpretty fallback predates Swift Testing and would silently
#    swallow its test output)
brew install xcbeautify

# 7. (optional) the test runner for the wrapper scripts
brew install bats-core
```

`bats-core` is "Bash Automated Testing System" — it provides the `bats` command
used to run the suites under `Scripts/test/`. It is **only** needed to run those
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
3. **Signing.** You must already be able to Archive and upload the app from Xcode
   by hand (Apple Distribution certificate, automatic signing, team `RLPRR8CPQG`).
   The tooling reuses that identity; it does not manage certificates.

### C. Quick check

```bash
bundle exec rake test        # tooling logic passes
./Scripts/release.sh --help  # wrapper runs
```

## The variants

Each variant is a **separate App Store Connect app**, so build numbers are
independent — a build number only has to beat that variant's own history.

| `--variant` | Scheme | App Store Connect app | Goes to |
|---|---|---|---|
| `internal` | `zodl-internal` | `co.electriccoin.secant-testnet` | TestFlight |
| `testnet` | `zodl-testnet` | `co.ecc.zashi-testnet` | TestFlight |
| `appstore` | `zodl-AppStore` | `co.electriccoin.secant-mainnet` | App Store |
| `internal-testnet` | — | both of the above | builds `internal` then `testnet`, running tests once |

## Everyday use — the release flow

**You do not need to check out the branch you want to build.** Pass it to `--ref`
(a branch, tag, or commit); the script fetches from `origin`, resolves it (it
tries `<ref>` and then `origin/<ref>`), and builds it in an isolated `git
worktree`. Your current checkout and working changes are left untouched.

**1. Cut the release** with `Scripts/prepare-release.sh` (see
[Cutting a release](#cutting-a-release) below for what it does and why):

```bash
./Scripts/prepare-release.sh start --dry-run upstream 3.8.0   # rehearse
./Scripts/prepare-release.sh start upstream 3.8.0
```

That leaves `release/3.8.0` and `candidate/3.8.0` on the remote, the marketing
version and build number recorded, and a pull request open between them.

**2. Build the TestFlight pair** from the **candidate** branch — note you can run
this from any checkout, e.g. while still on `main`:

```bash
./Scripts/release.sh --variant internal-testnet --ref candidate/3.8.0 --version 3.8.0 --build 1
```

`release/3.8.0` is still the *previous* release until the pull request merges,
so building from it would ship the wrong code.

**3. Need a fix?** Commit and push it on `candidate/3.8.0` — it appears in the
pull request — then rebuild with the next build number:

```bash
./Scripts/release.sh --variant internal-testnet --ref candidate/3.8.0 --version 3.8.0 --build 2
```

**4. Update What's New** before the App Store build. The App Store "What's
New" copy does **not** come from `CHANGELOG.md` — it lives in
`secant/Resources/WhatsNew/whatsNew*.json`: run `/update-whatsnew` for 3.8.0
and commit the result on `candidate/3.8.0`. `--submit-review` refuses in
preflight when a localization has no entry for the version, so a missing entry
blocks the submission — with `--ref`, before the build even starts.

**5. Ship to the App Store** when you're happy:

```bash
./Scripts/release.sh --variant appstore --ref candidate/3.8.0 --version 3.8.0 --build 1
```

`appstore` is its own App Store Connect app, so its build numbers are a separate
sequence — start from wherever that app left off.

**6. Finish the release.** Mark the pull request ready for review and merge it,
then tag and merge back — as a single chain, so a failed switch or pull cannot
put the tag on the wrong branch:

```bash
git switch release/3.8.0 &&
  git pull --ff-only upstream release/3.8.0 &&
  git tag -s 3.8.0 -m "Release 3.8.0" &&
  git push upstream refs/tags/3.8.0      # firing linear-release.yml is the last step
```

Then merge `release/3.8.0` into its maintenance line and forward to `main` —
the script's closing message and the pull request body name the exact branch
(`maint/v3.8.x`, or the line's existing spelling). Do not
cherry-pick: a tag that is not reachable from a live branch stops being part of
the history it shipped from, and the `Release Merged Back` check reports it.

#### Submitting to App Review with `--submit-review`

After the build is uploaded and App Store Connect has processed it, you can submit it for review:

With `--ref` (build in one go, then submit):
```bash
./Scripts/release.sh --variant appstore --ref candidate/3.8.0 --version 3.8.0 --build 1 --submit-review
```

Without `--ref` (submit an already-uploaded build):
```bash
./Scripts/release.sh --variant appstore --version 3.8.0 --build 1 --submit-review
```

Submitting to App Review:
- Creates the App Store version record if missing, or adopts an existing one in an editable state (PREPARE_FOR_SUBMISSION, developer-rejected, rejected, metadata-rejected, invalid-binary), renaming it if needed
- Copies promotional text from the live version into any localization that doesn't have one yet (manually entered text is kept, never overwritten)
- Writes What's New for every enabled App Store localization from `secant/Resources/WhatsNew/whatsNew*.json` in your **current checkout** (the entry matching `--version` — run `/update-whatsnew` first and commit; note this uses your local working tree, not the ref being built)
- Attaches the requested build, replacing a wrong one
- Submits with manual release — you still press Release in App Store Connect after approval
- Reads back promotional text and What's New per locale from App Store Connect and warns loudly if promotional text is empty where a copy was planned (this is **non-fatal and fixable in App Store Connect without a new review** — edit the missing text directly in ASC and save)

The submission fails if: a version is already submitted/in review (cancel in App Store Connect first), a version is approved-awaiting-release (release it first), the requested version is already live, or any enabled App Store localization lacks a What's New entry for the version.

## Cutting a release

`Scripts/prepare-release.sh start <remote> <version> [<revision>]` creates the
two branches a release runs on and opens the pull request between them:

- **`release/X.Y.Z`** starts out identical to the **previous release tag**.
- **`candidate/X.Y.Z`** starts at the revision being released (`HEAD` by
  default), and gets the CHANGELOG promotion and the version bump on top.

The pull request is `candidate/X.Y.Z → release/X.Y.Z`, opened as a **draft**;
marking it ready for review is part of declaring the release final (and is when
the E2E smoke suite runs, once). Basing it on the previous
tag is the whole point: **its diff is exactly what users receive relative to the
last release**, rather than the intervening development history. A release
branch cut from `main` would produce a diff against nothing anyone shipped.

Everything the release needs lands on the candidate branch, so that is what you
build and what reviewers read. `release/X.Y.Z` is not touched again until the
pull request merges — which is what declares the release final.

The script does, in order: check the tree, remote, `gh` login and version tool;
fetch tags; find the previous release tag reachable from the revision — refusing
when a newer release tag exists that the revision does not contain; refuse if
either branch already exists locally or on the remote; refuse if the CHANGELOG's
`## [Unreleased]` section *at the revision* is empty or already carries a
heading for this version. Only then does it do the local work — create
`release/X.Y.Z` and `candidate/X.Y.Z`, promote the CHANGELOG, set
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` across every non-test
target — and finish by pushing both branches in a single atomic push and opening
the draft pull request. A failure anywhere before that push leaves the remote
untouched.

```
Scripts/prepare-release.sh start [options] <remote> <version> [<revision>]
  --issue <N>       release tracking issue, referenced from the PR body
  --build <N>       build number to record (default: 1)
  --previous <tag>  base the release branch on this tag instead of the detected one
  --dry-run         print what would happen and change nothing
  -h, --help
```

**The version bump needs macOS.** It runs
`.claude/skills/update-app-version/scripts/set_version.py`, which reads the Xcode
project's object graph through `plutil`. `--dry-run` reports the requirement
rather than refusing, so the plan can be rehearsed anywhere.

`--previous` is for the case where the newest tag reachable from the revision is
not the release you are following — a patch cut from a maintenance line while a
newer version has already shipped from `main`. The tag must be an **ancestor**
of the revision: cutting a patch requires that line's previous release to have
been merged back into it first.

Tagging and the back-merge are step 6 above, done by hand. The
`Release Merged Back` check (`.github/workflows/release-merged-back.yml`) runs on
every pull request into a maintenance branch or `main` and reports any tagged
release branch that has not been merged back into its line. It is advisory and
never blocks; run it locally with:

```bash
REMOTE=upstream ./.github/scripts/check-release-merged-back.sh
```

## Always check first with `--dry-run`

Add `--dry-run` to run every preflight check and print the reconciliation summary
**without building** — the cheap way to confirm your intent is correct:

```bash
./Scripts/release.sh --variant appstore --ref candidate/3.8.0 --version 3.8.0 --build 1 --dry-run
```

The preflight blocks the build if: the version doesn't match the project's
`MARKETING_VERSION` or the version in the `release/X.Y.Z` / `candidate/X.Y.Z`
branch name; the build number duplicates or
is lower than the variant's latest on App Store Connect; the ref isn't on
`origin`; `PartnerKeys.plist` is missing/invalid; Xcode doesn't match
`.xcode-version`; or no distribution signing identity is present. It *warns* (but
proceeds) on a build-number gap or an uncommitted working tree.

With `--submit-review`, the dry run also verifies the build's existence and processing state on App Store Connect, the version record's state, and that every enabled App Store localization has a What's New entry for the version.

## Driving a whole run with `/make-builds`

`Scripts/release.sh` builds one variant. A release usually means several builds
in a row, each followed by a note to the team — so the repo also ships a Claude
Code skill, [`.claude/skills/make-builds/`](../.claude/skills/make-builds/SKILL.md),
that runs the wrapper for you, one build at a time, and announces every success
in a per-release Slack thread in `#wallet-team`.

It is a thin driver, not a second implementation: every build is the same
`./Scripts/release.sh …` invocation described above, with the same preflight and
the same failure modes. What it adds is sequencing, the Slack thread, and a
final report.

The skill is **manual only** — Claude never starts it on its own; you type
`/make-builds`. Invoking it authorizes the whole run: it will not stop to ask
"proceed?" before a build, before a Slack post, or after a failure.

### The invocation

One header line, then one line per build, then optional changelog lines:

```
/make-builds
release/3.8.0 3.8.0 2
internal-testnet
appstore submit-review
- Sending now works while a migration is running
- Keystone firmware 3.0.1 is the new minimum for signing
```

| Line | Format | Notes |
|---|---|---|
| Header (first non-blank line) | `<ref> <version> <build>` | Shared by every build of the run. `ref` is a branch, tag, or commit; `version` is `X.Y.Z`; `build` is an integer |
| Build line | `<variant> [skip-tests] [submit-review]` | `variant` is `internal`, `testnet`, `appstore`, or `internal-testnet`; options come in any order, at most once each; `submit-review` is `appstore`-only |
| Changelog line | starts with `-`, `*`, or `•` | Optional. Rendered in the thread parent only, never in the per-build replies |

Everything is validated **before anything runs**. A malformed header, an unknown
or repeated option, `submit-review` on a non-`appstore` line, the same variant
twice (`internal-testnet` counts as containing `internal` and `testnet`), or
zero build lines → every error is printed and no build starts. One build costs
30–90 minutes and uploads to TestFlight, so the skill never guesses a missing
value and never runs half a batch.

> The header carries `ref`/`version`/`build` once for the whole run. An older
> format repeated all three on every build line; paste one of those and the
> skill tells you so instead of misreading it.

### What happens per build

Builds run **strictly one at a time**, in the order you listed them — they share
one git repository, the local package checkout the project points at, and the
signing profile store, so parallel runs would collide. Each is launched in the
background (a foreground command would be killed at 10 minutes, a build takes
30–90+) with `-y` appended so the lane's confirmation prompt can't hang, and is
logged to the session scratchpad as
`make-builds-<variant>-<version>-<build>.log`.

There is no `--dry-run` pass first — the real run performs the identical
preflight and aborts cleanly on any mismatch — and a slow build is never killed:
after the archive it waits on App Store Connect processing, which is long and
quiet.

- **Build succeeds** → its Slack reply goes out immediately, before the next
  build starts.
- **Build fails** → nothing is posted for it, the decisive log lines are kept
  for the final report, and the run continues with the next build.

### What lands in Slack

One release run = one thread in `#wallet-team`. The parent names the version and
build, and each successful build adds a reply:

```
:thread: :green_apple: iOS builds 3.8.0 (2)
Builds: internal-testnet, appstore (→ App Review)
• Sending now works while a migration is running
• Keystone firmware 3.0.1 is the new minimum for signing
```

```
_iOS TestFlight Build (internal-testnet)_ — 3.8.0 (2)

App: `release/3.8.0@54812f81`
SDK: `candidate/4.1.0@cafca07a (tag: 4.1.0-rc.1)`
```

Slack itself is the registry — there is no local state. Before the first build
the skill scans the last 48 hours of the channel for a top-level message whose
first line is exactly `:thread: :green_apple: iOS builds <version> (<build>)`,
and reuses it when it finds one. There is deliberately **no author check**, so
you can finish a run a colleague started; in that case any changelog lines you
passed are skipped (the existing parent already carries one and can't be edited)
and the final report says so. `skip-tests` is never surfaced in the thread.

The `App:` / `SDK:` pair is rendered by
`.claude/skills/make-builds/scripts/build-refs.py`, never hand-written. It names
the built commit plus any tag pointing at it, and discovers the SDK from the
Xcode project rather than a hardcoded path: a local package is read live from
the checkout the project points at (with a `(dirty)` marker when it has
uncommitted changes), a remote one comes from the `Package.resolved` pin. Since
release commits are usually tagged *after* the build, no tag on the `App:` line
is normal. If no SDK reference resolves, the line is omitted and the final
report quotes the reason.

If the Slack connector isn't available in the session, the builds still run and
every composed message comes back in the final report, ready to paste. If the
parent can't be sent after a retry, the run falls back to **flat mode**:
per-build messages are posted top-level instead of threaded.

### The final report

After the last build you get, in chat: the thread link and whether it was reused
or created; one line per build with ✅ uploaded (and its reply link) or ❌ failed
(with a one-sentence reason); the log path and decisive error lines for each
failure; and any of the caveats above that applied.

### What it doesn't cover

`bump`, `--dry-run`, and submitting a build that is already uploaded (the
`--ref`-less `--submit-review` form) are outside the skill — run
`Scripts/bump.sh` / `Scripts/release.sh` directly for those.

## Command reference

```
Scripts/release.sh --variant <v> --ref <ref> --version <X.Y.Z> --build <n> [options]
  --variant       internal | testnet | appstore | internal-testnet
  --ref           branch, tag, or commit to build (optional with --submit-review)
  --version       marketing version you intend to ship (X.Y.Z)
  --build         build number (integer)
  --dry-run       run checks, then stop before building
  --yes           skip the confirmation prompt
  --skip-tests    skip the unit-test step
  --submit-review submit to App Review after upload (appstore only)
  -h, --help

Scripts/bump.sh --version <X.Y.Z> --build <n>

Scripts/prepare-release.sh start [options] <remote> <version> [<revision>]
  --issue <N>       release tracking issue, referenced from the PR body
  --build <N>       build number to record (default: 1)
  --previous <tag>  base the release branch on this tag instead of the detected one
  --dry-run         print what would happen and change nothing
  -h, --help
```

`Scripts/bump.sh` sets the version on whatever branch you are on;
`Scripts/prepare-release.sh` does the same as one step of cutting a release.
Use `bump.sh` only outside a release cut.

## Troubleshooting (preflight messages)

| Message | Fix |
|---|---|
| `version … does not match project MARKETING_VERSION …` | During a release cycle you are probably building from `release/X.Y.Z`, which is still the *previous* release — pass `--ref candidate/X.Y.Z`. Outside a cut, run `bump` or pass the version the project is actually at. |
| `build N already exists` / `is lower than the latest build` | Pick a higher number — check that variant's app in App Store Connect / TestFlight. With `--submit-review`, you can instead drop `--ref` to submit that already-uploaded build. |
| `ref is not on origin` | `git push` the branch or commit first. |
| `Could not resolve ref …` | The branch/tag/commit isn't on `origin` or locally — push or fetch it. |
| `PartnerKeys.plist is missing or invalid` | Place a valid plist at `secant/Resources/PartnerKeys.plist` (see `Scripts/validate-partner-keys.sh`). |
| `Xcode version does not match .xcode-version` | Switch Xcode (e.g. `xcodes select`) to the pinned version, or update `.xcode-version`. |
| `no distribution signing identity` | Ensure your Apple Distribution certificate is in the keychain — the same setup that lets you Archive manually. |
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

The `Scripts/test/*.bats` files are the same thing for the shell side:
`release_args.bats` and `prepare_release_args.bats` cover argument parsing,
`prepare_release_start.bats` covers the start flow against sandbox repositories,
`release_lib.bats` covers the text transforms and predicates in
`Scripts/lib/release-lib.sh` — version ordering, the CHANGELOG promotion, remote
URL parsing — and `merged_back.bats` covers the Release Merged Back check
against fixture repositories. None of them need a network, a git remote, or a
GitHub token.

These tests are **not run automatically** today — there is no CI hook for them yet
(a possible future addition). Run them by hand:

```bash
bundle exec rake test    # Ruby preflight logic (minitest)
bats Scripts/test/       # shell scripts and the release library (needs bats-core)
```
