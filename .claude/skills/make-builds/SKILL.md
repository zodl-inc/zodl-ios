---
name: make-builds
description: Create one or more iOS TestFlight builds with Scripts/release.sh and announce each successful build in the #wallet-team Slack channel. Manual only — invoke with /make-builds followed by one "<variant> <ref> <version> <build> [skip-tests] [submit-review]" line per build (submit-review is appstore-only), optionally followed by "- <changelog>" lines shared by all of the run's Slack messages.
disable-model-invocation: true
argument-hint: <variant> <ref> <version> <build> [skip-tests] [submit-review] — one line per build; optional trailing "- changelog" lines
---

# Make builds

Run one or more TestFlight builds through `Scripts/release.sh`, strictly one at
a time, and post an announcement to the `#wallet-team` Slack channel the moment
each build succeeds. The invocation is the authorization for the whole run:
never ask for confirmation before a build, before a Slack post, or before
continuing after a failure. The only reasons to stop are a validation error
(before anything has run) or the last build being done.

Run every command from the repo root — the directory holding
`Scripts/release.sh` and `Gemfile`, i.e. the repository this skill file lives
in. If the session's working directory is elsewhere, prefix each command with
`cd <repo-root> && `.

## The input

ARGUMENTS: $ARGUMENTS

Split the arguments into lines and classify each:

- **Build line** — its first whitespace-separated token is a variant. Format:
  `<variant> <ref> <version> <build> [skip-tests] [submit-review]`
  - `variant` — one of `internal`, `testnet`, `appstore`, `internal-testnet`
  - `ref` — branch, tag, or commit to build; must exist on origin, but the
    lane's own preflight verifies that — do not pre-verify it yourself
  - `version` — `X.Y.Z`, digits and dots only
  - `build` — an integer
  - after `build`: zero or more option tokens, in any order, each at most once:
    - `skip-tests` — valid on every variant
    - `submit-review` — valid on `appstore` lines only (after the upload, the
      lane also submits the build to App Review); on any other variant it is
      a validation error
- **Changelog line** — starts with `-`, `*`, or `•`. Optional. The same
  changelog goes into every Slack message of the run.
- **Blank line** — ignored.

Validate everything before running anything. Any line that is none of the
above, a build line with missing, extra, or malformed tokens, an option token
other than `skip-tests` / `submit-review`, a duplicated option token,
`submit-review` on a non-`appstore` line, or an input with zero build lines →
print one error naming each offending line and what was expected instead, and
stop without launching any build. Never run a partial batch and never guess a missing value: one build
costs 30–90 minutes and uploads to TestFlight.

## Workflow

### 1. Slack availability — once, before the first build

Announcements use the Slack connector's `slack_send_message` tool (if it is
deferred, load it with ToolSearch, e.g. query `slack send message`). If the
connector is not available in this session, still run all the builds — note the
absence and put every composed message into the final report instead of
sending it.

Channel: `#wallet-team` = `C0B4F0CUWMC`. Re-resolve by name with
`slack_search_channels` only if a send fails with `channel_not_found`.

### 2. Builds — sequential, in the order given

For each build line:

1. Capture the SDK state now (the project consumes the sibling checkout live,
   so read it at launch time, per build):
   ```bash
   git -C ../zcash-swift-wallet-sdk rev-parse --abbrev-ref HEAD
   git -C ../zcash-swift-wallet-sdk rev-parse --short=8 HEAD
   git -C ../zcash-swift-wallet-sdk status --porcelain
   ```
2. Launch the build in the **background** (`run_in_background`, no `sleep`
   polling — wait for its completion notification). A foreground call is
   killed at 10 minutes; a build takes 30–90+. Log to the session scratchpad:
   ```bash
   ./Scripts/release.sh --variant <variant> --ref <ref> --version <version> --build <build> [--skip-tests] [--submit-review] -y > <scratchpad>/make-builds-<variant>-<version>-<build>.log 2>&1
   ```
   Always append `-y` — it skips the lane's confirmation prompt, which would
   otherwise hang forever on a non-tty. Add `--skip-tests` only when the build
   line says `skip-tests`, and `--submit-review` only when it says
   `submit-review`. Add nothing else.
3. Wait for the process to exit before doing anything further. Do not kill it
   for being slow — after the archive it waits for App Store Connect
   processing, which is long and quiet. Do not start the next build and do not
   run other commands in this repo while it runs.
4. **Exit 0** → the build is on TestFlight. Send its Slack message now, before
   the next build starts. Take `<sha8>` from the log's final
   `Done: … from <ref> @ <sha8>` line (fallbacks:
   `git rev-parse --short=8 origin/<ref>`, then the literal `<ref>`).
5. **Non-zero exit** → keep the last ~40 log lines for the final report, post
   nothing to Slack for this build, and continue with the next build.

Never run builds in parallel — they share one git repository (fetch, worktree
add/remove), the live `../zcash-swift-wallet-sdk` checkout, and the signing
profile store, and same-commit refs would collide on the build worktree path.

Never insert a `--dry-run` pass first: the real run performs the identical
preflight before building and aborts cleanly on any mismatch.

### 3. Slack message — one per successful build line

`internal-testnet` is one build line, hence one message. Send exactly:

```
_iOS TestFlight Build (<variant>)_ — <version> (<build>)

App: `<ref>@<sha8>`
SDK: `<sdk-branch>@<sdk-sha8>`

• <changelog line>
• <changelog line>
```

- The SDK line uses the values captured at launch: append ` (dirty)` inside
  the backticks when `status --porcelain` was non-empty; on a detached HEAD use
  just the sha; drop the whole SDK line when the checkout does not exist.
- Changelog bullets always use `•`, whichever of `-`/`*`/`•` the user typed.
  When no changelog was given, omit the bullet block and its preceding blank
  line.
- Post for real with `slack_send_message` — not a draft, and never ask for
  approval first: posting immediately is what this skill was invoked to do.
  Keep the returned message link for the final report.

Example:

```
_iOS TestFlight Build (internal)_ — 3.9.0 (6)

App: `migration/rebuild@a7522c01`
SDK: `michal/librustzcash-batch-prove-outlook-rewire@0b5e678c`

• Migration stuck fixed
• Balance fixed
```

### 4. Final report — after the last build

Report in chat:

- One line per build, in order: variant `version (build)` — ✅ uploaded (with
  the Slack message link) or ❌ failed (one-sentence reason).
- For each failure: the log file path and the decisive error lines.
- If the Slack connector was unavailable or a send failed: say so explicitly
  and include each unsent message verbatim, ready to paste.

## Rules

| Situation | Do |
|---|---|
| Any input line invalid | Stop before the first build; name the line and what was expected |
| A build fails | Record it, skip its Slack post, continue with the next build |
| Slack connector missing | Build anyway; unsent messages + a note go in the final report |
| A Slack send errors | Retry once; if it still fails, put the message in the final report |
| A build seems slow or stuck | Leave it alone; only its exit ends the wait |
| Tempted to ask "proceed?" / "post this?" mid-run | Don't — the invocation already authorized the run |
