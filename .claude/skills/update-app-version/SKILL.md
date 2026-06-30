---
name: update-app-version
description: Set the app's marketing version and build number in the Xcode project. Updates MARKETING_VERSION and CURRENT_PROJECT_VERSION for every non-test target (all build configurations) in secant.xcodeproj, leaving test targets untouched, as a minimal pbxproj diff. Manual only — invoke with /update-app-version <marketing> <build>, e.g. /update-app-version 3.8.0 5.
disable-model-invocation: true
argument-hint: <marketing-version e.g. 3.8.0> <build-number e.g. 5>
---

# Update app version

Set the **marketing version** (`MARKETING_VERSION`, e.g. `3.8.0`) and **build
number** (`CURRENT_PROJECT_VERSION`, e.g. `5`) for every **non-test** target in
`secant.xcodeproj`, across all of each target's build configurations.

A bundled script (`scripts/set_version.py`) does the mechanical, error-prone
part — it reads the project's object graph to find which build configurations
belong to non-test targets, then rewrites only their version lines. The result
is always a minimal, review-friendly diff (every other byte of the pbxproj is
left exactly as it was) and is validated before it lands.

This skill is manual only. Run it when a release is being cut.

## The input

The two values arrive as the command arguments (substituted below) or in the
user's message:

ARGUMENTS: $ARGUMENTS

- **First argument** = marketing version — one to three dot-separated integers
  (`3`, `3.8`, `3.8.0`).
- **Second argument** = build number — a plain integer (`5`).

If either value is missing or malformed, ask the user — do not guess.

## Workflow

### 1. Preview — dry-run first

```bash
python3 .claude/skills/update-app-version/scripts/set_version.py \
  set --marketing <marketing> --build <build> --dry-run
```

This prints which non-test targets and how many configurations would change, and
the old → new values — **without writing**. If it exits non-zero, stop and
report; change nothing:

- **Exit 2** — malformed input or a project-structure problem.
- **Exit 4** — a non-test configuration is missing one of the version keys. The
  script lists which one. This is an anomaly to look at (add the key in Xcode
  first), not something to work around.

A soft warning (printed, but still exit 0) appears if the new build number is
not greater than the current one — double-check it's intended, then continue.

### 2. Apply

Once the dry-run looks right:

```bash
python3 .claude/skills/update-app-version/scripts/set_version.py \
  set --marketing <marketing> --build <build>
```

The edit is atomic: either every targeted configuration is updated or nothing
is written, and the new pbxproj is `plutil`-linted before it replaces the
original.

### 3. Verify

```bash
python3 .claude/skills/update-app-version/scripts/set_version.py show
git diff --stat -- secant.xcodeproj/project.pbxproj
git diff -- secant.xcodeproj/project.pbxproj
```

Confirm `show` reports the new marketing version and build number for **every**
non-test target, and that the diff touches **only** `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` value lines — nothing else moved.

### 4. Report

Summarize: the marketing version, the build number, and the targets updated.
Show the diff so the user can confirm only version lines changed. This skill
edits the project file only — committing, tagging, and building are left to the
user or the release process.

## What changes (and what doesn't)

- **`MARKETING_VERSION`** and **`CURRENT_PROJECT_VERSION`** are set for every
  non-test application target — currently `zodl-testnet`, `zodl-production`, and
  `zodl-internal` — across all three configurations (`Debug`,
  `Release-Testflight`, `Release-AppStore`).
- **Test targets** (`zodlTests`) and **project-level** build settings are never
  touched.
- **Info.plist files are not edited.** They already reference
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so they pick up the new
  values automatically.

## Invariants (why the script exists)

- **Non-test targets only**, selected from the project graph (via `plutil`),
  never by matching target names — so it stays correct as targets are added or
  renamed.
- **Minimal diff.** Only the version value lines change; the script does a
  targeted textual replacement and leaves every other line byte-for-byte
  unchanged.
- **Atomic and validated.** All-or-nothing; the edited pbxproj is `plutil
  -lint`-checked before replacing the original, so a corrupt project file can
  never land. Aborts (exit 4) **without writing** if a non-test configuration is
  missing a version key.
- Don't hand-edit the pbxproj for this — let the script do it so every release
  is consistent.

## The helper script

`scripts/set_version.py` (Python 3, standard library + `plutil`):

- `set --marketing X --build N [--dry-run] [--project P]` — set both versions
  for every non-test target. Validates the marketing version (1–3 dot-separated
  integers) and build number (integer). Exits **4**, writing nothing, if a
  non-test configuration lacks a version key.
- `show [--project P]` — print the current `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` for every non-test target configuration.

`--project` defaults to `secant` (resolves to `secant.xcodeproj/project.pbxproj`);
it also accepts a path to a `.xcodeproj` or directly to a `project.pbxproj`.
