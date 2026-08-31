---
name: make-builds
description: Create one or more iOS TestFlight builds with Scripts/release.sh and announce each successful build in a per-release Slack thread in #wallet-team. Manual only — invoke with /make-builds followed by "<ref> <version> <build>" on the first line, then one "<variant> [skip-tests] [submit-review]" line per build (submit-review is appstore-only), optionally followed by "- <changelog>" lines rendered in the thread parent.
disable-model-invocation: true
argument-hint: <ref> <version> <build> on the first line — then one "<variant> [skip-tests] [submit-review]" line per build; optional trailing "- changelog" lines
---

# Make builds

Run one or more TestFlight builds through `Scripts/release.sh`, strictly one at
a time, and announce each success in the run's Slack thread in `#wallet-team`
the moment it happens. One release run = one thread: the parent message names
the version and build, the replies carry the individual builds. The invocation
is the authorization for the whole run: never ask for confirmation before a
build, before a Slack post, or before continuing after a failure. The only
reasons to stop are a validation error (before anything has run) or the last
build being done.

Run every command from the repo root — the directory holding
`Scripts/release.sh` and `Gemfile`, i.e. the repository this skill file lives
in. If the session's working directory is elsewhere, prefix each command with
`cd <repo-root> && `.

## The input

ARGUMENTS: $ARGUMENTS

The first non-blank line is the **header**; classify every other line:

- **Header line** — `<ref> <version> <build>`, shared by every build of the
  run:
  - `ref` — branch, tag, or commit to build; must exist on origin, but the
    lane's own preflight verifies that — do not pre-verify it yourself
  - `version` — `X.Y.Z`, digits and dots only
  - `build` — an integer
- **Build line** — its first whitespace-separated token is a variant. Format:
  `<variant> [skip-tests] [submit-review]`
  - `variant` — one of `internal`, `testnet`, `appstore`, `internal-testnet`
  - options in any order, each at most once: `skip-tests` (any variant),
    `submit-review` (`appstore` only — after the upload, the lane also
    submits the build to App Review)
- **Changelog line** — starts with `-`, `*`, or `•`. Optional. Rendered only
  in the thread parent, never in the per-build replies.
- **Blank line** — ignored.

Validate everything before running anything. Errors, each named with the
offending line and what was expected instead:

- header missing or not exactly `<ref> <X.Y.Z> <integer>` — a first line
  starting with a variant name means the retired per-line format
  (`<variant> <ref> <version> <build>`); say so
- a build line with extra, missing, or malformed tokens (old-format lines
  carried ref/version/build per line — say so), an option token other than
  `skip-tests` / `submit-review`, a duplicated option token, or
  `submit-review` on a non-`appstore` line
- the same variant twice; `internal-testnet` together with `internal` or
  `testnet` also counts as a duplicate (it contains them)
- zero build lines, or a line that is none of the above

Any error → print them all and stop without launching any build. Never run a
partial batch and never guess a missing value: one build costs 30–90 minutes
and uploads to TestFlight.

## Workflow

### 1. Slack availability — once, before the first build

The run uses the Slack connector's `slack_send_message` and
`slack_read_channel` tools (if deferred, load both with ToolSearch, e.g.
query `slack send message read channel`). If the connector is not available
in this session, skip thread resolution, still run all the builds, and put
every composed message — the parent included, if one would have been created
— into the final report instead of sending it.

Channel: `#wallet-team` = `C0B4F0CUWMC`. Re-resolve by name with
`slack_search_channels` only if a call fails with `channel_not_found`.

### 2. Thread resolution — once, before the first build

One thread per version+build; Slack itself is the registry, there is no local
state. The thread key is the parent's entire first line, exactly:

```
:thread: :green_apple: iOS builds <version> (<build>)
```

1. Read recent history: `slack_read_channel` on `C0B4F0CUWMC` with `oldest` =
   now − 48h (`$(($(date +%s) - 172800))`), `limit` 100, following the
   pagination cursor while results stay inside the window.
2. A top-level message matches when its first line equals the key. Reads
   return emoji as the literal `:thread:` / `:green_apple:` codes, so compare
   the literal string. Deliberately **no author check** — a thread started by
   a colleague's run is a valid match, so one person can finish a run another
   person started. More than one match (should not happen) → use the newest
   and note it in the final report.
3. **Match found** → its ts is the run's `thread_ts`. Do not post the
   changelog anywhere this run — the existing parent already carries one and
   cannot be edited; if the invocation included changelog lines, note in the
   final report that they were skipped.
4. **No match** → send the parent to `C0B4F0CUWMC` now:

   ```
   :thread: :green_apple: iOS builds <version> (<build>)
   Builds: <variants in run order, comma-separated>
   • <changelog line>
   • <changelog line>
   ```

   - In the `Builds:` list, append ` (→ App Review)` to `appstore` when its
     build line has `submit-review`. Do not surface `skip-tests`.
   - Changelog bullets always use `•`, whichever of `-`/`*`/`•` the user
     typed; no changelog given → omit the bullet lines.
   - The run's `thread_ts` is `message_context.message_ts` from the send
     result (fallback: in the returned link, `p1786957298678079` →
     `1786957298.678079` — insert a dot before the last 6 digits).
   - Send fails → retry once; still failing → **flat mode**: run everything
     as usual but post the per-build messages top-level without `thread_ts`,
     and say so in the final report.

### 3. Builds — sequential, in the order given

For each build line, with `<ref>`, `<version>`, `<build>` taken from the
header:

1. Launch the build in the **background** (`run_in_background`, no `sleep`
   polling — wait for its completion notification). A foreground call is
   killed at 10 minutes; a build takes 30–90+. Log to the session scratchpad:
   ```bash
   ./Scripts/release.sh --variant <variant> --ref <ref> --version <version> --build <build> [--skip-tests] [--submit-review] -y > <scratchpad>/make-builds-<variant>-<version>-<build>.log 2>&1
   ```
   Always append `-y` — it skips the lane's confirmation prompt, which would
   otherwise hang forever on a non-tty. Add `--skip-tests` only when the build
   line says `skip-tests`, and `--submit-review` only when it says
   `submit-review`. Add nothing else.
2. Wait for the process to exit before doing anything further. Do not kill it
   for being slow — after the archive it waits for App Store Connect
   processing, which is long and quiet. Do not start the next build and do not
   run other commands in this repo while it runs.
3. **Exit 0** → the build is on TestFlight. Send its Slack reply now, before
   the next build starts. Take `<sha8>` from the log's final
   `Done: … from <ref> @ <sha8>` line (fallbacks:
   `git rev-parse --short=8 origin/<ref>`, then the literal `<ref>`), then
   render the reply's two ref lines:
   ```bash
   python3 .claude/skills/make-builds/scripts/build-refs.py --ref <ref> --sha <sha8>
   ```
   Paste its stdout into the reply verbatim — see step 4. Anything it writes to
   stderr is a `note:` explaining why the SDK line is missing; carry that into
   the final report rather than inventing a replacement line.
4. **Non-zero exit** → keep the last ~40 log lines for the final report, post
   nothing to Slack for this build, and continue with the next build.

Never run builds in parallel — they share one git repository (fetch, worktree
add/remove), the live local-package checkout the project points at, and the
signing profile store, and same-commit refs would collide on the build worktree
path.

Never insert a `--dry-run` pass first: the real run performs the identical
preflight before building and aborts cleanly on any mismatch.

### 4. Slack reply — one per successful build line

`internal-testnet` is one build line, hence one reply. Send to `C0B4F0CUWMC`
with the run's `thread_ts` (omit it only in flat mode), no `reply_broadcast`,
exactly:

```
_iOS TestFlight Build (<variant>)_ — <version> (<build>)

<the two lines printed by build-refs.py>
```

- **Never hand-write the `App:` / `SDK:` lines** — paste what `build-refs.py`
  printed. It resolves the SDK from the Xcode project rather than from a
  hardcoded path, so it keeps working when the SDK checkout is renamed or is
  switched between a local and a remote package. Both lines carry any tag
  pointing at the built commit, which is the point of the pair: a reader can
  tell at a glance which tagged version an announcement corresponds to.
- What the script emits, so you can sanity-check it. Tag groups render as
  `(tag: X)`, or `(tags: X, Y)` when several tags point at the same commit, and
  are omitted when there are none:

  ```
  App: `<ref>@<sha8> (tag: X)`
  SDK: `<branch>@<sha8> (tag: X) (dirty)`     ← local package
  SDK: `<version-or-branch>@<sha8>`           ← remote package
  ```

  - **App** — release commits are usually tagged *after* the build, so no tag
    on this line is normal, not a failure.
  - **Local** SDK package — read live from the checkout the project points at.
    ` (dirty)` follows the tag group when that checkout has uncommitted
    changes; a detached HEAD drops the branch and shows just the sha.
  - **Remote** SDK package — taken from the `Package.resolved` pin. A pin has no
    working copy, so it is never dirty and needs no tag lookup: the pinned
    version *is* the tag, and sits in the branch slot.
  - **No `SDK:` line at all** when nothing resolves. Say why in the final
    report, quoting the script's `note:`.
- The SDK line is read after the build, while the lane's own preflight recorded
  it at the start — the log line `build uses local Swift package <path>
  (<sha8>, clean|dirty)`. If the two shas disagree the checkout moved mid-build:
  post the log's sha and flag it in the final report.
- No changelog in replies — it lives in the thread parent.
- Post for real with `slack_send_message` — not a draft, and never ask for
  approval first: posting immediately is what this skill was invoked to do.
  Keep the returned message link for the final report.

Example — a local SDK checkout sitting on a tagged commit, app not yet tagged:

```
_iOS TestFlight Build (internal)_ — 3.10.1 (1)

App: `release/3.10.1@54812f81`
SDK: `candidate/4.1.0@cafca07a (tag: 4.1.0-rc.1)`
```

### 5. Final report — after the last build

Report in chat:

- The thread: its link, and whether it was found (reused) or created.
- One line per build, in order: variant `version (build)` — ✅ uploaded (with
  the Slack reply link) or ❌ failed (one-sentence reason).
- For each failure: the log file path and the decisive error lines.
- If a reply went out without an `SDK:` line, or its sha disagreed with the
  log's preflight: say so, quoting the `note:` `build-refs.py` printed.
- If changelog lines were skipped because the thread already existed: say so.
- If the Slack connector was unavailable or a send failed: say so explicitly
  and include each unsent message verbatim, ready to paste.

## Rules

| Situation | Do |
|---|---|
| Any input line invalid | Stop before the first build; name the line and what was expected |
| A build fails | Record it, skip its Slack reply, continue with the next build |
| Slack connector missing | Build anyway; unsent messages + a note go in the final report |
| Parent unsendable after one retry | Flat mode: per-build messages go top-level; note it in the final report |
| A reply send errors | Retry once; if it still fails, put the message in the final report |
| Thread found and the invocation has changelog lines | Don't post them; note it in the final report |
| A build seems slow or stuck | Leave it alone; only its exit ends the wait |
| `build-refs.py` prints no `SDK:` line | Post the reply without it; quote its `note:` in the final report — never hand-write a replacement |
| Tempted to ask "proceed?" / "post this?" mid-run | Don't — the invocation already authorized the run |
