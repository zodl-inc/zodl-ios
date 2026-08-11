# CHP_PLAN — Coinholder Polling re-enable: implementation plan

> **For agentic workers:** execute this plan task-by-task under the delegation protocol in
> `CHP_DESIGN.md` §8 — one task per fresh delegate (Sonnet default; **Opus for T2 and T3**),
> the orchestrator reviews each diff against the task's acceptance criteria and authors no
> code. A human engineer may instead execute tasks inline in order. Steps use checkbox
> (`- [ ]`) syntax for tracking. Every task is executable with zero context beyond this file
> + `CHP_DESIGN.md` + `CHP.md` (all three sit in this directory).

**Goal:** Coinholder Polling working again in Zodl iOS on the Ironwood chain, driven by
`zcash_voting = 2.0.0-rc.5`, with the existing UI untouched.

**Architecture:** three frozen-boundary layers — Valar's crate owns all voting semantics;
SDK FFI + Swift wrapper are semantics-free marshalling; the app keeps its screens/flows and
rewires only the call sites the 2.0 library collapsed. Net deletion (~SDK +215/−360, app
+95/−160).

**Tech stack:** Rust (SDK `rust/` → `libzcashlc` XCFramework via `Scripts/init-local-ffi.sh`),
Swift (SDK wrapper + TCA app), SPM local sibling path dependency.

**Authorship & provenance (campaign rule):** the orchestrator (Fable) authored this plan's
structure, prose, and shell commands. **Every compilable code block (Swift/Rust/toml/pbxproj
content) was authored by a delegated model**, named in the *Code blocks by:* line under each
task heading, and spliced verbatim. The same rule governs execution: delegates write all code.

**Companion files:** in-task references to `## CORRECTIONS`, `## PROBE EVIDENCE`,
`## INTERFACES-FOR-APP`, and `## VERIFICATION EVIDENCE` resolve to the authoring lane's
verbatim deliverable in `docs/chp-plan/` — `plan-sdk-lane.md` for Tasks 1–4 (its
`## INTERFACES-FOR-APP` also carries Task 4B's addendum), `plan-app-lane.md` for Tasks 7–14,
and `plan-f1-amendment.md` for Task 4B + step 8.14 (its `## EVIDENCE` block is that lane's
provenance). Read the referenced item there before executing the step that cites it.

## Workspace (verified 2026-08-11)

| Path | What | Rules |
|---|---|---|
| `~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios` | zodl worktree, branch `chp-re-enable` (this file's home) | commits `[MOB-1678] <title>`; pushes to `origin` only at T14/T16 |
| `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk` | SDK worktree, branch `chp-re-enable` @ `f74f13b8` (re-based on main `ee7b05c9`, 2026-08-11; tree byte-identical to it) | commits `[#1855] <title>`; **NEVER push** (remote is push-guarded; Lukas pushes by hand — T16 hands him the command) |
| `~/Dev/Xcode/GitHub/LukasKorba/_migration/*` | Michal's gardening lanes | **do not touch, do not switch branches** |

The pair is deliberate: the app's SPM dependency is the literal sibling path
`../zcash-swift-wallet-sdk` (`project.pbxproj` `relativePath`), so building the app in
`_chp/zodl-ios` automatically consumes the CHP SDK. The SDK worktree starts in **binary FFI
mode** (no `LocalPackages/`); T5 switches it to local FFI mode. All commit trailers:
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Global constraints (from CHP_DESIGN.md §0 — every task inherits these)

1. **UI frozen.** No screen/string/flow/view changes; no new `Localizable.xcstrings` keys. A
   task that seems to need one → STOP, report a finding.
2. **Adapters semantics-free.** No phase tracking, workflow state, or wire mirrors anywhere in
   FFI/wrapper/app clients.
3. **Pin exactly** `zcash_voting = "=2.0.0-rc.5"` (the `=` matters).
4. **Honest gates.** Every build/test command redirects full output to a log file and reports
   the real exit code. When piping through `tee`, the idiom is `set -o pipefail; <cmd> 2>&1 |
   tee <log> | tail -N; echo "REAL_EXIT=$?"` — never `${PIPESTATUS[0]}`, which is bash-only
   and silently expands to empty under this environment's zsh. Never judge by grep.
5. **Secrets never** in code, logs, commits, or reports. The hotkey stored secret is key
   material.
6. **Commit per task** with the exact message given in the task; conventions per the
   workspace table above.
7. **Provenance tags** in reports: [LIB] / [BUG] / [CEO] / [PENDING] per `CHP_DESIGN.md` §0.7.
8. **Red ladder is by design:** T7 flips the flag and the app goes red; T8–T13 burn the
   compiler's error list monotonically to zero; T14 restores green. A red build between T7 and
   T14 is not a failure — a *non-decreasing* error count is.
9. **Report format per task** (`CHP_DESIGN.md` §8.4): files+lines changed, gate log tails +
   real exit codes, deviations surfaced (never absorbed).
10. **When the world moves** (crate rc.6, SDK `origin/main` advances, Android PRs re-target):
    STOP, re-check `CHP.md` §5.5 pin rule + §11.1 merge policy, log the move in `CHP.md` §10.

## Task ladder

Order is load-bearing: **T0 → T1–T4 + T4B (SDK wave; 4B = the F1 signing passthrough, added
2026-08-11 after the recon resolved the software-signing gap) → T5–T6 (rebuild + SDK gates) →
T7 (enumeration) → T8–T13 (burn the list) → T14–T15 (green gates) → T16 (wrap-up)**.

The `S1–S6` / `A1–A7` codes in task headings are the spec's change items, defined in
`CHP_DESIGN.md` §3 (S = SDK workstream, A = app workstream). Every task assumes all
lower-numbered tasks have already landed in the worktrees; when starting mid-ladder, first run
`git log --oneline -6` in the worktree the task targets and confirm the preceding tasks'
commits (by their exact messages, listed in each task's final step) are present.

---

### Task 0: Pre-flight — world check + workspace verification

*No code blocks (commands only) — orchestrator-authored.*

**Files:** none modified.

- [ ] **Step 0.1: Crate world check.** Run:

```bash
curl -s -A "chp-preflight" "https://crates.io/api/v1/crates/zcash_voting" | python3 -c "import json,sys; print('max_version:', json.load(sys.stdin)['crate']['max_version'])"
```

Expected: `max_version: 2.0.0-rc.5`. **If anything newer appears → STOP** and re-run the pin
rule (`CHP.md` §5.5: newest *published* rc whose CHANGELOG-stated runtime preconditions
deployed infra meets) before proceeding; update this plan's pin references if the answer
changes.

- [ ] **Step 0.2: SDK base check.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git fetch origin main --quiet; git log --oneline -1 origin/main && git log --oneline -1
```

Expected: `origin/main` = `ee7b05c9 …`, HEAD = `f74f13b8 [#1855] Merge origin/main: mains
absorbed the gardening stack…` (the 2026-08-11 re-base; that merge's tree is byte-identical
to this main). **If origin/main moved again → STOP** and re-merge before T1, taking main's
side everywhere; if a conflict falls outside `Cargo.toml`/`Cargo.lock`, re-derive the policy
from `CHP.md` §11.1 and log it. Beware `git rerere`: this repo's cache once silently
re-applied a stale `Cargo.toml` resolution — inspect resolved conflict content, never trust
it blind (CHP.md §10, 2026-08-11 (4)).

- [ ] **Step 0.3: Workspace asserts.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git branch --show-current && git status --short | head -3 && grep -o 'relativePath = "../zcash-swift-wallet-sdk"' secant.xcodeproj/project.pbxproj | head -1
```

Expected: `chp-re-enable`, clean status (docs-only changes acceptable), and the
`relativePath` line printed. Any other branch → STOP.

- [ ] **Step 0.4: Rust baseline gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo check 2>&1 | tee /tmp/chp-t0-cargo.log | tail -3; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0` (proven at the merge; first run in this worktree compiles from
scratch — minutes, not seconds). Non-zero → STOP, report the log tail. One warning is
expected and known: `Patch 'slipstream-core v0.6.4 (…slipstream-internal…)' was not used in
the crate graph` — main's patch key doesn't match the renamed `zodl-slipstream` package, so
the pin is inert and the engine resolves from crates.io (surfaced to Michal; not ours to
fix). If local builds rewrite `Cargo.lock` with a `[[patch.unused]]` stanza, that is
cargo-canonical — include it in the next task's commit rather than reverting it repeatedly.

- [ ] **Step 0.5: Android PR context (informational, no STOP).** Run:

```bash
gh pr view 2157 --repo zcash/zcash-android-wallet-sdk --json state,mergedAt,title 2>/dev/null; gh pr view 2406 --repo zodl-inc/zodl-android --json state,title 2>/dev/null || echo "PR lookup unavailable — proceed; recipes are quoted inline in T1"
```

Record whatever prints in the T0 report.

---

### Task 1: S2 — pin `zcash_voting = "=2.0.0-rc.5"` + thread `PirLayout`

*Code blocks by: Opus (SDK delegate). Rust is probe-proven (`cargo check` + `cargo fmt --check` +
`cargo test --lib voting` all green at `a3823651` + these edits); Swift is written-from-reading and
compiles at plan Task 6.*

**Files:**
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Cargo.toml:105`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Cargo.lock` (by `cargo update`)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/delegation.rs:419` (+ `:437`, `:461`, `:498`, `:542`, and the `mod tests` call sites at `:1203` and `:1505`)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`
- Test: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/delegation.rs` (`mod tests`, in-file)

**Interfaces:**
- Consumes: `zcash_voting 2.0.0-rc.5` — `voting::config::PirLayout { pir_depth, tier0_layers, tier1_layers }` and `voting::connect_pir_blocking(PirLayout, &str, Arc<dyn Transport>) -> Result<PirClientBlocking, VotingError>`.
- Produces: FFI `zcashlc_voting_precompute_delegation_pir` and `zcashlc_voting_build_and_prove_delegation` each gain three trailing/positional `u32` layout parameters; Swift gains `VotingPirLayout` and a defaulted `pirLayout:` on both async wrappers (see `## INTERFACES-FOR-APP`).

---

- [ ] **Step 1.1: Pin the crate exactly.** Edit `Cargo.toml` line 105. Replace this line:

```toml
zcash_voting = { version = "2.0.0-rc.3" }
```

with:

```toml
zcash_voting = { version = "=2.0.0-rc.5" }
```

The `=` is load-bearing: without it cargo resolves `1.0.0`, because a bare `2.0.0-rc.5` requirement
does not match pre-release versions the way a caret requirement matches releases.

- [ ] **Step 1.2: Update the lock for that one package only.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo update -p zcash_voting 2>&1 | tail -10
```

Expected — exactly these six lines (order may vary):

```
    Updating imt-tree v0.2.0 -> v0.2.1
    Updating pir-client v0.4.0-rc.2 -> v0.4.0-rc.4
    Updating pir-types v0.3.0-rc.2 -> v0.3.0-rc.4
    Updating vote-commitment-tree v0.4.0-rc.1 -> v0.4.0-rc.2
    Updating vote-commitment-tree-client v0.6.0-rc.1 -> v0.6.0-rc.2
    Updating zcash_voting v2.0.0-rc.3 -> v2.0.0-rc.5
```

Any line mentioning `zcash_client_backend`, `zcash_client_sqlite`, `orchard`, `pczt` or
`librustzcash` → **STOP**: the librustzcash family must not move (CHP.md §5.5). Report it.

- [ ] **Step 1.3: Route PIR connection through the crate's fail-closed handshake.** In
`rust/src/voting/delegation.rs`, replace the whole `connect_pir_client` function (lines 416–422,
the comment block through the closing brace) with this. This is the one compile error rc.5
introduces, and it is the same fix Android's PR #2157 landed.

```rust
// Keep PIR client construction at the SDK boundary so zcash_voting can accept
// an injected transport. Today we use direct Hyper/Rustls. In the future this will be the
// single place to add a Tor-backed transport based on SDK configuration.
//
// The layout comes from the round's resolved dynamic config and is passed through
// unchanged: `connect_pir_blocking` performs the config/server layout handshake and
// fails closed before any private query when the server disagrees.
fn connect_pir_client(
    pir_url: &str,
    pir_layout: voting::config::PirLayout,
) -> anyhow::Result<voting::PirClientBlocking> {
    voting::connect_pir_blocking(pir_layout, pir_url, Arc::new(voting::HyperTransport::new()))
        .map_err(|e| anyhow!("connect to PIR server failed: {}", e))
}
```

- [ ] **Step 1.4: Thread the layout into the PIR-precompute entry point.** Still in
`rust/src/voting/delegation.rs`, in `zcashlc_voting_precompute_delegation_pir`. First extend the
parameter list — replace:

```rust
    pir_server_url: *const u8,
    pir_server_url_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        crate::parse_network(handle.network_id)?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
```

with:

```rust
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    pir_depth: u32,
    tier0_layers: u32,
    tier1_layers: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        crate::parse_network(handle.network_id)?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
```

Then, in the same function, replace:

```rust
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let pir_client = connect_pir_client(&pir_url)?;

        let result = handle
            .db
            .precompute_delegation_pir(
```

with:

```rust
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let pir_layout = voting::config::PirLayout {
            pir_depth,
            tier0_layers,
            tier1_layers,
        };
        let pir_client = connect_pir_client(&pir_url, pir_layout)?;

        let result = handle
            .db
            .precompute_delegation_pir(
```

The `# Safety` doc block above the function needs no edit: the three new parameters are plain
scalars passed by value, so they add no pointer contract.

- [ ] **Step 1.5: Thread the layout into the prove entry point.** Still in
`rust/src/voting/delegation.rs`, in `zcashlc_voting_build_and_prove_delegation`. Replace:

```rust
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
```

with:

```rust
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    pir_depth: u32,
    tier0_layers: u32,
    tier1_layers: u32,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
```

Then, in the same function, replace:

```rust
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let pir_client = connect_pir_client(&pir_url)?;
```

with:

```rust
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let pir_layout = voting::config::PirLayout {
            pir_depth,
            tier0_layers,
            tier1_layers,
        };
        let pir_client = connect_pir_client(&pir_url, pir_layout)?;
```

- [ ] **Step 1.6: Fix the two Rust unit-test call sites the new arity breaks.**
`cargo check` will NOT catch these — `#[cfg(test)]` code is only compiled by `cargo test`. In
`rust/src/voting/delegation.rs`, find the start of the test module (around line 1183):

```rust
mod tests {
    use super::*;
```

and replace it with:

```rust
mod tests {
    use super::*;

    /// The PIR geometry the live dynamic voting config serves today. These
    /// tests never reach the PIR handshake — they assert null-handle and
    /// input-validation rejections — so the values only need to be a
    /// well-formed layout rather than the sentinel `PirLayout::UNKNOWN`.
    const PIR_DEPTH: u32 = 19;
    const TIER0_LAYERS: u32 = 12;
    const TIER1_LAYERS: u32 = 7;
```

Then, in the same test module, replace this call (around line 1203):

```rust
                    0,
                    round.as_ptr(),
                    round.len(),
                    round.as_ptr(),
                    round.len(),
                    None,
                    std::ptr::null_mut(),
                )
```

with:

```rust
                    0,
                    round.as_ptr(),
                    round.len(),
                    round.as_ptr(),
                    round.len(),
                    PIR_DEPTH,
                    TIER0_LAYERS,
                    TIER1_LAYERS,
                    None,
                    std::ptr::null_mut(),
                )
```

and replace this call (around line 1505):

```rust
            zcashlc_voting_precompute_delegation_pir(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
            )
```

with:

```rust
            zcashlc_voting_precompute_delegation_pir(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                PIR_DEPTH,
                TIER0_LAYERS,
                TIER1_LAYERS,
            )
```

- [ ] **Step 1.7: Rust format gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0` and no output before it.

- [ ] **Step 1.8: Rust compile gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo check 2>&1 | tee /tmp/chp-t1-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`. The tail ends with `Finished \`dev\` profile …`. One pre-existing warning
(`rust/src/migration_plan_cache.rs:77:9: field \`immediate\` is never read`) is expected and is not
from this task. Any `error[E…]` → report the log tail; do not proceed.

- [ ] **Step 1.9: Rust test gate (catches what `cargo check` cannot).** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t1-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0` and a line reading `test result: ok. 72 passed; 0 failed; 0 ignored;
0 measured; 162 filtered out`. A count other than 72 passed / 0 failed → report it.

- [ ] **Step 1.10: Lock assertions (spec S2 acceptance).** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -A1 '^name = "zcash_voting"$\|^name = "pir-client"$\|^name = "pir-types"$' Cargo.lock | grep -v '^--'
```

Expected, exactly:

```
name = "pir-client"
version = "0.4.0-rc.4"
name = "pir-types"
version = "0.3.0-rc.4"
name = "zcash_voting"
version = "2.0.0-rc.5"
```

Then run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -o 'librustzcash?rev=[0-9a-f]*' Cargo.lock | sort -u
```

Expected, exactly one line:

```
librustzcash?rev=13ce6c4ef57a6c7e8837d797d85112ae16ac7455
```

Two or more revs → **STOP**, the graph split into two librustzcash generations (CHP.md §7.2/V2).

- [ ] **Step 1.11: Add the Swift layout type.** Append to the end of
`Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift` (after the closing brace of
`VotingStoredCommitmentBundle`, currently line 568):

```swift

// MARK: - PIR layout

/// PIR tree geometry advertised by the round's resolved dynamic voting config.
///
/// Mirrors `zcash_voting::config::PirLayout` field for field. `zcash_voting`
/// runs the config/server layout handshake with these values and fails closed
/// before issuing any private query when the server disagrees, so they must come
/// from a resolved dynamic config rather than being assumed or compiled in.
public struct VotingPirLayout: Equatable, Sendable {
    public let pirDepth: UInt32
    public let tier0Layers: UInt32
    public let tier1Layers: UInt32

    /// The crate's `PirLayout::UNKNOWN` sentinel, and its `Default`.
    ///
    /// `zcash_voting` rejects it — "pir_layout is unknown; resolve a current
    /// dynamic voting config first" — so this is a fail-closed placeholder for
    /// callers that have not resolved a config yet, never a usable layout.
    public static let unknown = VotingPirLayout(
        pirDepth: 0,
        tier0Layers: 0,
        tier1Layers: 0
    )

    public init(pirDepth: UInt32, tier0Layers: UInt32, tier1Layers: UInt32) {
        self.pirDepth = pirDepth
        self.tier0Layers = tier0Layers
        self.tier1Layers = tier1Layers
    }
}
```

- [ ] **Step 1.12: Thread the layout through `precomputeDelegationPir`.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`, replace the parameter list and
FFI call of `precomputeDelegationPir` (lines 138–174). Replace:

```swift
    public func precomputeDelegationPir(
        roundId: String,
        bundleIndex: UInt32,
        notes: [VotingNoteInfo],
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirResolver: PirSnapshotResolver = PirSnapshotResolver()
    ) async throws -> VotingDelegationPirPrecomputeResult {
```

with:

```swift
    public func precomputeDelegationPir(
        roundId: String,
        bundleIndex: UInt32,
        notes: [VotingNoteInfo],
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirLayout: VotingPirLayout = .unknown,
        pirResolver: PirSnapshotResolver = PirSnapshotResolver()
    ) async throws -> VotingDelegationPirPrecomputeResult {
```

and, in the same method, replace:

```swift
                        zcashlc_voting_precompute_delegation_pir(
                            dbh,
                            ridBuf.baseAddress,
                            UInt(ridBuf.count),
                            bundleIndex,
                            notesBuf.baseAddress,
                            UInt(notesBuf.count),
                            urlBuf.baseAddress,
                            UInt(urlBuf.count)
                        )
```

with:

```swift
                        zcashlc_voting_precompute_delegation_pir(
                            dbh,
                            ridBuf.baseAddress,
                            UInt(ridBuf.count),
                            bundleIndex,
                            notesBuf.baseAddress,
                            UInt(notesBuf.count),
                            urlBuf.baseAddress,
                            UInt(urlBuf.count),
                            pirLayout.pirDepth,
                            pirLayout.tier0Layers,
                            pirLayout.tier1Layers
                        )
```

Also extend that method's doc comment: after the line

```swift
    /// endpoint whose served snapshot height equals `expectedSnapshotHeight`
    /// exactly is used. See `PirSnapshotResolver` for the failure semantics.
```

insert:

```swift
    ///
    /// `pirLayout` must come from the round's resolved dynamic voting config.
    /// `zcash_voting` fails the config/server layout handshake closed before any
    /// private query, and rejects the `.unknown` default outright.
```

- [ ] **Step 1.13: Thread the layout through `buildAndProveDelegation`.** In the same file, replace
the parameter list of `buildAndProveDelegation` (lines 1522–1528):

```swift
    public func buildAndProveDelegation(
        _ params: VotingDelegationProofParams,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirResolver: PirSnapshotResolver = PirSnapshotResolver(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VotingDelegationProofResult {
```

with:

```swift
    public func buildAndProveDelegation(
        _ params: VotingDelegationProofParams,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirLayout: VotingPirLayout = .unknown,
        pirResolver: PirSnapshotResolver = PirSnapshotResolver(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VotingDelegationProofResult {
```

and, in the same method, replace:

```swift
        return try await Task.detached { [self] in
            try syncBuildAndProveDelegation(
                params,
                pirServerUrl: pirServerUrl,
                progress: progress
            )
        }.value
```

with:

```swift
        return try await Task.detached { [self] in
            try syncBuildAndProveDelegation(
                params,
                pirServerUrl: pirServerUrl,
                pirLayout: pirLayout,
                progress: progress
            )
        }.value
```

- [ ] **Step 1.14: Thread the layout through the detached proving body.** In the same file, in the
`private extension VotingRustBackend` block, replace the signature of `syncBuildAndProveDelegation`
(lines 1789–1793):

```swift
    func syncBuildAndProveDelegation(
        _ params: VotingDelegationProofParams,
        pirServerUrl: String,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> VotingDelegationProofResult {
```

with:

```swift
    func syncBuildAndProveDelegation(
        _ params: VotingDelegationProofParams,
        pirServerUrl: String,
        pirLayout: VotingPirLayout,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> VotingDelegationProofResult {
```

and, in the same function, replace:

```swift
                                        zcashlc_voting_build_and_prove_delegation(
                                            dbh,
                                            ridBuf.baseAddress,
                                            UInt(ridBuf.count),
                                            params.bundleIndex,
                                            notesBuf.baseAddress,
                                            UInt(notesBuf.count),
                                            fvkBuf.baseAddress,
                                            UInt(fvkBuf.count),
                                            secretBuf.baseAddress,
                                            UInt(secretBuf.count),
                                            fpBuf.baseAddress,
                                            UInt(fpBuf.count),
                                            keys.accountIndex,
                                            nameBuf.baseAddress,
                                            UInt(nameBuf.count),
                                            urlBuf.baseAddress,
                                            UInt(urlBuf.count),
                                            trampoline,
                                            progressContext
                                        )
```

with:

```swift
                                        zcashlc_voting_build_and_prove_delegation(
                                            dbh,
                                            ridBuf.baseAddress,
                                            UInt(ridBuf.count),
                                            params.bundleIndex,
                                            notesBuf.baseAddress,
                                            UInt(notesBuf.count),
                                            fvkBuf.baseAddress,
                                            UInt(fvkBuf.count),
                                            secretBuf.baseAddress,
                                            UInt(secretBuf.count),
                                            fpBuf.baseAddress,
                                            UInt(fpBuf.count),
                                            keys.accountIndex,
                                            nameBuf.baseAddress,
                                            UInt(nameBuf.count),
                                            urlBuf.baseAddress,
                                            UInt(urlBuf.count),
                                            pirLayout.pirDepth,
                                            pirLayout.tier0Layers,
                                            pirLayout.tier1Layers,
                                            trampoline,
                                            progressContext
                                        )
```

- [ ] **Step 1.15: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Changed`, insert this
as the first bullet of that section (immediately after the `## Changed` heading line):

```markdown
- Voting is pinned to `zcash_voting = "=2.0.0-rc.5"` (exactly; a non-`=` requirement resolves to
  1.0.0). rc.4 made the PIR layout an explicit client/server handshake, so
  `VotingRustBackend.precomputeDelegationPir(...)` and `buildAndProveDelegation(...)` take a new
  `pirLayout: VotingPirLayout` — the `pir_depth`/`tier0_layers`/`tier1_layers` triple from the
  round's resolved dynamic voting config. It defaults to `VotingPirLayout.unknown`, the crate's own
  `PirLayout::UNKNOWN` sentinel, which `zcash_voting` rejects: a caller that does not pass a
  resolved layout fails closed before any private query rather than querying with a guessed
  geometry.
```

- [ ] **Step 1.16: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add Cargo.toml Cargo.lock rust/src/voting/delegation.rs Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift CHANGELOG.md && git commit -m "[#1855] Pin zcash_voting =2.0.0-rc.5 and thread the resolved PIR layout through the delegation FFI" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: S3 — de-mirror the wire (retire the hand-written wire structs in `rust/src/voting/json.rs`)

*Code blocks by: Opus (SDK delegate). Rust is probe-proven (`cargo check` + `cargo fmt --check` +
`cargo test --lib voting` green, acceptance greps verified); Swift is written-from-reading, with
every field name and encoding transcribed from `zcash_voting`'s own `wire.rs` serde attributes.*

Read `## CORRECTIONS` item 4 before starting: `json.rs` is **not** deleted outright. Six of its
types marshal crate types that deliberately do not derive `Serialize` (one of them documents a
prohibition on it, because it holds share plaintexts). Those are FFI transport, not wire mirrors.
This task removes the four real wire mirrors and the wire tail of `JsonVoteCommit`. **Do not
hand-add `tx1_effects` or a single-share filter anywhere** — the crate's serializer supplies both.

**Files:**
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/json.rs` (359 → 223 lines)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/tree.rs:10` and `:73`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/delegation.rs:25` and the body of `zcashlc_voting_get_delegation_submission_with_signature`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift:268-379`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`, `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/MIGRATING.md`
- Test: none added — the SDK's voting offline suite must stay byte-identical (asserted at plan Task 6, step 6.3)

**Interfaces:**
- Consumes: `zcash_voting::wire::{DelegationSubmissionWire, VoteShareWire}`, `zcash_voting::types::WireEncryptedShare`, `zcash_voting::vote::VanWitness`, `zcash_voting::delegate::{submission, DelegationSigner}`, and `DelegationSubmission::to_wire_json()`.
- Produces: `getDelegationSubmission(...)` returns the crate's wire body (`tx1Effects` present, `sighash` gone); `VotingVoteCommit` loses `sharePayloads`; `VotingSharePayload` is deleted; `VotingWireEncryptedShare` becomes base64 strings. See `## INTERFACES-FOR-APP`.

---

- [ ] **Step 2.1: Delete the three wire mirrors and reshape the commit result.** In
`rust/src/voting/json.rs`, delete everything from the line

```rust
/// JSON-serializable DelegationSubmission.
```

down to (but not including) the line

```rust
/// JSON-serializable DelegationInputs.
```

and put this in its place. This removes `JsonDelegationSubmission`, `JsonWireEncryptedShare` and
`JsonSharePayload` outright, and replaces `JsonVoteCommit` with a version that carries the crate's
own `WireEncryptedShare` and no helper payloads at all:

```rust
/// JSON-serializable `voting::vote::VoteCommit`.
///
/// The helper-share payloads are deliberately absent: they are wire data owned
/// by `zcash_voting`, produced by `zcashlc_voting_recover_wire_json` once the
/// confirmed vote-commitment-tree position is known. Commit-time payloads are
/// provisional and must never be sent to helper servers.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonVoteCommit {
    pub proposal_id: u32,
    pub van_nullifier: Vec<u8>,
    pub vote_authority_note_new: Vec<u8>,
    pub vote_commitment: Vec<u8>,
    pub proof: Vec<u8>,
    pub anchor_height: u32,
    pub r_vpk: Vec<u8>,
    pub vote_auth_sig: Vec<u8>,
    pub enc_shares: Vec<voting::WireEncryptedShare>,
}

impl From<voting::vote::VoteCommit> for JsonVoteCommit {
    fn from(c: voting::vote::VoteCommit) -> Self {
        Self {
            proposal_id: c.proposal_id,
            van_nullifier: c.van_nullifier.to_vec(),
            vote_authority_note_new: c.vote_authority_note_new.to_vec(),
            vote_commitment: c.vote_commitment.to_vec(),
            proof: c.proof,
            anchor_height: c.anchor_height,
            r_vpk: c.r_vpk.to_vec(),
            vote_auth_sig: c.vote_auth_sig.to_vec(),
            enc_shares: c.encrypted_shares,
        }
    }
}

```

- [ ] **Step 2.2: Delete the VAN-witness mirror.** Still in `rust/src/voting/json.rs`, delete the
final block of the file — everything from

```rust
/// JSON-serializable VanWitness.
```

to the end of the file. `voting::vote::VanWitness` already derives `Serialize`/`Deserialize` and
has identical field names (`auth_path`, `position`, `anchor_height`), so the mirror was a pure
duplicate. After this step the file ends with the closing brace of `JsonDelegationInputs` and is
**223 lines**.

- [ ] **Step 2.3: Serialize the crate's VAN witness directly.** In `rust/src/voting/tree.rs`,
delete this import line (line 10):

```rust
use super::json::JsonVanWitness;
```

and in `zcashlc_voting_generate_van_witness`, replace:

```rust
        let json_witness: JsonVanWitness = witness.into();
        json_to_boxed_slice(&json_witness)
```

with:

```rust
        json_to_boxed_slice(&witness)
```

- [ ] **Step 2.4: Drop the dead import in the delegation FFI.** In
`rust/src/voting/delegation.rs`, replace the import block at line 25:

```rust
use super::json::{
    JsonDelegationPirPrecomputeResult, JsonDelegationProofResult, JsonDelegationSubmission,
    JsonNoteInfo, JsonVotingPczt, JsonWitnessData,
};
```

with:

```rust
use super::json::{
    JsonDelegationPirPrecomputeResult, JsonDelegationProofResult, JsonNoteInfo, JsonVotingPczt,
    JsonWitnessData,
};
```

- [ ] **Step 2.5: Emit the crate's own delegation wire body.** In
`rust/src/voting/delegation.rs`, in `zcashlc_voting_get_delegation_submission_with_signature`,
replace:

```rust
        let submission = handle
            .db
            .get_delegation_submission_with_signature(
                &round_id_str,
                bundle_index,
                sig_bytes,
                sighash_bytes,
            )
            .map_err(|e| anyhow!("get_delegation_submission_with_signature failed: {}", e))?;

        let json_sub: JsonDelegationSubmission = submission.into();
        json_to_boxed_slice(&json_sub)
```

with:

```rust
        let signer =
            voting::delegate::DelegationSigner::signature_from_bytes(sig_bytes, sighash_bytes)
                .map_err(|e| anyhow!("invalid delegation signature material: {}", e))?;
        let submission =
            voting::delegate::submission(&handle.db, &round_id_str, bundle_index, signer)
                .map_err(|e| anyhow!("delegate::submission failed: {}", e))?;

        let wire_json = submission
            .to_wire_json()
            .map_err(|e| anyhow!("serialize delegation submission wire JSON failed: {}", e))?;
        Ok(crate::ffi::BoxedSlice::some(wire_json.into_bytes()))
```

`delegate::submission` calls the same DB method underneath and then hands back the crate's typed
`DelegationSubmission`; `to_wire_json()` is `DelegationSubmissionWire::try_from(&self)?.to_json()`.
That is where `tx1_effects` comes from and where the wire `sighash` stops existing — neither is
written by hand here or anywhere else. Also update the function's doc comment: replace the line

```rust
/// Returns JSON-encoded `DelegationSubmission` as `*mut FfiBoxedSlice`, or null on error.
```

with:

```rust
/// Returns `zcash_voting`'s own `wire::DelegationSubmissionWire` JSON as
/// `*mut FfiBoxedSlice`, or null on error. The crate serializes it, so the
/// field names, the base64 encoding and the Ironwood `tx1_effects` blob are
/// the crate's and are never reshaped here.
```

- [ ] **Step 2.6: Rust format + compile gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check && set -o pipefail && cargo check 2>&1 | tee /tmp/chp-t2-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, ending in `Finished \`dev\` profile …`, with only the pre-existing
`migration_plan_cache.rs:77` warning.

- [ ] **Step 2.7: Rust test gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t2-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `test result: ok. 72 passed; 0 failed`.

- [ ] **Step 2.8: Acceptance greps (spec S3).** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git grep -c 'all_enc_shares' -- rust/src/voting/; echo "ALL_ENC_SHARES_EXIT=$?"
```

Expected: **no output at all** and `ALL_ENC_SHARES_EXIT=1` — zero files match. Any hit means a
hand-mirrored helper payload survived; report it. Then run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git grep -c 'sighash' -- rust/src/voting/
```

Expected, exactly these five files and counts (every one a crate-type passthrough, not a wire
mirror — the signer's input sighash, the Keystone signature record, the PCZT sighash extractor, and
one doc line):

```
rust/src/voting/constants.rs:1
rust/src/voting/delegation.rs:5
rust/src/voting/json.rs:2
rust/src/voting/recovery.rs:21
rust/src/voting/util.rs:8
```

(`git grep -c` prints `path:matching-line-count`.) The five survivors are: one doc line in
`constants.rs`; the signer's input `sighash` parameter of
`zcashlc_voting_get_delegation_submission_with_signature` in `delegation.rs`; `JsonVotingPczt`'s
`pczt_sighash`, which is internal PCZT state and never wire data, in `json.rs`; the Keystone
signature record and its length validation and tests in `recovery.rs` — note the crate's own
`wire::KeystoneSignatureRecord` carries a `sighash` field too; and
`zcashlc_voting_extract_pczt_sighash` plus its test in `util.rs`. Every one is a crate-type
passthrough. A hit in any *other* file, or a new mirror struct, is a deviation.

Finally confirm the file shrank:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && wc -l rust/src/voting/json.rs
```

Expected: `223`.

- [ ] **Step 2.9: Retype the Swift wire structs.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift`, replace everything from

```swift
// MARK: - Delegation Submission (JSON)
```

through the closing brace of `VotingSharePayload` (i.e. up to but not including
`// MARK: - Delegation Inputs (JSON)`) with the block below. This retypes the delegation submission
to the crate's wire shape, drops `sharePayloads` from the commit result, retypes the encrypted-share
ciphertexts to base64, and deletes `VotingSharePayload` entirely:

```swift
// MARK: - Delegation Submission (JSON)

/// The chain-ready delegation submission body, in `zcash_voting`'s own wire
/// encoding.
///
/// The FFI returns `zcash_voting::wire::DelegationSubmissionWire` serialized by
/// the crate, so the field names and the base64 encoding are the crate's and the
/// SDK reshapes nothing. Two consequences for callers: `tx1Effects` — the
/// versioned Ironwood TX1 effecting data the vote chain requires, and whose
/// absence is the `400: tx1 effects must be 821 bytes, got 0` rejection — is
/// present without anyone assembling it, and the legacy `sighash` field is gone
/// from the wire. The signer's sighash still exists; it simply never belonged in
/// the submission body, because the server derives the signing digest itself.
public struct VotingDelegationSubmission: Codable, Sendable {
    /// Randomized verification key (`rk` on the wire), base64.
    public let randomizedKey: String
    /// SpendAuth signature over the PCZT sighash, base64.
    public let spendAuthSig: String
    /// Versioned Ironwood TX1 effecting data, base64 (821 bytes decoded).
    public let tx1Effects: String
    public let nfSigned: String
    public let cmxNew: String
    public let govComm: String
    public let govNullifiers: [String]
    public let proof: String
    public let voteRoundId: String

    enum CodingKeys: String, CodingKey {
        case randomizedKey = "rk"
        case spendAuthSig = "spend_auth_sig"
        case tx1Effects = "tx1_effects"
        case nfSigned = "signed_note_nullifier"
        case cmxNew = "cmx_new"
        case govComm = "van_cmx"
        case govNullifiers = "gov_nullifiers"
        case proof
        case voteRoundId = "vote_round_id"
    }
}

// MARK: - Vote Commit (JSON)

/// The result of committing one cast vote: the signed commitment fields destined
/// for the vote chain, and the encrypted shares the vote proof binds.
///
/// Helper-server payloads are deliberately not here. A commit made before the
/// vote's tree position is confirmed can only produce provisional payloads, and
/// sending those is the bug the sequence in `CHP_DESIGN.md` §3/A2 exists to
/// prevent. Build helper payloads with
/// ``VotingRustBackend/recoverWireJson(commitmentBundleJson:proposalId:shareIndex:voteCommitmentTreePosition:submitAt:)``
/// after ``VotingRustBackend/confirmVoteSubmission(roundId:bundleIndex:proposalId:txHash:eventsJson:)``.
///
/// Every field here is wire data — it is published on chain — so the commit
/// result carries no secret the wallet must retain. The signing secrets used to
/// produce it stay inside `zcash_voting`.
public struct VotingVoteCommit: Codable, Sendable {
    public let proposalId: UInt32
    public let vanNullifier: [UInt8]
    public let voteAuthorityNoteNew: [UInt8]
    public let voteCommitment: [UInt8]
    public let proof: [UInt8]
    public let anchorHeight: UInt32
    /// Randomizer for the vote public key (`r_vpk` on the wire).
    public let voteKeyRandomizer: [UInt8]
    public let voteAuthSig: [UInt8]
    public let encShares: [VotingWireEncryptedShare]

    enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
        case vanNullifier = "van_nullifier"
        case voteAuthorityNoteNew = "vote_authority_note_new"
        case voteCommitment = "vote_commitment"
        case proof
        case anchorHeight = "anchor_height"
        case voteKeyRandomizer = "r_vpk"
        case voteAuthSig = "vote_auth_sig"
        case encShares = "enc_shares"
    }
}

// MARK: - Wire Encrypted Share (JSON)

/// Wire-safe encrypted share — only the public ciphertext components.
///
/// Decoded straight from `zcash_voting::types::WireEncryptedShare`, which
/// base64-encodes both ciphertext components, so `ciphertext1` and `ciphertext2`
/// are base64 strings rather than byte arrays. Secrets (`plaintext_value`,
/// `randomness`) stay inside Rust and never cross the FFI boundary.
public struct VotingWireEncryptedShare: Codable, Sendable {
    /// First ciphertext component (`c1` on the wire), base64.
    public let ciphertext1: String
    /// Second ciphertext component (`c2` on the wire), base64.
    public let ciphertext2: String
    public let shareIndex: UInt32

    enum CodingKeys: String, CodingKey {
        case ciphertext1 = "c1"
        case ciphertext2 = "c2"
        case shareIndex = "share_index"
    }

    public init(ciphertext1: String, ciphertext2: String, shareIndex: UInt32) {
        self.ciphertext1 = ciphertext1
        self.ciphertext2 = ciphertext2
        self.shareIndex = shareIndex
    }
}

```

- [ ] **Step 2.10: Confirm nothing else in the SDK referenced the deleted type.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -rn 'VotingSharePayload\|sharePayloads\|allEncShares' Sources/ Tests/; echo "LEFTOVER_EXIT=$?"
```

Expected: no output and `LEFTOVER_EXIT=1`. Any hit inside `Sources/` must be fixed here; any hit
inside `Tests/` is a deviation to surface, because plan Task 6 asserts the voting suite is
unmodified.

- [ ] **Step 2.11: CHANGELOG + MIGRATING.** In `CHANGELOG.md`, under `# Unreleased` → `## Changed`,
insert this immediately after the bullet added in Task 1:

```markdown
- The voting FFI no longer maintains its own copies of `zcash_voting`'s wire formats. Payloads bound
  for the vote chain and the helper servers are serialized by the crate and handed across the
  boundary verbatim, which makes two rc.4 wire corrections automatic rather than hand-written:
  `VotingDelegationSubmission` gains `tx1Effects` (and loses the wire-level `sighash`), and helper
  payloads no longer carry every helper's share. Concretely: `VotingDelegationSubmission`'s byte
  fields are now base64 `String`s matching the crate's encoding; `VotingWireEncryptedShare`'s
  `ciphertext1`/`ciphertext2` are base64 `String`s; `VotingSharePayload` is removed; and
  `VotingVoteCommit` no longer carries `sharePayloads`, because payloads built before the vote's
  tree position is confirmed are provisional and must not be submitted.
```

Then, in `MIGRATING.md`, insert this section immediately after the `# Migrating from previous
versions to _Unreleased_` heading line. **Note the outer fence below is four backticks so the inner
Swift block survives — write the content between them, not the fences themselves:**

````markdown
## Voting wire payloads are produced by `zcash_voting`, not by the SDK

`VotingSharePayload` is removed and `VotingVoteCommit.sharePayloads` is gone with it. Helper-server
payloads are now obtained after confirmation, one per share index:

```swift
let bundle = try backend.getCommitmentBundle(
    roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId
)
let payload = try VotingRustBackend.recoverWireJson(
    commitmentBundleJson: bundle!.bundleJson,
    proposalId: proposalId,
    shareIndex: shareIndex,
    voteCommitmentTreePosition: confirmation.voteCommitmentTreePosition,
    submitAt: submitAt
)
```

`payload` is the helper request body verbatim — do not decode, re-shape or re-encode it.

`VotingDelegationSubmission` and `VotingWireEncryptedShare` are now decoded from the crate's own
wire structs, so their byte fields are base64 `String`s rather than `[UInt8]`, `sighash` is gone
from the delegation submission (the vote chain derives the signing digest itself), and
`tx1Effects` is present. A host that base64-encoded these fields itself before putting them on the
wire must stop and send the strings as they arrive.
````

- [ ] **Step 2.12: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add rust/src/voting/json.rs rust/src/voting/tree.rs rust/src/voting/delegation.rs Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift CHANGELOG.md MIGRATING.md && git commit -m "[#1855] Marshal zcash_voting's own wire types instead of mirroring them in the voting FFI" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: S4 — two thin passthroughs (`confirm_vote_submission`, `recover_wire_json`)

*Code blocks by: Opus (SDK delegate). Rust is probe-proven (both symbols compile, cbindgen emits
both into `target/Headers/zcashlc.h`, `cargo test --lib voting` green); Swift wrappers and the two
test files are written-from-reading and are compiled and executed at plan Task 6.*

Zero logic. Each function parses its inputs, calls one public crate function, and serializes the
crate's own result type. No phase tracking, no `leaf_index` splitting, no position arithmetic — all
of that is inside `zcash_voting` and stays there. This FFI generates its C header with cbindgen
(`rust/build.rs`), so there is **no header file to edit**.

**Files:**
- Create: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/confirmation.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting.rs:9`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/share_tracking.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`
- Test: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Tests/OfflineTests/VotingConfirmVoteSubmissionTests.swift`
- Test: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Tests/OfflineTests/VotingRecoverWireJsonTests.swift`

**Interfaces:**
- Consumes: `zcash_voting::confirmation::{confirm_vote_submission, TxEvent}` (rc.5 `confirmation.rs:119`) and `zcash_voting::share::recover_wire_json` (rc.5 `share.rs:192`); result type `zcash_voting::wire::VoteConfirmation`.
- Produces: C symbols `zcashlc_voting_confirm_vote_submission` and `zcashlc_voting_recover_wire_json`; Swift `VotingRustBackend.confirmVoteSubmission(...)`, `VotingRustBackend.recoverWireJson(...)` (static) and `VotingVoteConfirmation`. Plan Tasks 9 and 14 consume these; the exact signatures are in `## INTERFACES-FOR-APP`.

---

- [ ] **Step 3.1: Create the confirmation FFI module.** Create
`rust/src/voting/confirmation.rs` with exactly this content:

```rust
use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};

/// Record a confirmed cast-vote transaction in one durable step.
///
/// Thin passthrough to `zcash_voting::confirmation::confirm_vote_submission`:
/// the crate parses the confirmation events, records the transaction hash,
/// advances the vote-authority-note position and records the vote-commitment
/// tree position inside a single database transaction, then returns both
/// positions. The FFI adds no parsing, no phase tracking and no state of its
/// own — in particular it does not split the `leaf_index` attribute, which is
/// the crate's job.
///
/// `events_json` is the confirmation-events array the wallet's chain client
/// returned, serialized as JSON: a list of
/// `{"type": "...", "attributes": [{"key": "...", "value": "..."}]}` objects,
/// which is exactly `Vec<zcash_voting::confirmation::TxEvent>`.
///
/// Returns JSON-encoded `zcash_voting::wire::VoteConfirmation` as
/// `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument (`round_id`, `tx_hash`,
///   `events_json`): if `len > 0` then `ptr` must be non-null and valid for
///   reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_confirm_vote_submission(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
    tx_hash: *const u8,
    tx_hash_len: usize,
    events_json: *const u8,
    events_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let tx_hash_str = unsafe { str_from_ptr(tx_hash, tx_hash_len) }?;
        let events_bytes = unsafe { bytes_from_ptr(events_json, events_json_len) }?;
        let events: Vec<voting::confirmation::TxEvent> = serde_json::from_slice(events_bytes)?;

        let confirmation = voting::confirmation::confirm_vote_submission(
            &handle.db,
            &round_id_str,
            bundle_index,
            proposal_id,
            &tx_hash_str,
            &events,
        )
        .map_err(|e| anyhow!("confirm_vote_submission failed: {}", e))?;

        json_to_boxed_slice(&confirmation)
    });
    unwrap_exc_or_null(res)
}
```

- [ ] **Step 3.2: Register the module.** In `rust/src/voting.rs`, replace:

```rust
mod constants;
pub mod db;
```

with:

```rust
pub mod confirmation;
mod constants;
pub mod db;
```

- [ ] **Step 3.3: Add the share-recovery passthrough.** In
`rust/src/voting/share_tracking.rs`, insert this immediately **before** the line
`#[cfg(test)]` that opens the test module at the bottom of the file (i.e. after the closing brace
of `zcashlc_voting_add_sent_servers`, with one blank line on each side):

```rust
/// Rebuild one helper-server share payload as the crate's own wire JSON.
///
/// Thin passthrough to `zcash_voting::share::recover_wire_json`: the crate
/// parses the persisted recovery bundle, selects the requested share, binds the
/// confirmed vote-commitment-tree position and the scheduled submission time
/// into it, and serializes the result with its own `VoteShareWire` codec. No
/// second commit happens, and the FFI shapes nothing: the returned bytes are
/// the helper payload verbatim.
///
/// `commitment_bundle_json` is the recovery JSON previously read with
/// `zcashlc_voting_get_commitment_bundle`.
///
/// Returns the UTF-8 wire JSON as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - If `commitment_bundle_json_len > 0` then `commitment_bundle_json` must be
///   non-null and valid for reads for that many bytes; if it is `0`, the pointer
///   is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_recover_wire_json(
    commitment_bundle_json: *const u8,
    commitment_bundle_json_len: usize,
    proposal_id: u32,
    share_index: u32,
    vc_tree_position: u64,
    submit_at: u64,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bundle_json =
            unsafe { str_from_ptr(commitment_bundle_json, commitment_bundle_json_len) }?;

        let wire_json = voting::share::recover_wire_json(
            &bundle_json,
            proposal_id,
            share_index,
            vc_tree_position,
            submit_at,
        )
        .map_err(|e| anyhow!("recover_wire_json failed: {}", e))?;

        Ok(crate::ffi::BoxedSlice::some(wire_json.into_bytes()))
    });
    unwrap_exc_or_null(res)
}
```

No new imports are needed: `anyhow!`, `catch_panic`, `str_from_ptr`, `unwrap_exc_or_null` and
`voting` are all already imported at the top of that file.

- [ ] **Step 3.4: Rust format + compile gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check && set -o pipefail && cargo check 2>&1 | tee /tmp/chp-t3-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, only the pre-existing `migration_plan_cache.rs:77` warning.

- [ ] **Step 3.5: Header-generation assert.** cbindgen writes the C header during the build, so the
two new declarations must already be there. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -c 'zcashlc_voting_confirm_vote_submission\|zcashlc_voting_recover_wire_json' target/Headers/zcashlc.h
```

Expected: `2`. If the file does not exist, run `cargo check` once more (the header is a build-script
side effect) and retry. A count below 2 means a symbol did not export — report it and stop.

- [ ] **Step 3.6: Rust test gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t3-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `test result: ok. 72 passed; 0 failed`.

- [ ] **Step 3.7: Add the Swift confirmation type.** Append to the end of
`Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift` (after the `VotingPirLayout` block Task
1 added):

```swift

// MARK: - Vote confirmation (JSON)

/// The positions a mined cast-vote transaction confirmed.
///
/// Decoded from `zcash_voting::wire::VoteConfirmation`. Both positions are read
/// out of the chain's confirmation events by the crate, which also writes them
/// to the voting database in the same transaction that returns them — so this
/// value and the persisted state can never disagree.
public struct VotingVoteConfirmation: Codable, Sendable, Equatable {
    /// The confirmed transaction hash, echoed back from the events.
    public let txHash: String
    /// Confirmed vote-authority-note leaf position.
    public let vanLeafPosition: UInt32
    /// Confirmed position of the vote commitment within the vote commitment
    /// tree. This is the value to late-bind into helper-share payloads.
    public let voteCommitmentTreePosition: UInt64

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case vanLeafPosition = "van_leaf_position"
        case voteCommitmentTreePosition = "vc_tree_position"
    }
}
```

- [ ] **Step 3.8: Add the `confirmVoteSubmission` wrapper.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`, insert this method into the
`// MARK: - Vote casting` extension, immediately after the closing brace of `markVoteSubmitted` and
before the closing brace of that extension:

```swift

    /// Record a confirmed cast-vote transaction in one atomic step.
    ///
    /// `zcash_voting` parses the confirmation events, records the transaction
    /// hash, advances the vote-authority-note position and records the
    /// vote-commitment tree position inside a single database transaction, then
    /// returns both positions. Callers must not parse the events themselves:
    /// splitting the `leaf_index` attribute by hand is exactly the duplicated
    /// state this entry point exists to delete.
    ///
    /// `eventsJson` is the confirmation-events array the wallet's chain client
    /// already fetches, serialized as JSON — a list of
    /// `{"type": …, "attributes": [{"key": …, "value": …}]}` objects.
    ///
    /// Repeating the call with the same transaction hash and position is
    /// accepted; a stale confirmation cannot rewind a position that a later one
    /// already advanced.
    public func confirmVoteSubmission(
        roundId: String,
        bundleIndex: UInt32,
        proposalId: UInt32,
        txHash: String,
        eventsJson: String
    ) throws -> VotingVoteConfirmation {
        let roundIdBytes = [UInt8](roundId.utf8)
        let txHashBytes = [UInt8](txHash.utf8)
        let eventsBytes = [UInt8](eventsJson.utf8)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice> = try withHandle { dbh in
            let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = roundIdBytes.withUnsafeBufferPointer { ridBuf in
                txHashBytes.withUnsafeBufferPointer { txBuf in
                    eventsBytes.withUnsafeBufferPointer { evBuf in
                        zcashlc_voting_confirm_vote_submission(
                            dbh,
                            ridBuf.baseAddress,
                            UInt(ridBuf.count),
                            bundleIndex,
                            proposalId,
                            txBuf.baseAddress,
                            UInt(txBuf.count),
                            evBuf.baseAddress,
                            UInt(evBuf.count)
                        )
                    }
                }
            }

            guard let ptr else {
                throw VotingRustBackendError.rustError(
                    lastErrorMessage(fallback: "`confirm_vote_submission` failed")
                )
            }
            return ptr
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        return try decodeJSON(from: ptr)
    }
```

- [ ] **Step 3.9: Add the `recoverWireJson` wrapper.** In the same file, insert this method into the
`// MARK: - Share tracking (static)` extension, immediately after the closing brace of
`computeShareNullifier` and before the closing brace of that extension:

```swift

    /// Rebuild one helper-server share payload as `zcash_voting`'s own wire JSON.
    ///
    /// The crate parses the persisted recovery bundle, selects the requested
    /// share, late-binds the confirmed vote-commitment-tree position and the
    /// scheduled submission time, and serializes the payload itself. Nothing is
    /// re-proved and nothing is committed a second time.
    ///
    /// - Parameters:
    ///   - commitmentBundleJson: ``VotingStoredCommitmentBundle/bundleJson`` from
    ///     `getCommitmentBundle(roundId:bundleIndex:proposalId:)`.
    ///   - voteCommitmentTreePosition: the confirmed position, from
    ///     ``VotingVoteConfirmation/voteCommitmentTreePosition``.
    /// - Returns: the helper request body. POST it verbatim; do not decode,
    ///   re-shape or re-encode it.
    /// - Throws: `VotingRustBackendError.rustError` if the bundle JSON is
    ///   malformed, its proposal does not match `proposalId`, or the share index
    ///   is not present in it.
    public static func recoverWireJson(
        commitmentBundleJson: String,
        proposalId: UInt32,
        shareIndex: UInt32,
        voteCommitmentTreePosition: UInt64,
        submitAt: UInt64
    ) throws -> String {
        let bundleBytes = [UInt8](commitmentBundleJson.utf8)
        let payload = try staticBoxedSliceFFI(fallback: "`recover_wire_json` failed") {
            bundleBytes.withUnsafeBufferPointer { buf in
                zcashlc_voting_recover_wire_json(
                    buf.baseAddress,
                    UInt(buf.count),
                    proposalId,
                    shareIndex,
                    voteCommitmentTreePosition,
                    submitAt
                )
            }
        }
        return String(decoding: payload, as: UTF8.self)
    }
```

- [ ] **Step 3.10: Add the confirmation offline test file.** Create
`Tests/OfflineTests/VotingConfirmVoteSubmissionTests.swift` with exactly this content. It follows
the existing suite's DB-fixture pattern (`VotingRustBackendTests.swift`): a canonical 64-hex round
id, a temp-path database opened per test and cleaned up in `tearDown`, and assertions on the two
error surfaces an offline test can reach — a proof cannot be produced without a chain, so the
success path belongs to the testnet E2E round.

```swift
//
//  VotingConfirmVoteSubmissionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// Builds a round identifier that satisfies the Rust round-parameter validation,
/// which requires 64 lowercase hex characters encoding a canonical Pallas field
/// element. `tag` occupies the low byte so each caller gets a distinct round.
private func hexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

private let confirmWalletId = "test-wallet"
private let confirmNetworkId: UInt32 = 1
/// A well-formed round identifier that is never initialized, so the crate has no
/// vote row to confirm against.
private let confirmMissingRoundId = hexRoundId(0xfd)
private let confirmTxHash = "vote-tx-hash"
/// One well-formed `cast_vote` event, shaped exactly as
/// `Vec<zcash_voting::confirmation::TxEvent>` deserializes it. The FFI must hand
/// it to the crate unparsed — the SDK never splits `leaf_index` itself.
private let confirmEventsJson = """
[{"type":"cast_vote","attributes":[\
{"key":"vote_round_id","value":"\(confirmMissingRoundId)"},\
{"key":"leaf_index","value":"7,42"}]}]
"""

final class VotingConfirmVoteSubmissionTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
        super.tearDown()
    }

    func test_confirmVoteSubmission_beforeOpen_throwsDatabaseNotOpen() {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(
            try backend.confirmVoteSubmission(
                roundId: confirmMissingRoundId,
                bundleIndex: 0,
                proposalId: 1,
                txHash: confirmTxHash,
                eventsJson: confirmEventsJson
            )
        ) { error in
            guard case VotingRustBackendError.databaseNotOpen = error else {
                XCTFail("expected .databaseNotOpen, got \(error.localizedDescription)")
                return
            }
        }
    }

    func test_confirmVoteSubmission_afterOpen_missingVote_throwsRustError() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.confirmVoteSubmission(
                roundId: confirmMissingRoundId,
                bundleIndex: 0,
                proposalId: 1,
                txHash: confirmTxHash,
                eventsJson: confirmEventsJson
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("confirm_vote_submission failed"),
                "unexpected message: \(message)"
            )
        }
    }

    // MARK: - Helpers

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingConfirmVoteSubmissionTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: confirmNetworkId)
        try backend.setWalletId(confirmWalletId)
        return backend
    }
}
```

- [ ] **Step 3.11: Add the share-recovery offline test file.** Create
`Tests/OfflineTests/VotingRecoverWireJsonTests.swift` with exactly this content. `recoverWireJson`
is static and takes no database handle, so its offline surface is input validation — a bundle JSON
the crate cannot parse, and one whose proposal id disagrees with the request.

```swift
//
//  VotingRecoverWireJsonTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

private let recoverProposalId: UInt32 = 1
private let recoverShareIndex: UInt32 = 0
private let recoverConfirmedPosition: UInt64 = 999
private let recoverSubmitAt: UInt64 = 123

final class VotingRecoverWireJsonTests: XCTestCase {
    func test_recoverWireJson_malformedBundleJson_throwsRustError() {
        XCTAssertThrowsError(
            try VotingRustBackend.recoverWireJson(
                commitmentBundleJson: "not json",
                proposalId: recoverProposalId,
                shareIndex: recoverShareIndex,
                voteCommitmentTreePosition: recoverConfirmedPosition,
                submitAt: recoverSubmitAt
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("recover_wire_json failed"),
                "unexpected message: \(message)"
            )
        }
    }

    func test_recoverWireJson_emptyBundleJson_throwsRustError() {
        XCTAssertThrowsError(
            try VotingRustBackend.recoverWireJson(
                commitmentBundleJson: "",
                proposalId: recoverProposalId,
                shareIndex: recoverShareIndex,
                voteCommitmentTreePosition: recoverConfirmedPosition,
                submitAt: recoverSubmitAt
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("recover_wire_json failed"),
                "unexpected message: \(message)"
            )
        }
    }
}
```

Both files run at plan Task 6 (`swift test --filter OfflineTests`), after the FFI rebuild in plan
Task 5 puts the two new symbols in the library. They cannot run before that.

- [ ] **Step 3.12: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Added`, append this
bullet at the end of that section (immediately before the `## Changed` heading):

```markdown
- Two thin passthroughs to `zcash_voting` operations the SDK previously made callers assemble by
  hand. `VotingRustBackend.confirmVoteSubmission(roundId:bundleIndex:proposalId:txHash:eventsJson:)`
  hands the chain's confirmation events to the crate, which parses them, records the transaction
  hash, advances the vote-authority-note position and records the vote-commitment tree position in
  one database transaction, returning both as `VotingVoteConfirmation` — replacing a caller-side
  `leaf_index` string split and a two-write window in which a crash could leave the two positions
  disagreeing. `VotingRustBackend.recoverWireJson(commitmentBundleJson:proposalId:shareIndex:voteCommitmentTreePosition:submitAt:)`
  rebuilds one helper-server payload from the persisted recovery bundle with the confirmed position
  late-bound into it, without re-proving or committing again; the returned string is the helper
  request body verbatim.
```

- [ ] **Step 3.13: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add rust/src/voting.rs rust/src/voting/confirmation.rs rust/src/voting/share_tracking.rs Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift Tests/OfflineTests/VotingConfirmVoteSubmissionTests.swift Tests/OfflineTests/VotingRecoverWireJsonTests.swift CHANGELOG.md && git commit -m "[#1855] Expose zcash_voting's atomic vote confirmation and helper-share recovery through the FFI" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: S5 — publicize `nu63ConsensusBranchID`

*Code blocks by: Opus (SDK delegate). Written-from-reading; compiles at plan Task 6.*

Read `## CORRECTIONS` item 9 first: the constant currently lives on an **internal** type, where
adding `public` would change nothing. It moves to the SDK's public constants namespace and the one
existing use site is repointed, so there stays exactly one declaration of the value.

**Files:**
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Constants/ZcashSDK.swift:140`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift:24-27` and `:85`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`
- Test: none — covered by the existing `swift build` at plan Task 6

**Interfaces:**
- Consumes: the existing `public typealias ConsensusBranchID = Int32` (`Extensions/ZcashSDK+extensions.swift:10`).
- Produces: `public static let ZcashSDK.nu63ConsensusBranchID: ConsensusBranchID` = `0x37a5_165b`. Plan Task 11 (A4) replaces the hardcoded `0xC8E7_1055` at `VotingCryptoClientLiveKey.swift:218` with it; note the app's `VotingBuildPcztParams.consensusBranchId` is `UInt32`, so the conversion is `UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)`.

---

- [ ] **Step 4.1: Declare the public constant.** In
`Sources/ZcashLightClientKit/Constants/ZcashSDK.swift`, replace:

```swift
public enum ZcashSDK {
    /// The number of zatoshi that equal 1 ZEC.
    public static let zatoshiPerZEC: BlockHeight = 100_000_000
```

with:

```swift
public enum ZcashSDK {
    /// The consensus branch ID of NU6.3 ("Ironwood").
    ///
    /// Published so hosts that must name the active consensus era read it from
    /// the SDK instead of hardcoding the literal. The voting stack is the case
    /// that forced this: `zcash_voting` rejects a delegation built for any other
    /// branch, so a stale hardcoded era does not degrade — every delegation fails
    /// at construction. A constant that moves with the SDK cannot go stale
    /// silently at the next network upgrade the way a copied literal does.
    public static let nu63ConsensusBranchID: ConsensusBranchID = 0x37a5_165b

    /// The number of zatoshi that equal 1 ZEC.
    public static let zatoshiPerZEC: BlockHeight = 100_000_000
```

- [ ] **Step 4.2: Repoint the server-validation use site.** In
`Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift`, replace:

```swift
extension ValidateServerAction: Action {
    /// The consensus branch ID of NU6.3 ("Ironwood"). When the chain is on this branch, the
    /// connected server must serve Ironwood data — see the tree-state check in `run` below.
    static let nu63ConsensusBranchID: ConsensusBranchID = 0x37a5_165b

    var removeBlocksCacheWhenFailed: Bool { false }
```

with:

```swift
extension ValidateServerAction: Action {
    var removeBlocksCacheWhenFailed: Bool { false }
```

and, further down in the same file, replace:

```swift
            if remoteBranchID == Self.nu63ConsensusBranchID {
```

with:

```swift
            if remoteBranchID == ZcashSDK.nu63ConsensusBranchID {
```

The doc comment moved with the value; the tree-state check below the call site still explains why
this branch is special, so nothing is lost from this file.

- [ ] **Step 4.3: Single-declaration assert.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -rn 'nu63ConsensusBranchID\|0x37a5_165b' Sources/ Tests/
```

Expected, exactly two lines — one declaration and one use:

```
Sources/ZcashLightClientKit/Constants/ZcashSDK.swift:142:    public static let nu63ConsensusBranchID: ConsensusBranchID = 0x37a5_165b
Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift:82:            if remoteBranchID == ZcashSDK.nu63ConsensusBranchID {
```

(Line numbers shift with the edits above; the two file paths and the absence of any third hit are
what matters.) A surviving `static let nu63ConsensusBranchID` inside `ValidateServerAction` means
step 4.2's first replacement did not apply — fix it before committing.

- [ ] **Step 4.4: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Added`, append this
bullet at the end of that section (immediately before the `## Changed` heading):

```markdown
- `ZcashSDK.nu63ConsensusBranchID` publishes the NU6.3 ("Ironwood") consensus branch ID,
  `0x37a5_165b`. It was already used internally by the server-validation path; it is public now so
  hosts that must name the era — voting delegations are rejected outright when built for the wrong
  branch — take it from the SDK rather than copying the literal.
```

- [ ] **Step 4.5: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add Sources/ZcashLightClientKit/Constants/ZcashSDK.swift Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift CHANGELOG.md && git commit -m "[#1855] Publish the NU6.3 consensus branch ID as an SDK constant" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4B: S4b — software delegation-signing passthrough [F1 resolution]

*Code blocks by: Opus (F1 amendment delegate). Rust and Swift are written-from-reading against
`zcash_voting 2.0.0-rc.5`'s cached source and the SDK worktree pinned at `7e4f03e7`; the Rust
compiles at this task's own steps 4B.4/4B.5, the Swift compiles and the test executes at plan
Task 6.*

This task resolves the STOP finding that Task 8's step 8.14 used to raise (`## CORRECTIONS`
item 4, app lane): the software (non-Keystone) delegation path had no signature source under
the 2.0 API. It does have one — `zcash_voting` prescribes it. The crate stopped deriving
account keys and signing on the caller's behalf, and in the same release added
`delegate::signing_request`, which hands the wallet the account index, network, seed
fingerprint, PCZT sighash and spend-auth randomizer for one bundle and expects the wallet to
derive its own Orchard SpendAuth key, randomize it with the randomizer, sign the sighash, and
hand back the detached signature. That recipe is stated in the crate's own doc comment
(`src/delegate.rs:405-410`) and README ("Secret boundaries", `README.md:235-241`), and is
implemented, shipped and unit-tested in the crate authors' own reference wallet, Vizor
(`chainapsis/vizor-wallet`, `rust/src/wallet/voting/delegation.rs:318-349`). This task
transcribes that implementation behind one FFI symbol.

Shape: the S4 passthrough pattern (Task 3) plus ~20 lines of crypto that are transcribed, not
designed. Everything the recipe needs — `orchard`, `pasta_curves`, `ff`, `zip32`, `rand`,
`zcash_keys` — is already a direct dependency of `rust/Cargo.toml`, so no dependency changes.
The FFI generates its C header with cbindgen (`rust/build.rs`), so there is **no header file to
edit**.

**Files:**
- Create: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/signing.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting.rs` (module list)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`
- Test: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Tests/OfflineTests/VotingSignDelegationRequestTests.swift`

**Interfaces:**
- Consumes: `zcash_voting::delegate::signing_request` (rc.5 `delegate.rs:874`) and its result
  `delegate::DelegationSigningRequest` (`delegate.rs:412-426`); `delegate::DelegationKeys::with_voting_hotkey`
  (`delegate.rs:84-100`), reconstructed exactly as `zcashlc_voting_build_and_prove_delegation`
  already does; `zcash_keys::keys::UnifiedSpendingKey`, `orchard::keys::SpendAuthorizingKey`,
  `pasta_curves::pallas::Scalar`, `zip32::fingerprint::SeedFingerprint` — all existing direct
  dependencies.
- Produces: C symbol `zcashlc_voting_sign_delegation_request`; Swift
  `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` returning the new
  `VotingDelegationSignature`. Plan Task 8 (step 8.14) consumes it; the exact signature is in
  `## INTERFACES-FOR-APP`.

**Security note for the executing delegate:** `seed` is wallet root seed material and this is
the only voting FFI entry point that takes it. Handle it exactly as the existing seed-taking
voting FFI does (`zcashlc_voting_generate_delegation_inputs`, `rust/src/voting/util.rs:33-86`):
borrow it through `bytes_from_ptr`, never copy it into an owned buffer, never log it, never
persist it, never pass it to `zcash_voting`. There is deliberately no zeroization step, because
there is deliberately no copy to zeroize — the Swift caller owns the allocation and its
lifetime, which is the same contract every other voting FFI byte input has. Do not add
`println!`/`dbg!`/`log::` calls to this module, even temporarily while debugging.

---

- [ ] **Step 4B.1: Create the signing FFI module.** Create `rust/src/voting/signing.rs` with
exactly this content:

```rust
use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use pasta_curves::pallas;
use serde::Serialize;
use zcash_voting as voting;
use zip32::AccountId;

use crate::unwrap_exc_or_null;

use super::constants::SEED_FINGERPRINT_LEN;
use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr, usk_from_seed};

/// The detached SpendAuth signature this wallet produced for one delegation
/// bundle, with the sighash it covers.
///
/// Not a mirror of any `zcash_voting` wire type: the crate has no type for a
/// bare `(signature, sighash)` pair, because it never sees the signing step.
/// This is the FFI's own two-field return envelope, so it lives here rather
/// than in `json.rs`.
#[derive(Serialize)]
struct JsonDelegationSignature {
    sig: Vec<u8>,
    sighash: Vec<u8>,
}

/// Sign one delegation bundle's PCZT sighash with the account's own Orchard
/// SpendAuth key.
///
/// This implements `zcash_voting`'s own prescribed software-wallet recipe; it
/// is not an SDK invention. The crate stopped deriving account keys and signing
/// on the caller's behalf in 2.0 and documents the replacement on
/// `delegate::DelegationSigningRequest` (rc.5 `src/delegate.rs:405-410`): a
/// software wallet uses `account_index`, `network`, `sighash` and `alpha` to
/// derive its account SpendAuth key locally, randomizes it, signs `sighash`,
/// and passes the resulting signature back. The crate README states the same
/// under "Secret boundaries" (`README.md:235-241`). The derive → randomize →
/// sign body below is transcribed from the crate authors' own reference wallet,
/// Vizor (`chainapsis/vizor-wallet`, `rust/src/wallet/voting/delegation.rs:318-349`),
/// which ships it with a signature-verifying round-trip test.
///
/// Two calls make one delegation submission: this one produces the signature,
/// then `zcashlc_voting_get_delegation_submission_with_signature` consumes it.
/// The sighash returned here is not decorative — the crate checks it against
/// the sighash it stored at setup and refuses the submission if they disagree.
/// The Keystone flow differs only in where the signature comes from.
///
/// `fvk_bytes`, `hotkey_stored_secret`, `seed_fingerprint`, `account_index` and
/// `round_name` are the same delegation-key inputs
/// `zcashlc_voting_build_and_prove_delegation` takes, because the crate loads
/// the signing request through the same `DelegationKeys` value that built the
/// PCZT.
///
/// # Key material
///
/// `seed` is wallet root seed material — the only voting FFI entry point that
/// takes it. It is borrowed for the duration of the call through
/// `bytes_from_ptr` and never copied into an owned buffer, so there is nothing
/// here to zeroize; the caller owns the allocation and its lifetime, exactly as
/// for every other voting FFI byte input. It is never logged, never persisted
/// and never handed to `zcash_voting`: only the locally derived randomized key
/// touches it, and only the 64-byte detached signature leaves this function.
///
/// Returns JSON-encoded `{"sig": [..64], "sighash": [..32]}` as
/// `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument (`round_id`, `fvk_bytes`,
///   `hotkey_stored_secret`, `seed_fingerprint`, `round_name`, `seed`): if
///   `len > 0` then `ptr` must be non-null and valid for reads for `len` bytes;
///   if `len == 0`, `ptr` is ignored.
/// - `seed` must remain valid and unmutated for the duration of the call. The
///   callee neither retains nor frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_sign_delegation_request(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    fvk_bytes: *const u8,
    fvk_bytes_len: usize,
    hotkey_stored_secret: *const u8,
    hotkey_stored_secret_len: usize,
    seed_fingerprint: *const u8,
    seed_fingerprint_len: usize,
    account_index: u32,
    round_name: *const u8,
    round_name_len: usize,
    seed: *const u8,
    seed_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let fvk = unsafe { bytes_from_ptr(fvk_bytes, fvk_bytes_len) }?;
        let hotkey_secret =
            unsafe { bytes_from_ptr(hotkey_stored_secret, hotkey_stored_secret_len) }?;
        let seed_fp_bytes = unsafe { bytes_from_ptr(seed_fingerprint, seed_fingerprint_len) }?;
        let seed_fp_32: [u8; SEED_FINGERPRINT_LEN] = seed_fp_bytes.try_into().map_err(|_| {
            anyhow!(
                "seed_fingerprint must be {} bytes, got {}",
                SEED_FINGERPRINT_LEN,
                seed_fp_bytes.len()
            )
        })?;
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let seed_bytes = unsafe { bytes_from_ptr(seed, seed_len) }?;

        let hotkey = voting::VotingHotkey::from_stored_secret(hotkey_secret, handle.network)
            .map_err(|e| anyhow!("failed to reconstruct voting hotkey: {}", e))?;
        let keys = voting::delegate::DelegationKeys::with_voting_hotkey(
            fvk.to_vec(),
            &hotkey,
            seed_fp_32,
            account_index,
            round_name_str,
        )
        .map_err(|e| anyhow!("failed to build delegation keys: {}", e))?;

        let request =
            voting::delegate::signing_request(&handle.db, &round_id_str, bundle_index, &keys)
                .map_err(|e| anyhow!("signing_request failed: {}", e))?;

        // Bind the request to this exact wallet seed before deriving any keys.
        let seed_fp = zip32::fingerprint::SeedFingerprint::from_seed(seed_bytes)
            .ok_or_else(|| anyhow!("seed length is not valid for ZIP-32"))?;
        if seed_fp.to_bytes() != request.seed_fingerprint {
            return Err(anyhow!(
                "wallet seed fingerprint does not match the delegation signing request"
            ));
        }

        // The request's network is the round's stored network: the crate
        // validated `keys.network` (which came from `handle.network` through
        // the hotkey) against it before answering. Asserting it here is what
        // makes deriving through the SDK's own `usk_from_seed(handle.network_id,
        // ..)` provably equivalent to deriving from `request.network` directly,
        // and it fails closed if a later release sources that field elsewhere.
        if request.network != handle.network {
            return Err(anyhow!(
                "delegation signing request network does not match the open voting database"
            ));
        }

        let account = AccountId::try_from(request.account_index).map_err(|_| {
            anyhow!(
                "account_index must be < 2^31, got {}",
                request.account_index
            )
        })?;
        let usk = usk_from_seed(handle.network_id, seed_bytes, account)
            .map_err(|e| anyhow!("failed to derive sender UnifiedSpendingKey: {}", e))?;
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());

        // The alpha randomizer must decode as a canonical Pallas scalar.
        let alpha = Option::<pallas::Scalar>::from(pallas::Scalar::from_repr(request.alpha))
            .ok_or_else(|| anyhow!("delegation alpha is not a canonical Pallas scalar"))?;

        // Sign the request's own sighash with the randomized spend auth key.
        let rsk = ask.randomize(&alpha);
        let sig = rsk.sign(rand::rngs::OsRng, &request.sighash);
        let sig_bytes: [u8; 64] = (&sig).into();

        json_to_boxed_slice(&JsonDelegationSignature {
            sig: sig_bytes.to_vec(),
            sighash: request.sighash.to_vec(),
        })
    });
    unwrap_exc_or_null(res)
}
```

- [ ] **Step 4B.2: Register the module.** In `rust/src/voting.rs`, replace:

```rust
pub mod share_tracking;
#[cfg(test)]
```

with:

```rust
pub mod share_tracking;
pub mod signing;
#[cfg(test)]
```

(This is the post-Task-3 module list, which already begins with `pub mod confirmation;`. If
`pub mod share_tracking;` is not present, Task 3 did not land — stop and check the SDK
worktree's `git log --oneline -6` before continuing.)

- [ ] **Step 4B.3: No dependency changes — assert it.** The recipe's crates must already be
direct dependencies. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -n '^orchard\|^pasta_curves\|^ff \|^zip32\|^rand ' Cargo.toml; git diff --stat -- Cargo.toml Cargo.lock
```

Expected: five lines from the `grep` (`orchard`, `pasta_curves`, `ff`, `zip32`, `rand`), and
**no output at all** from `git diff --stat` — this task adds no dependency and must not touch
either manifest. If a crate is missing from `Cargo.toml`, **stop**: the transcription assumed
it, and adding a dependency is outside this task's scope. If a manifest diff appears, it came
from somewhere else — surface it rather than committing it here.

- [ ] **Step 4B.4: Rust format + compile gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check && set -o pipefail && cargo check 2>&1 | tee /tmp/chp-t4b-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, only the pre-existing `migration_plan_cache.rs:77` warning. A
`too_many_arguments` complaint cannot appear here (the gates run `cargo check`, not `cargo
clippy`, and no sibling FFI function in this crate carries an allow attribute for it — do not
add one).

- [ ] **Step 4B.5: Header-generation assert.** cbindgen writes the C header during the build, so
the new declaration must already be there. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -c 'zcashlc_voting_sign_delegation_request' target/Headers/zcashlc.h
```

Expected: `1`. If the file does not exist, run `cargo check` once more (the header is a
build-script side effect) and retry. `0` means the symbol did not export — report it and stop.

- [ ] **Step 4B.6: Rust test gate (count must not move).** This task adds no Rust unit tests, so
the voting suite's count must be exactly what Task 3's step 3.6 reported. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t4b-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `test result: ok. 72 passed; 0 failed` — the same 72 Task 3 gated on. A
different count means something other than this task changed the suite; surface it.

- [ ] **Step 4B.7: Add the Swift signature type.** Append to the end of
`Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift` (after the `VotingVoteConfirmation`
block Task 3 added):

```swift

// MARK: - Delegation signature (JSON)

/// A SpendAuth signature this wallet produced for one delegation bundle, with
/// the sighash it covers.
///
/// Both values go straight into
/// ``VotingRustBackend/getDelegationSubmission(roundId:bundleIndex:signature:sighash:)``.
/// The sighash is not informational: `zcash_voting` checks it against the one it
/// stored when the bundle's PCZT was set up and rejects the submission if they
/// disagree, so pass back the value that came out with the signature rather than
/// one recomputed elsewhere.
public struct VotingDelegationSignature: Codable, Sendable, Equatable {
    /// The 64-byte detached RedPallas SpendAuth signature.
    public let signature: [UInt8]
    /// The 32-byte ZIP-244 sighash the signature covers.
    public let sighash: [UInt8]

    enum CodingKeys: String, CodingKey {
        case signature = "sig"
        case sighash
    }
}
```

- [ ] **Step 4B.8: Add the `signDelegationRequest` wrapper.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`, inside the
`// MARK: - Delegation workflow` extension, replace:

```swift
    /// Get the delegation submission payload for an externally produced
    /// signature.
```

with:

```swift
    /// Sign one delegation bundle's PCZT sighash with this account's own Orchard
    /// SpendAuth key.
    ///
    /// `zcash_voting` 2.0 stopped deriving account keys and signing for its
    /// callers, and prescribes this replacement for software wallets: load the
    /// bundle's signing request (account index, network, seed fingerprint,
    /// sighash and spend-auth randomizer), derive the account SpendAuth key from
    /// the wallet seed, randomize it with the randomizer, and sign the sighash.
    /// All of that happens in Rust — the seed goes in, only the detached
    /// signature comes back out.
    ///
    /// This is the software counterpart of the Keystone flow: there, the device
    /// produces the signature and the app extracts it from the signed PCZT; here
    /// the wallet produces it itself. Both then call the same
    /// ``getDelegationSubmission(roundId:bundleIndex:signature:sighash:)``,
    /// which is the only remaining path into a submission payload.
    ///
    /// - Parameters:
    ///   - keys: the same ``VotingDelegationKeyInputs`` used to build and prove
    ///     this bundle. The crate loads the signing request through them, so a
    ///     different account index, hotkey secret or seed fingerprint fails
    ///     instead of silently signing for the wrong account.
    ///   - seed: the wallet's root seed, at least 32 bytes. It is borrowed for
    ///     the duration of this call, is never persisted or logged, and must be
    ///     the seed whose fingerprint is in `keys` — a mismatch throws rather
    ///     than producing a signature the chain would reject.
    /// - Returns: the detached 64-byte SpendAuth signature and the 32-byte
    ///   ZIP-244 sighash it covers. Pass both to `getDelegationSubmission`
    ///   unchanged.
    /// - Throws: ``VotingRustBackendError/databaseNotOpen`` if no database is
    ///   open; ``VotingRustBackendError/invalidData`` if `seed` or the seed
    ///   fingerprint is the wrong length; ``VotingRustBackendError/rustError``
    ///   if the bundle has no stored signing request yet (its PCZT setup has not
    ///   run), or the seed does not match the request.
    public func signDelegationRequest(
        roundId: String,
        bundleIndex: UInt32,
        keys: VotingDelegationKeyInputs,
        seed: [UInt8]
    ) throws -> VotingDelegationSignature {
        guard keys.seedFingerprint.count == votingSeedFingerprintByteCount else {
            throw VotingRustBackendError.invalidData(
                "seedFingerprint must be exactly \(votingSeedFingerprintByteCount) bytes"
            )
        }
        guard seed.count >= votingMinSeedByteCount else {
            throw VotingRustBackendError.invalidData(
                "seed must be at least \(votingMinSeedByteCount) bytes"
            )
        }

        let roundIdBytes = [UInt8](roundId.utf8)
        let roundNameBytes = [UInt8](keys.roundName.utf8)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice> = try withHandle { dbh in
            let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = roundIdBytes.withUnsafeBufferPointer { ridBuf in
                keys.fvk.withUnsafeBufferPointer { fvkBuf in
                    keys.hotkeyStoredSecret.withUnsafeBufferPointer { secretBuf in
                        keys.seedFingerprint.withUnsafeBufferPointer { fpBuf in
                            roundNameBytes.withUnsafeBufferPointer { nameBuf in
                                seed.withUnsafeBufferPointer { seedBuf in
                                    zcashlc_voting_sign_delegation_request(
                                        dbh,
                                        ridBuf.baseAddress,
                                        UInt(ridBuf.count),
                                        bundleIndex,
                                        fvkBuf.baseAddress,
                                        UInt(fvkBuf.count),
                                        secretBuf.baseAddress,
                                        UInt(secretBuf.count),
                                        fpBuf.baseAddress,
                                        UInt(fpBuf.count),
                                        keys.accountIndex,
                                        nameBuf.baseAddress,
                                        UInt(nameBuf.count),
                                        seedBuf.baseAddress,
                                        UInt(seedBuf.count)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            guard let ptr else {
                throw VotingRustBackendError.rustError(
                    lastErrorMessage(fallback: "`sign_delegation_request` failed")
                )
            }
            return ptr
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        return try decodeJSON(from: ptr)
    }

    /// Get the delegation submission payload for an externally produced
    /// signature.
```

The two methods are now adjacent and in call order — sign, then submit.

- [ ] **Step 4B.9: Add the offline test file.** Create
`Tests/OfflineTests/VotingSignDelegationRequestTests.swift` with exactly this content. It
follows the existing suite's DB-fixture pattern (`VotingRustBackendTests.swift`, and Task 3's
two files): a canonical 64-hex round id, a temp-path database opened per test and cleaned up in
`tearDown`, and assertions on the error surfaces an offline test can reach. The success path is
not testable offline — a signature requires a bundle whose PCZT setup ran against a real round,
so it belongs to the testnet E2E round.

```swift
//
//  VotingSignDelegationRequestTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// Builds a round identifier that satisfies the Rust round-parameter validation,
/// which requires 64 lowercase hex characters encoding a canonical Pallas field
/// element. `tag` occupies the low byte so each caller gets a distinct round.
private func signHexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

private let signWalletId = "test-wallet"
private let signNetworkId: UInt32 = 1
/// A well-formed round identifier that is never initialized, so the crate has no
/// stored signing request to answer with.
private let signMissingRoundId = signHexRoundId(0xfc)
/// Orchard FVK length. The value is never used as a key here: the crate reads
/// only the account index, seed fingerprint and network out of the delegation
/// keys when loading a signing request.
private let signFvk = [UInt8](repeating: 0, count: 96)
private let signSeedFingerprint = [UInt8](repeating: 7, count: 32)
private let signSeed = [UInt8](repeating: 9, count: 32)
private let signRoundName = "chp-offline"

final class VotingSignDelegationRequestTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
        super.tearDown()
    }

    func test_signDelegationRequest_shortSeed_throwsInvalidData() throws {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: [UInt8](repeating: 9, count: 31)
            )
        ) { error in
            guard case VotingRustBackendError.invalidData(let message) = error else {
                XCTFail("expected .invalidData, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("seed must be at least"),
                "unexpected message: \(message)"
            )
        }
    }

    func test_signDelegationRequest_beforeOpen_throwsDatabaseNotOpen() throws {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: signSeed
            )
        ) { error in
            guard case VotingRustBackendError.databaseNotOpen = error else {
                XCTFail("expected .databaseNotOpen, got \(error.localizedDescription)")
                return
            }
        }
    }

    func test_signDelegationRequest_afterOpen_missingRound_throwsRustError() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: signSeed
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("signing_request failed"),
                "unexpected message: \(message)"
            )
        }
    }

    // MARK: - Helpers

    /// A hotkey secret has to be real: the FFI reconstructs a `VotingHotkey`
    /// from it before it can build the delegation keys the signing request is
    /// loaded through. `generateHotkey` is static and needs no database.
    private func makeKeys() throws -> VotingDelegationKeyInputs {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: signNetworkId)
        return VotingDelegationKeyInputs(
            fvk: signFvk,
            hotkeyStoredSecret: hotkey.storedSecret,
            seedFingerprint: signSeedFingerprint,
            accountIndex: 0,
            roundName: signRoundName
        )
    }

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingSignDelegationRequestTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: signNetworkId)
        try backend.setWalletId(signWalletId)
        return backend
    }
}
```

This file runs at plan Task 6 (`swift test --filter OfflineTests`), after the FFI rebuild in
plan Task 5 puts the new symbol in the library. It cannot run before that.

- [ ] **Step 4B.10: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Added`, append
this bullet at the end of that section (immediately before the `## Changed` heading — after the
bullet Task 4 added):

```markdown
- `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` lets a software
  wallet produce the SpendAuth signature a delegation submission needs. `zcash_voting 2.0` no
  longer derives account keys or signs for its callers, which left
  `getDelegationSubmission(roundId:bundleIndex:signature:sighash:)` reachable only by hardware
  signers; this is the crate's own prescribed software path — it loads the bundle's signing
  request, derives the account Orchard SpendAuth key from the wallet seed, randomizes it with
  the request's spend-auth randomizer and signs the stored ZIP-244 sighash, returning the
  detached signature and that sighash as `VotingDelegationSignature`. The seed is borrowed for
  the call and never persisted, logged or handed to `zcash_voting`; the signature is checked
  against the seed fingerprint the bundle was built for, so signing with the wrong seed fails
  instead of producing a rejected transaction. Software and hardware delegation now converge on
  the same submission entry point.
```

- [ ] **Step 4B.11: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add rust/src/voting.rs rust/src/voting/signing.rs Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift Tests/OfflineTests/VotingSignDelegationRequestTests.swift CHANGELOG.md && git commit -m "[#1855] Add the software delegation-signing passthrough zcash_voting 2.0 prescribes" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: S6 — full FFI rebuild + symbol gate

*No code blocks (commands only) — orchestrator-authored.*

**Files:** creates `LocalPackages/` in the SDK worktree (untracked build artifact — do not
commit it).

- [ ] **Step 5.1: Full local-FFI build (all architectures).** The FFI boundary changed in
T1–T3, so per the SDK repo's own rules this must be the *full* script, not a single-arch
rebuild. Budget for the halo2 voting-circuits tax (Android's equivalent CI step went
30→60 min). Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; ./Scripts/init-local-ffi.sh 2>&1 | tee /tmp/chp-t5-ffi.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0` and `LocalPackages/` now exists. Non-zero → report the last 50 log
lines; do not proceed.

- [ ] **Step 5.2: Slice + symbol gate.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && FW=$(find LocalPackages -name 'libzcashlc' -path '*macos*' | head -1) && lipo -archs "$FW" && nm -gU "$FW" | grep -c 'zcashlc_voting_commit_vote\|zcashlc_voting_confirm_vote_submission\|zcashlc_voting_recover_wire_json\|zcashlc_voting_sign_delegation_request'
```

Expected: `lipo` prints the macOS slice arch(s); the grep count is **exactly 4** (the three
Task 3-era symbols plus Task 4B's `zcashlc_voting_sign_delegation_request`). Fewer → a T3 or
T4B symbol didn't export (check `nm -gU "$FW" | grep zcashlc_voting_` for what's actually
there and report); do not proceed. Repeat the `nm` gate for the ios-sim slice
(`-path '*simulator*'`), same expected 4.

- [ ] **Step 5.3: No commit.** This task produces build artifacts only. Verify:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git status --short | grep -v '^??' | head -3
```

Expected: empty (LocalPackages is untracked; nothing staged).

---

### Task 6: SDK gates — swift build + OfflineTests (gates 1–3 close)

*No code blocks (commands only) — orchestrator-authored.*

**Files:** none modified.

- [ ] **Step 6.1: Swift build.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; swift build 2>&1 | tee /tmp/chp-t6-build.log | tail -3; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`.

- [ ] **Step 6.2: OfflineTests.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; swift test --filter OfflineTests 2>&1 | tee /tmp/chp-t6-test.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, zero failures. Record the executed-test count in the report.

- [ ] **Step 6.3: Voting suite unmodified assert (spec S3 acceptance).** Two parts
(amended 2026-08-11: base moved to the re-base merge `f74f13b8`, and Task 4B's third new test
file joined the exclusion list). Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git diff f74f13b8 --stat -- Tests/ | grep -i voting | grep -v 'ConfirmVoteSubmission\|RecoverWireJson\|SignDelegationRequest'; echo "EXIT=$?"
```

Expected: `EXIT=1` (no hits) — pre-existing voting tests untouched. Then:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git diff f74f13b8 --stat -- Tests/ | grep -i voting | grep -c 'ConfirmVoteSubmission\|RecoverWireJson\|SignDelegationRequest'
```

Expected: `3` — exactly the T3 pair + T4B's signing test exist beyond the base. Any modified
pre-existing voting test file → deviation, surface it.

---

### Task 7: A7 — flag on (internal+testnet) = the enumeration gate

*Code blocks by: Sonnet (app delegate).*

**Files:**
- Modify: `secant.xcodeproj/project.pbxproj` (6 build configurations, exact UUIDs above)

**Interfaces:**
- Consumes: nothing (build-settings only).
- Produces: `/tmp/chp-t7-errors.txt` — the authoritative T8–T13 work list.

---

- [ ] **Step 7.1: Flip `zodl-testnet` Debug.** In `secant.xcodeproj/project.pbxproj`, in the
block `9E41FFB82CB2814500783CFD /* Debug */` (lines 873-901), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_TESTNET";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E41FFB92CB2814500783CFD /* Release-Testflight */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E41FFB92CB2814500783CFD /* Release-Testflight */ = {
```

(The trailing UUID line is included only so the match is unambiguous — it is not itself edited.)

- [ ] **Step 7.2: Flip `zodl-testnet` Release-Testflight.** In the same file, in the block
`9E41FFB92CB2814500783CFD /* Release-Testflight */` (lines 903-930), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_TESTNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E41FFBA2CB2814500783CFD /* Release-AppStore */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E41FFBA2CB2814500783CFD /* Release-AppStore */ = {
```

- [ ] **Step 7.3: Flip `zodl-testnet` Release-AppStore.** In the same file, in the block
`9E41FFBA2CB2814500783CFD /* Release-AppStore */` (lines 932-959), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_TESTNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
		9E4AB2B52BA1BEE900F5D6DB /* Debug */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_TESTNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
		9E4AB2B52BA1BEE900F5D6DB /* Debug */ = {
```

(The trailing UUID line here is `zodl-production`'s Debug block header — included only to prove
this edit stops before touching production, and is not itself modified.)

- [ ] **Step 7.4: Flip `zodl-internal` Debug.** In the same file, in the block
`9E5AB47F2C94777800065483 /* Debug */` (lines 1159-1187), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_MAINNET";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E5AB4802C94777800065483 /* Release-Testflight */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG UNREDACTED SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = NO;
			};
			name = Debug;
		};
		9E5AB4802C94777800065483 /* Release-Testflight */ = {
```

- [ ] **Step 7.5: Flip `zodl-internal` Release-Testflight.** In the same file, in the block
`9E5AB4802C94777800065483 /* Release-Testflight */` (lines 1189-1216), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_MAINNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E5AB4812C94777800065483 /* Release-AppStore */ = {
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-Testflight";
		};
		9E5AB4812C94777800065483 /* Release-AppStore */ = {
```

- [ ] **Step 7.6: Flip `zodl-internal` Release-AppStore.** In the same file, in the block
`9E5AB4812C94777800065483 /* Release-AppStore */` (lines 1218-1245), replace:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = SECANT_MAINNET;
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
/* End XCBuildConfiguration section */
```

with:

```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SECANT_MAINNET VOTING_ENABLED";
				TARGETED_DEVICE_FAMILY = 1;
				UPLOAD_CRASHLYTICS_SYMBOLS = YES;
			};
			name = "Release-AppStore";
		};
/* End XCBuildConfiguration section */
```

(The trailing marker comment is the literal end of the `XCBuildConfiguration` section in this
file — included to prove this is the last of the six edits.)

- [ ] **Step 7.7: Verify exactly 6 hits, and that `zodl-production` has none.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -c 'VOTING_ENABLED' secant.xcodeproj/project.pbxproj
```

Expected: `6`. Then run — three separate per-block checks, not one range scan: a single
`Debug`-to-`Release-AppStore` awk range is unsafe here because `9E4AB2BA2BA1C05100F5D6DB /*
Release-AppStore */` (line 1040) is a *different*, non-`zodl-production` block that happens to
share that name and sit right after `zodl-production`'s Release-Testflight config — a range
ending there stops around line 1040 and never reaches `zodl-production`'s own real
Release-AppStore block, `9E4AB2BF2BA1C05100F5D6DB` (lines 1120-1158). Every boundary UUID below
also has a *second*, harmless-looking occurrence later in the file, inside its target's own
`XCConfigurationList` `buildConfigurations = (...)` reference array (e.g.
`9E4AB2B52BA1BEE900F5D6DB /* Debug */,` around line 1283) — an `awk` range re-opens on any
repeat match of its start pattern, so a boundary without the trailing ` = {` silently re-fires
there and can leak a second, unwanted chunk into the count (verified empirically: it happens to
add 0 in this file today only because those reference lines never contain the literal string
`VOTING_ENABLED` — not something to rely on). Anchoring every boundary on the block-definition
form, `UUID /* Name */ = {`, makes it match only the one real block header:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios
awk '/9E4AB2B52BA1BEE900F5D6DB \/\* Debug \*\/ = \{/,/9E4AB2B62BA1BEE900F5D6DB \/\* Release-Testflight \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
awk '/9E4AB2B62BA1BEE900F5D6DB \/\* Release-Testflight \*\/ = \{/,/9E4AB2BA2BA1C05100F5D6DB \/\* Release-AppStore \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
awk '/9E4AB2BF2BA1C05100F5D6DB \/\* Release-AppStore \*\/ = \{/,/9E5AB47F2C94777800065483 \/\* Debug \*\/ = \{/' secant.xcodeproj/project.pbxproj | grep -c VOTING_ENABLED
```

Expected: `0`, `0`, `0` — one per real `zodl-production` config (Debug, Release-Testflight, and
its actual Release-AppStore block via `9E4AB2BF2BA1C05100F5D6DB`, each isolated by scanning to
the *next* real block-definition header — `zodl-internal`'s own Debug config, in the third
check — so no later block's settings can leak in). Verified directly against the post-T7 tree:
these three commands print `41`, `40`, `40` total lines respectively (matching each block's true
span exactly, with no re-triggered second chunk), and `0`, `0`, `0` for the `VOTING_ENABLED`
count. Any other count on any of the four checks (this trio plus the total-6 check above) → the
edits landed in the wrong block; revert and redo before proceeding.

- [ ] **Step 7.8: Full internal-scheme build, capturing the complete log.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t7-full.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: **`REAL_EXIT` non-zero** — this is the red-by-design step. A zero exit here is itself
a finding to surface (it would mean the flag flip alone didn't expose the six-item disposition
gap, contradicting every piece of evidence in this plan) — do not treat it as success without
reporting it first.

- [ ] **Step 7.9: Extract the authoritative error list.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -E '(error:|error [A-Z]+[0-9]+:)' /tmp/chp-t7-full.log | sort -u > /tmp/chp-t7-errors.txt; wc -l /tmp/chp-t7-errors.txt
```

Report the full contents of `/tmp/chp-t7-errors.txt` verbatim. Map every line to exactly one of:
Task 8 (the six-member disposition + the Keystone unification), Task 9 (the vote sequence +
`SharePayload`/transport reshape), Task 10 (hotkey container + `generateHotkey`/`buildVotingPczt`/
`buildAndProveDelegation`), Task 11 (the branch-ID literal), Task 12 (`pirLayout`), Task 13 (the
static-config URL — unlikely to be a compile error, but check), or the two explicit findings this
plan already carries forward from `## CORRECTIONS` items 4 and 6 (the software delegation-signing
gap; the hotkey-address encoding gap). **Any error that maps to none of these is a new finding —
surface it, do not silently fold it into an existing task's diff.**

- [ ] **Step 7.10: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant.xcodeproj/project.pbxproj && git commit -m "[MOB-1678] Enable VOTING_ENABLED for internal and testnet configurations" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: A1 — pipeline collapse (six members → `commitVote`) + the Keystone unification

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 3–5 and 14 first. This task closes: `buildVoteCommitment`,
`signCastVote`, `buildSharePayloads` (main-path call site only — the two recovery-path call
sites at `:2171`/`:3463` are Task 9's, since they are inseparable from the confirm/recover
rewrite), `encryptShares`, `decomposeWeight`, `storeVoteCommitmentBundle` (main-path call site
only — same reason for its other two sites), and the Keystone half of item 4's finding.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift:29` (step 8.0) and elsewhere (steps 8.1-8.4, 8.14)
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Verify (no edit expected): `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientTestKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:144-155` (step 8.0, database open), `:1875-1893` (main construction), `:2900` (Keystone submission), `:3557`/`:3591`-region (step 8.14, software signing)

**Interfaces:**
- Consumes: `VotingRustBackend.open(path: String, networkId: UInt32) throws` (`VotingRustBackend.swift:72`, real, unaffected by the SDK lane); `VotingRustBackend.commitVote(roundId:bundleIndex:hotkeyStoredSecret:proposalId:choice:numOptions:voteCommitmentTreePosition:vanWitness:singleShare:progress:) async throws -> VotingVoteCommit` and `VotingRustBackend.getDelegationSubmission(roundId:bundleIndex:signature:sighash:) throws -> VotingDelegationSubmission` (both real, current, unaffected by SDK-lane Tasks 1–4 — see `## VERIFICATION EVIDENCE`); `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` (SDK-lane Task 4B, step 8.14).
- Produces: `VotingCryptoClient.openDatabase(_ path: String, _ networkId: UInt32) async throws -> Void`; `VotingCryptoClient.commitVote(...) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature)`; `VotingCryptoClient.getDelegationSubmission(...)` re-typed to `(_ roundId: String, _ bundleIndex: UInt32, _ signature: Data, _ sighash: Data) async throws -> DelegationRegistration`, consumed by plan Task 9 (the confirm/recover rewrite) and by Task 8's own Keystone call-site fix; `VotingCryptoClient.signDelegationRequest(...)` (step 8.14).

---

- [ ] **Step 8.0: Thread `networkId` through the voting-database open call.** T7's red-build
enumeration surfaced a compile error no other step in this plan (or in `CHP_DESIGN.md` §3's
A1-A6 list) covers: `VotingCryptoClientLiveKey.swift`'s `DatabaseActor.open` calls
`b.open(path: path)`, but the real SDK signature is `open(path: String, networkId: UInt32)
throws` (`VotingRustBackend.swift:72` in the SDK worktree — this function is outside every
`Files:` list in the SDK lane's Tasks 1-4B, so it was never touched; the mismatch predates this
campaign). The app-level `openDatabase` member never carried a `networkId` parameter either.
Verify both anchors first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "func open(path: String) throws" secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
grep -n "public func open(path" ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift
```

Expected: one hit each — `DatabaseActor.open`'s old 1-arg signature in the app, and the real
2-arg `open(path:networkId:)` in the SDK. Then locate the one call site:

```bash
grep -n "votingCrypto.openDatabase" secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

Expected: exactly one hit, `:155`, inside the `.serviceConfigLoaded` reducer case — the only
place the app opens the voting database. `networkId` is sourced the same way every other
`VotingCryptoClient` member in this file already does it (5 sites: `:808-810`, `:1725-1726`,
`:2037-2038`, `:2594-2595`, `:2804-2805`) — `zcashSDKEnvironment.network().networkType.
votingRustNetworkId` — not invented here.

First, the interface. In `VotingCryptoClientInterface.swift`, replace:

```swift
    // --- Database lifecycle ---
    var openDatabase: @Sendable (_ path: String) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
```

with:

```swift
    // --- Database lifecycle ---
    var openDatabase: @Sendable (_ path: String, _ networkId: UInt32) async throws -> Void
    var setWalletId: @Sendable (_ walletId: String) async throws -> Void
```

Second, the `LiveKey` closure. In `VotingCryptoClientLiveKey.swift`, replace:

```swift
            openDatabase: { path in
                try await dbActor.open(path: path)
            },
```

with:

```swift
            openDatabase: { path, networkId in
                try await dbActor.open(path: path, networkId: networkId)
            },
```

Third, `DatabaseActor` itself. In the same file, replace:

```swift
    func open(path: String) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path)
        _backend = b
    }
```

with:

```swift
    func open(path: String, networkId: UInt32) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path, networkId: networkId)
        _backend = b
    }
```

Fourth, the one call site. In `VotingCoordFlowCoordinator.swift`, replace:

```swift
            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                return .run { [votingAPI, votingCrypto] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath)
                    try await votingCrypto.setWalletId(walletId)
```

with:

```swift
            case .serviceConfigLoaded(let config):
                state.serviceConfig = config
                let walletId = state.walletId
                let network = zcashSDKEnvironment.network()
                let networkId: UInt32 = network.networkType.votingRustNetworkId
                return .run { [votingAPI, votingCrypto, networkId] send in
                    // 1. Configure API client URLs from the loaded config.
                    await votingAPI.configureURLs(config)

                    // 2. Open the voting DB and scope it to this wallet.
                    let dbPath = FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("voting.sqlite3").path
                    try await votingCrypto.openDatabase(dbPath, networkId)
                    try await votingCrypto.setWalletId(walletId)
```

`zcashSDKEnvironment.network()` / `.networkType.votingRustNetworkId` is the exact two-line idiom
already used at the five sites listed above — reused here, not invented — and it must be
computed in the reducer's synchronous body (before `.run`, as shown), then added to the
closure's explicit capture list, the same pattern every other `.run` site in this file already
follows for values it needs from outside the closure.

Finally, confirm this was the only call site (so no second one was missed):

```bash
grep -rn '\.openDatabase(' secant/Sources/ zodlTests/
```

Expected: exactly one hit, the now-two-argument call inside `.serviceConfigLoaded` above. Any
other hit — including in a test file — is a second call site this step must also fix before
proceeding to step 8.1.

- [ ] **Step 8.1: Delete `decomposeWeight` and `encryptShares` from the interface.** In
`VotingCryptoClientInterface.swift`, delete these two members (lines 125-129):

```swift
    var decomposeWeight: @Sendable (_ weight: UInt64) -> [UInt64] = { _ in [] }
    var encryptShares: @Sendable (
        _ roundId: String,
        _ shares: [UInt64]
    ) async throws -> [EncryptedShare]
```

Grep evidence both are zero-consumer in the coordinator: `## VERIFICATION EVIDENCE`, "Member
reference counts" table.

- [ ] **Step 8.2: Delete `buildVoteCommitment` and `signCastVote`, add `commitVote`.** In the
same file, replace:

```swift
    var buildVoteCommitment: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ anchorHeight: UInt32,
        _ singleShare: Bool
    ) -> AsyncThrowingStream<VoteCommitmentBuildEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    var buildSharePayloads: @Sendable (
        _ encShares: [EncryptedShare],
        _ commitment: VoteCommitmentBundle,
        _ voteDecision: VoteChoice,
        _ numOptions: UInt32,
        _ vcTreePosition: UInt64,
        _ singleShare: Bool
    ) async throws -> [SharePayload]
```

with:

```swift
    /// Build, sign, and persist the cast-vote commitment for one proposal in a single call.
    /// Replaces the former three-member sequence — build the commitment, sign the cast vote,
    /// build the share payloads — because `zcash_voting` now owns that orchestration
    /// internally and the intermediate artifacts are no longer separable steps.
    ///
    /// `voteCommitmentTreePosition` must be `0` for the provisional call in the sanctioned
    /// sequence (plan Task 9, spec `CHP_DESIGN.md` §3/A2 step 1) — the true position is not
    /// known until the cast-vote transaction confirms on chain. The call is idempotent:
    /// repeating it for the same (round, bundle, proposal) returns the persisted recovery
    /// bundle rather than re-proving.
    ///
    /// `hotkeyStoredSecret` is the voting hotkey's stored secret bytes (plan Task 10), not a
    /// derived seed. The returned pair feeds `VotingAPIClient.submitVoteCommitment(bundle:
    /// signature:)` verbatim — `bundle.sharesHash` is populated empty; `submitVoteCommitment`'s
    /// wire-body construction never reads it (verified: `VotingAPIClientLiveKey.swift:912-933`).
    // swiftlint:disable:next function_parameter_count
    var commitVote: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ hotkeyStoredSecret: [UInt8],
        _ proposalId: UInt32,
        _ choice: VoteChoice,
        _ numOptions: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ vanAuthPath: [Data],
        _ vanPosition: UInt32,
        _ vanAnchorHeight: UInt32,
        _ singleShare: Bool
    ) async throws -> (bundle: VoteCommitmentBundle, signature: CastVoteSignature)
```

Also delete the now-orphaned `signCastVote` member (currently between `resetTreeClient` and
`extractNcRoot`):

```swift
    /// Decompress r_vpk and sign the canonical cast-vote sighash.
    /// Call after `buildVoteCommitment` completes, before `submitVoteCommitment`.
    var signCastVote: @Sendable (
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ bundle: VoteCommitmentBundle
    ) async throws -> CastVoteSignature
```

with nothing (delete the four lines and the one blank line that follows them, leaving exactly
one blank line before `/// Extract the Orchard nc_root from a protobuf-encoded TreeState.`).

- [ ] **Step 8.3: Delete `storeVoteCommitmentBundle`.** In the same file, delete (lines 224-232):

```swift
    /// Persist the vote commitment bundle + VC tree position before TX submission.
    /// Required for share delegation if the app crashes between TX confirm and share send.
    var storeVoteCommitmentBundle: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ bundle: VoteCommitmentBundle,
        _ vcTreePosition: UInt64
    ) async throws -> Void
```

- [ ] **Step 8.4: Unify `getDelegationSubmission` and delete `getDelegationSubmissionWithKeystoneSig`.**
In the same file, replace:

```swift
    /// Reconstruct the full chain-ready delegation TX payload from DB + seed.
    /// Call after `buildAndProveDelegation` completes.
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32
    ) async throws -> DelegationRegistration
    /// Reconstruct the delegation TX payload using a Keystone-provided signature.
    /// Uses the externally-provided signature and ZIP-244 sighash instead of
    /// deriving `ask` from seed.
    var getDelegationSubmissionWithKeystoneSig: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ keystoneSig: Data,
        _ keystoneSighash: Data
    ) async throws -> DelegationRegistration
```

with:

```swift
    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash. `zcash_voting` no longer derives account keys
    /// or signs on the caller's behalf, so an externally-produced signature is the only
    /// remaining path — this one member now serves both the Keystone-signed call site
    /// (`VotingCoordFlowCoordinator.swift:2900`, signature off the scanned QR) and the
    /// software-signed call sites (`:3557`, `:3591` — see this task's step 8.10 finding for
    /// their unresolved signature source).
    var getDelegationSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ signature: Data,
        _ sighash: Data
    ) async throws -> DelegationRegistration
```

- [ ] **Step 8.5: Add the `malformedWireShare` error case the new `commitVote` implementation
needs.** This is prepared here so step 8.6 compiles; `VotingCryptoError` lives in
`VotingCryptoClientLiveKey.swift`, edited next.

---

- [ ] **Step 8.6: Delete `decomposeWeight`/`encryptShares`/`buildVoteCommitment`/
`signCastVote`/`buildSharePayloads`, add `commitVote`, in the LiveKey.** In
`VotingCryptoClientLiveKey.swift`, replace (lines 337-484 — from the `decomposeWeight` closure
through the end of the `buildSharePayloads` closure):

```swift
            decomposeWeight: { weight in
                (try? VotingRustBackend.decomposeWeight(weight)) ?? []
            },
            encryptShares: { roundId, shares in
                let backend = try await dbActor.backend()
                let wireShares: [VotingWireEncryptedShare] = try backend.encryptShares(
                    roundId: roundId,
                    shares: shares
                )
                return wireShares.map { (share: VotingWireEncryptedShare) -> EncryptedShare in
                    EncryptedShare(
                        c1: Data(share.ciphertext1),
                        c2: Data(share.ciphertext2),
                        shareIndex: share.shareIndex
                    )
                }
            },
            // swiftlint:disable:next line_length
            buildVoteCommitment: { roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice, numOptions, vanAuthPath, vanPosition, anchorHeight, singleShare in
                AsyncThrowingStream<VoteCommitmentBuildEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let vanWitness = try VotingVanWitness.make(
                                authPath: vanAuthPath.map { [UInt8]($0) },
                                position: vanPosition,
                                anchorHeight: anchorHeight
                            )
                            let result = try await backend.buildVoteCommitment(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                proposalId: proposalId,
                                choice: choice.ffiValue,
                                numOptions: numOptions,
                                vanWitness: vanWitness,
                                singleShare: singleShare,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            publishState(backend: backend, roundId: roundId)
                            let vanNullifier: Data = Data(result.vanNullifier)
                            let voteAuthorityNoteNew: Data = Data(result.voteAuthorityNoteNew)
                            let voteCommitment: Data = Data(result.voteCommitment)
                            let proof: Data = Data(result.proof)
                            let sharesHash: Data = Data(result.sharesHash)
                            let rVpkBytes: Data = Data(result.rVpkBytes)
                            let alphaV: Data = Data(result.alphaV)
                            let encShares: [EncryptedShare] = result.encShares.map { share in
                                EncryptedShare(
                                    c1: Data(share.ciphertext1),
                                    c2: Data(share.ciphertext2),
                                    shareIndex: share.shareIndex
                                )
                            }
                            let shareBlindFactors: [Data] = result.shareBlinds.map { Data($0) }
                            let shareComms: [Data] = result.shareComms.map { Data($0) }
                            let bundle = VoteCommitmentBundle(
                                vanNullifier: vanNullifier,
                                voteAuthorityNoteNew: voteAuthorityNoteNew,
                                voteCommitment: voteCommitment,
                                proposalId: proposalId,
                                proof: proof,
                                encShares: encShares,
                                anchorHeight: result.anchorHeight,
                                voteRoundId: result.voteRoundId,
                                sharesHash: sharesHash,
                                shareBlindFactors: shareBlindFactors,
                                shareComms: shareComms,
                                rVpkBytes: rVpkBytes,
                                alphaV: alphaV
                            )
                            continuation.yield(.completed(bundle))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
            buildSharePayloads: { encShares, commitment, voteDecision, numOptions, vcTreePosition, singleShare in
                let backend = try await dbActor.backend()
                let sdkShares = encShares.map {
                    VotingWireEncryptedShare(
                        ciphertext1: [UInt8]($0.c1),
                        ciphertext2: [UInt8]($0.c2),
                        shareIndex: $0.shareIndex
                    )
                }
                let vanNullifier: [UInt8] = [UInt8](commitment.vanNullifier)
                let voteAuthorityNoteNew: [UInt8] = [UInt8](commitment.voteAuthorityNoteNew)
                let voteCommitment: [UInt8] = [UInt8](commitment.voteCommitment)
                let proof: [UInt8] = [UInt8](commitment.proof)
                let sharesHash: [UInt8] = [UInt8](commitment.sharesHash)
                let shareBlinds: [[UInt8]] = commitment.shareBlindFactors.map { [UInt8]($0) }
                let shareComms: [[UInt8]] = commitment.shareComms.map { [UInt8]($0) }
                let rVpkBytes: [UInt8] = [UInt8](commitment.rVpkBytes)
                let alphaV: [UInt8] = [UInt8](commitment.alphaV)
                let sdkCommitment = VotingVoteCommitmentBundle(
                    vanNullifier: vanNullifier,
                    voteAuthorityNoteNew: voteAuthorityNoteNew,
                    voteCommitment: voteCommitment,
                    proposalId: commitment.proposalId,
                    proof: proof,
                    encShares: sdkShares,
                    anchorHeight: commitment.anchorHeight,
                    voteRoundId: commitment.voteRoundId,
                    sharesHash: sharesHash,
                    shareBlinds: shareBlinds,
                    shareComms: shareComms,
                    rVpkBytes: rVpkBytes,
                    alphaV: alphaV
                )
                let payloads = try backend.buildSharePayloads(
                    commitment: sdkCommitment,
                    voteDecision: voteDecision.ffiValue,
                    numOptions: numOptions,
                    voteCommitmentTreePosition: vcTreePosition,
                    singleShare: singleShare
                )
                return payloads.map { payload in
                    let encShare = EncryptedShare(
                        c1: Data(payload.encShare.ciphertext1),
                        c2: Data(payload.encShare.ciphertext2),
                        shareIndex: payload.encShare.shareIndex
                    )
                    let allEncShares = payload.allEncShares.map { wire in
                        EncryptedShare(
                            c1: Data(wire.ciphertext1),
                            c2: Data(wire.ciphertext2),
                            shareIndex: wire.shareIndex
                        )
                    }
                    let shareComms = payload.shareComms.map { Data($0) }
                    return SharePayload(
                        sharesHash: Data(payload.sharesHash),
                        proposalId: payload.proposalId,
                        voteDecision: payload.voteDecision,
                        encShare: encShare,
                        treePosition: payload.treePosition,
                        allEncShares: allEncShares,
                        shareComms: shareComms,
                        primaryBlind: Data(payload.primaryBlind)
                    )
                }
            },
```

with:

```swift
            // swiftlint:disable:next function_parameter_count
            commitVote: { roundId, bundleIndex, hotkeyStoredSecret, proposalId, choice, numOptions, voteCommitmentTreePosition, vanAuthPath, vanPosition, vanAnchorHeight, singleShare in
                let backend = try await dbActor.backend()
                let vanWitness = try VotingVanWitness.make(
                    authPath: vanAuthPath.map { [UInt8]($0) },
                    position: vanPosition,
                    anchorHeight: vanAnchorHeight
                )
                let result = try await backend.commitVote(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    proposalId: proposalId,
                    choice: choice.ffiValue,
                    numOptions: numOptions,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    vanWitness: vanWitness,
                    singleShare: singleShare
                )
                publishState(backend: backend, roundId: roundId)
                let encShares: [EncryptedShare] = try result.encShares.map { share in
                    guard
                        let c1 = Data(base64Encoded: share.ciphertext1),
                        let c2 = Data(base64Encoded: share.ciphertext2)
                    else {
                        throw VotingCryptoError.malformedWireShare(share.shareIndex)
                    }
                    return EncryptedShare(c1: c1, c2: c2, shareIndex: share.shareIndex)
                }
                let bundle = VoteCommitmentBundle(
                    vanNullifier: Data(result.vanNullifier),
                    voteAuthorityNoteNew: Data(result.voteAuthorityNoteNew),
                    voteCommitment: Data(result.voteCommitment),
                    proposalId: result.proposalId,
                    proof: Data(result.proof),
                    encShares: encShares,
                    anchorHeight: result.anchorHeight,
                    voteRoundId: roundId,
                    sharesHash: Data(),
                    rVpkBytes: Data(result.voteKeyRandomizer)
                )
                let signature = CastVoteSignature(voteAuthSig: Data(result.voteAuthSig))
                return (bundle, signature)
            },
```

`VotingVoteCommit.encShares` (`VotingWireEncryptedShare`) is base64-`String` post SDK-lane
Task 2 (`## VERIFICATION EVIDENCE`'s SDK-signatures block); `voteRoundId` comes from the
already-in-scope `roundId` parameter because the commit result carries no round id of its own
(the crate's wire type never needed one — it is not itself submitted).

- [ ] **Step 8.7: Add the `malformedWireShare` error case.** In the same file, in the
`VotingCryptoError` enum, replace:

```swift
enum VotingCryptoError: LocalizedError {
    case proofFailed(String)
    case databaseNotOpen
    case hotkeySeedBindingMismatch
    case invalidSpendAuthSignatureLength(Int)
    case invalidKeystoneMetadata

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        }
    }
}
```

with:

```swift
enum VotingCryptoError: LocalizedError {
    case proofFailed(String)
    case databaseNotOpen
    case hotkeySeedBindingMismatch
    case invalidSpendAuthSignatureLength(Int)
    case invalidKeystoneMetadata
    case malformedWireShare(UInt32)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        }
    }
}
```

- [ ] **Step 8.8: Delete the `storeVoteCommitmentBundle` implementation.** In the same file,
delete (currently between `resetTreeClient` and `extractNcRoot` — verify against the file at
edit time since step 8.6 shifted line numbers upstream):

```swift
            signCastVote: { hotkeySeed, networkId, bundle in
                let sig = try VotingRustBackend.signCastVote(
                    hotkeySeed: hotkeySeed,
                    networkId: networkId,
                    commitment: bundle.toSDK()
                )
                return CastVoteSignature(
                    voteAuthSig: Data(sig.voteAuthSig)
                )
            },
```

(replace with nothing — `signCastVote` is fully absorbed into `commitVote`), and delete
(currently between `getVoteTxHash` and `getVoteCommitmentBundle`):

```swift
            storeVoteCommitmentBundle: { roundId, bundleIndex, proposalId, bundle, vcTreePosition in
                let backend = try await dbActor.backend()
                let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? "{}"
                try backend.storeCommitmentBundle(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    bundleJson: json,
                    voteCommitmentTreePosition: vcTreePosition
                )
            },
```

(replace with nothing — persistence is internal to `commitVote` now).

- [ ] **Step 8.9: Unify the `getDelegationSubmission` implementation.** In the same file,
replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, senderSeed, networkId, accountIndex in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    senderSeed: senderSeed,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
            getDelegationSubmissionWithKeystoneSig: { roundId, bundleIndex, keystoneSig, keystoneSighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keystoneSig: [UInt8](keystoneSig),
                    sighash: [UInt8](keystoneSighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
```

with:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighashOut: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighashOut
                )
            },
```

- [ ] **Step 8.10: Verify `VotingCryptoClientTestKey.swift` needs no edit.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && cat secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientTestKey.swift
```

Expected: exactly the 8-line file quoted in `## CORRECTIONS` item 2 (`static let testValue =
Self()`, no explicit member overrides). If the file differs from that (a member override was
added since this plan was written), that is a deviation — surface it and adapt the override to
the new signatures; do not silently skip it.

- [ ] **Step 8.11: Rewire the main-path construction.** In
`VotingCoordFlowCoordinator.swift`, replace:

```swift
                        var builtBundle: VoteCommitmentBundle?
                        for try await event in votingCrypto.buildVoteCommitment(
                            roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice,
                            numOptions, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                        ) {
                            if case .completed(let bundle) = event {
                                builtBundle = bundle
                            }
                        }
                        guard let builtBundle else {
                            throw VotingFlowError.missingVoteCommitmentBundle
                        }

                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, 0)

                        let castVoteSig = try await votingCrypto.signCastVote(hotkeySeed, networkId, builtBundle)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)
```

with:

```swift
                        let (builtBundle, castVoteSig) = try await votingCrypto.commitVote(
                            roundId, bundleIndex, hotkeySeed, proposalId, choice,
                            numOptions, 0, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                        )

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .confirming))
                        let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                        try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)
```

`hotkeySeed` is still the pre-Task-10 mnemonic-derived value at this point in the ladder — it
occupies the same positional slot `commitVote`'s `hotkeyStoredSecret:` parameter expects, and
plan Task 10 is what changes *what value* is passed here, not this call's shape. The `0` is the
provisional `voteCommitmentTreePosition` (spec `CHP_DESIGN.md` §3/A2 step 1). Everything from
`await send(.voteSubmissionStepUpdated(...step: .confirming))` onward through the rest of the
enclosing loop (the confirmation poll, `leaf_index` parse, `buildSharePayloads` call, the
second `storeVoteCommitmentBundle` call, and `markVoteSubmitted`) is **left exactly as it stands
today** — those lines are Task 9's, which needs this task's diff as its own "before" state.

- [ ] **Step 8.12: Rewire the Keystone submission call site.** In the same file, replace:

```swift
                    let registration = try await votingCrypto.getDelegationSubmissionWithKeystoneSig(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
```

with:

```swift
                    let registration = try await votingCrypto.getDelegationSubmission(
                        roundId, bundleIdx, sig.sig, sig.sighash
                    )
```

`sig` is a `KeystoneBundleSignature` whose `.sig`/`.sighash` are already `Data` (populated from
`extractSpendAuthSignatureFromSignedPczt`/`extractPcztSighash`, both `throws -> Data`) — the
positional call shape is unchanged, only the member name changes.

- [ ] **Step 8.13: Compile-progress evidence gate (partial — by design).** Run the build first,
judged on its own real exit code — do not pipe it into `grep -c` (that would make the exit code
of a match-counting command stand in for the compiler's, which silently reports failure at the
goal state of zero errors; Global Constraint #4 forbids judging by grep):

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t8-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero (red-by-design continues through T13) — `set -o pipefail`
propagates `xcodebuild`'s own exit code through `tee`/`tail` unchanged, the same idiom Step 7.8
already uses. Then, as a separate, second command, count the errors — this command's exit
status is never judged (`grep -c` exits 1 at a count of zero, which is not a failure here, so
`|| true` neutralizes it; only the printed number is read):

```bash
grep -c 'error:' /tmp/chp-t8-build.log || true
```

Expected: a number, **strictly less** than `wc -l /tmp/chp-t7-errors.txt`. Grep the log for
`buildVoteCommitment\|signCastVote\|encryptShares\|decomposeWeight\|
getDelegationSubmissionWithKeystoneSig` — these five must **not** appear anywhere in the new
log. `buildSharePayloads` and `storeVoteCommitmentBundle` **are** expected to still appear
(the `:1937`, `:2171`, `:3460`/`:3463` call sites this task deliberately left standing) — that
is Task 9's targeted work, not a regression here.

- [ ] **Step 8.14: Wire the software delegation path to the new signing wrapper.**
`VotingCoordFlowCoordinator.swift` calls `votingCrypto.getDelegationSubmission(roundId,
bundleIndex, senderSeed, networkId, accountIndex)` twice inside `static func
runDelegationPipeline` — once as a "is it already cached?" probe (near `:3557`) and once for
real after proving (near `:3591`). Both become a two-call chain: sign, then submit. Locate them
by the quoted context, not by line number.

First, add the client member. In `VotingCryptoClientInterface.swift`, replace:

```swift
    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

with:

```swift
    /// Produce this wallet's own SpendAuth signature for one delegation bundle.
    /// The software counterpart of the Keystone QR round-trip: `zcash_voting` 2.0 no longer
    /// derives account keys or signs for its callers, and prescribes exactly this instead —
    /// load the bundle's signing request, derive the account SpendAuth key from the seed,
    /// randomize it with the request's randomizer, sign the request's sighash. All of it
    /// happens inside the SDK; the seed goes in, only the detached signature comes back.
    /// Feed the result straight into `getDelegationSubmission`.
    var signDelegationRequest: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String
    ) async throws -> (signature: Data, sighash: Data)

    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

(The anchor is the first two lines of the doc comment step 8.4 wrote; the new member goes
immediately above it. `VotingCryptoClientTestKey.swift` still needs no edit — `@DependencyClient`
synthesizes the unimplemented default, per `## CORRECTIONS` item 2.)

Second, implement it. In `VotingCryptoClientLiveKey.swift`, replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

with:

```swift
            signDelegationRequest: { roundId, bundleIndex, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName in
                let backend = try await dbActor.backend()
                // Same derivation the software branch of `buildVotingPczt` uses: the sender's
                // Orchard FVK and ZIP-32 seed fingerprint come from the seed itself, so the
                // delegation keys here are byte-identical to the ones that built the PCZT.
                let inputs = try VotingRustBackend.generateDelegationInputs(
                    senderSeed: senderSeed,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let signed = try backend.signDelegationRequest(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keys: VotingDelegationKeyInputs(
                        fvk: inputs.fvkBytes,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        seedFingerprint: inputs.seedFingerprint,
                        accountIndex: accountIndex,
                        roundName: roundName
                    ),
                    seed: senderSeed
                )
                return (signature: Data(signed.signature), sighash: Data(signed.sighash))
            },
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

Third, rewire the cached-submission probe. In `VotingCoordFlowCoordinator.swift`, replace:

```swift
            let registration: DelegationRegistration
            if let cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                roundId, bundleIndex, senderSeed, networkId, accountIndex
            ) {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

with:

```swift
            let registration: DelegationRegistration
            // The cache probe is now two calls: signing succeeds once the bundle's PCZT setup
            // is stored, and the submission only assembles once its proof is too. Either one
            // failing means this bundle is not finished yet, so fall through and build it.
            let cachedSignature = try? await votingCrypto.signDelegationRequest(
                roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
            )
            let cachedRegistration: DelegationRegistration?
            if let cachedSignature {
                cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, cachedSignature.signature, cachedSignature.sighash
                )
            } else {
                cachedRegistration = nil
            }

            if let cachedRegistration {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

Fourth, rewire the post-proving call. In the same function, replace:

```swift
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, senderSeed, networkId, accountIndex
                )
```

with:

```swift
                let signed = try await votingCrypto.signDelegationRequest(
                    roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
                )
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, signed.signature, signed.sighash
                )
```

`hotkeySeed` and `roundName` are both `runDelegationPipeline` parameters already in scope at
both sites, so nothing new is threaded through the coordinator. The `hotkeySeed` local keeps
its name and starts carrying the hotkey **stored secret** at Task 10 step 10.14, exactly as it
does for the neighbouring `buildVotingPczt` / `buildAndProveDelegation` calls in this same
function — which is why the new member's parameter is named `hotkeyStoredSecret` from the
start. Task 10 needs no amendment for this member.

`runDelegationPipeline` already carries
`// swiftlint:disable:next function_body_length function_parameter_count`, which covers the
handful of lines this step adds.

**Reporting:** record in the T8 report that the F1 STOP finding is closed by plan Task 4B (SDK
commit `[#1855] Add the software delegation-signing passthrough zcash_voting 2.0 prescribes`),
and that `:3557`/`:3591` are now expected to compile. If Task 4B's commit is not present in the
SDK worktree (`git log --oneline -8` there), **stop** — do not hand-roll signing code in the
app; that would put key derivation in the wrong layer and is forbidden by §0.2.

- [ ] **Step 8.15: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Collapse the six-member vote pipeline into commitVote and unify getDelegationSubmission" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: A2 — the six-step vote sequence

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 7, 11, 12 first, and this task's step 9.9 note on
`recordShareDelegation` (a fourth, related SDK-signature change discovered while wiring this
sequence — the crate now derives the share nullifier internally instead of taking it as an
argument, which is *good* news: it removes rather than adds a gap). This task assumes Task 8
landed — it starts from the "after" state of Task 8's step 8.11.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Dependencies/VotingModels/VotingModels.swift` (`SharePayload`, `DelegationRegistration`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (`sharePostBody`, `submitDelegation`)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:1892-1966` (main path), `:2151-2210` (share-status-poll resubmission), `:3419-3505` (`tryRecoverInflightVote`)
- Modify: `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift` (step 9.0a's `makeDelegationRegistration` fixture — a third `DelegationRegistration(...)` call site found beyond the two Task 8/14 already knew about)

**Interfaces:**
- Consumes (from SDK-lane `## INTERFACES-FOR-APP`, not yet in the tree — this task's build gate
  runs after plan Task 6): `VotingRustBackend.confirmVoteSubmission(roundId:bundleIndex:
  proposalId:txHash:eventsJson:) throws -> VotingVoteConfirmation` and
  `VotingRustBackend.recoverWireJson(commitmentBundleJson:proposalId:shareIndex:
  voteCommitmentTreePosition:submitAt:) throws -> String` (static). Consumes the real, current
  `VotingRustBackend.recordShareDelegation(roundId:bundleIndex:proposalId:shareIndex:
  sentToURLs:submitAt:) throws` (`## VERIFICATION EVIDENCE` — 6 args, no nullifier; unaffected
  by SDK-lane Tasks 1–4). Consumes the real, current `VotingDelegationSubmission`
  (`VotingTypes.swift:281-296` in the SDK worktree — all-`String`/base64, **no** `sighash`
  field; step 9.0a).
- Produces: `VotingCryptoClient.confirmVoteSubmission(...)`,
  `.getCommitmentBundleJson(...) -> (bundleJson: String, vcTreePosition: UInt64)?`,
  `.recoverWireJson(...) -> String`; re-typed `.markVoteSubmitted(...txHash:)` and
  `.recordShareDelegation(...)` (nullifier dropped); `SharePayload` re-typed to
  `{ wireJson: String, shareIndex: UInt32 }`; `DelegationRegistration` re-typed (step 9.0a):
  `signedNoteNullifier`/`cmxNew`/`vanCmx`/`proof` become `String`, `govNullifiers` becomes
  `[String]`, `rk`/`spendAuthSig`/`sighash`/`voteRoundId` stay `Data`.

---

- [ ] **Step 9.0a: Fix step 8.9's wire-type drift in `getDelegationSubmission`.** Step 8.9's
`LiveKey` closure was written against the pre-SDK-lane-Task-2 shape of `VotingDelegationSubmission`
(all `[UInt8]`, plus a `sighash` field) — the real, post-Task-2 type is all-`String`/base64 and
has **no** `sighash` field at all (`## VERIFICATION EVIDENCE`'s SDK-signatures block already
quoted its doc comment: *"the legacy `sighash` field is gone from the wire. The signer's
sighash still exists; it simply never belonged in the submission body, because the server
derives the signing digest itself."*). The live error is
`VotingCryptoClientLiveKey.swift:415: missing argument label 'hexString:' in call` — `Data(sub.
randomizedKey)` resolves against this file's own `Data(hexString:)` extension instead of a
byte-array initializer, because `sub.randomizedKey` is now a `String`. Verify first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && sed -n '406,434p' secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
grep -n "public struct VotingDelegationSubmission" -A16 ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift
```

Expected: the closure shown below (unchanged from what step 8.9 landed) and the SDK struct with
all-`String` fields and no `sighash`.

**Consumer verdict** (per §2.0's no-reshaping rule — keep the crate's base64 strings end-to-end
wherever the consumer permits, decode to `Data` only where a genuine byte-level need exists).
`DelegationRegistration`'s only two consumers are the wire-body builder
(`VotingAPIClientLiveKey.swift`'s `submitDelegation`, which currently calls
`.base64EncodedString()` on every field — i.e. it already wants base64 text, so handing it the
SDK's base64 strings directly instead of decode-then-reencode is strictly more correct, not
less) and the Keystone signature check
(`VotingCoordFlowCoordinator.swift:2893-2895`: `registration.rk != sig.rk`,
`.spendAuthSig != sig.sig`, `.sighash != sig.sighash`, each against a `Data` from
`KeystoneBundleSignature`). That second site is the *only* genuine byte-level requirement in
the app — so `rk`, `spendAuthSig`, and `sighash` stay `Data`; `signedNoteNullifier`, `cmxNew`,
`vanCmx`, `govNullifiers`, and `proof` (wire-only, never compared) become the SDK's base64
`String`s verbatim. `voteRoundId` is untouched either way: it was never base64 — `sub.
voteRoundId` is the round's *hex* id in both SDK generations, and line 414's `Data(hexString:
sub.voteRoundId)` already converts it correctly; that line does not appear in either diff below.
`sighash` itself never came from `sub` at all going forward — the crate stopped returning one,
and correctly so: the closure's own `sighash` parameter (supplied by the caller, already `Data`)
is the only sighash that ever existed for this call.

First, re-type the model. In `secant/Sources/Dependencies/VotingModels/VotingModels.swift`,
replace:

```swift
struct DelegationRegistration: Equatable, Sendable {
    let rk: Data // swiftlint:disable:this identifier_name
    let spendAuthSig: Data
    let signedNoteNullifier: Data
    let cmxNew: Data
    let vanCmx: Data
    let govNullifiers: [Data]
    let proof: Data
    let voteRoundId: Data
    let sighash: Data

    init(
        rk: Data, // swiftlint:disable:this identifier_name
        spendAuthSig: Data,
        signedNoteNullifier: Data,
        cmxNew: Data,
        vanCmx: Data,
        govNullifiers: [Data],
        proof: Data,
        voteRoundId: Data,
        sighash: Data
    ) {
        self.rk = rk
        self.spendAuthSig = spendAuthSig
        self.signedNoteNullifier = signedNoteNullifier
        self.cmxNew = cmxNew
        self.vanCmx = vanCmx
        self.govNullifiers = govNullifiers
        self.proof = proof
        self.voteRoundId = voteRoundId
        self.sighash = sighash
    }
}
```

with:

```swift
struct DelegationRegistration: Equatable, Sendable {
    let rk: Data // swiftlint:disable:this identifier_name
    let spendAuthSig: Data
    /// Base64, verbatim from `VotingDelegationSubmission` — never compared as bytes, only
    /// ever placed on the wire, so it is never decoded.
    let signedNoteNullifier: String
    let cmxNew: String
    let vanCmx: String
    let govNullifiers: [String]
    let proof: String
    let voteRoundId: Data
    let sighash: Data

    init(
        rk: Data, // swiftlint:disable:this identifier_name
        spendAuthSig: Data,
        signedNoteNullifier: String,
        cmxNew: String,
        vanCmx: String,
        govNullifiers: [String],
        proof: String,
        voteRoundId: Data,
        sighash: Data
    ) {
        self.rk = rk
        self.spendAuthSig = spendAuthSig
        self.signedNoteNullifier = signedNoteNullifier
        self.cmxNew = cmxNew
        self.vanCmx = vanCmx
        self.govNullifiers = govNullifiers
        self.proof = proof
        self.voteRoundId = voteRoundId
        self.sighash = sighash
    }
}
```

Second, add the decode-failure error case this closure needs (`rk`/`spendAuthSig` are the only
two fields still decoded from base64, and a malformed value from the crate must not silently
proceed). In `VotingCryptoClientLiveKey.swift`, in the `VotingCryptoError` enum step 8.7 last
edited, replace:

```swift
    case malformedWireShare(UInt32)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        }
    }
}
```

with:

```swift
    case malformedWireShare(UInt32)
    case malformedDelegationSubmission(String)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        case .malformedDelegationSubmission(let detail):
            return "getDelegationSubmission returned malformed wire data: \(detail)"
        }
    }
}
```

Third, fix the closure itself. In the same file, replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.randomizedKey)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighashOut: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighashOut
                )
            },
```

with:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                guard
                    let rk = Data(base64Encoded: sub.randomizedKey),
                    let spendAuthSig = Data(base64Encoded: sub.spendAuthSig)
                else {
                    throw VotingCryptoError.malformedDelegationSubmission(
                        "rk/spend_auth_sig did not base64-decode"
                    )
                }
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: sub.nfSigned,
                    cmxNew: sub.cmxNew,
                    vanCmx: sub.govComm,
                    govNullifiers: sub.govNullifiers,
                    proof: sub.proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
```

`sighash` on the last line is the closure's own parameter (already `Data`) — never `sub.sighash`,
which no longer exists.

Fourth, stop re-encoding what is already base64 text. In
`secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift`, replace:

```swift
            submitDelegation: { registration in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let body: [String: Any] = [
                        "rk": registration.rk.base64EncodedString(),
                        "spend_auth_sig": registration.spendAuthSig.base64EncodedString(),
                        "sighash": registration.sighash.base64EncodedString(),
                        "signed_note_nullifier": registration.signedNoteNullifier.base64EncodedString(),
                        "cmx_new": registration.cmxNew.base64EncodedString(),
                        "van_cmx": registration.vanCmx.base64EncodedString(),
                        "gov_nullifiers": registration.govNullifiers.map { $0.base64EncodedString() },
                        "proof": registration.proof.base64EncodedString(),
                        "vote_round_id": registration.voteRoundId.base64EncodedString()
                    ]
```

with:

```swift
            submitDelegation: { registration in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let body: [String: Any] = [
                        "rk": registration.rk.base64EncodedString(),
                        "spend_auth_sig": registration.spendAuthSig.base64EncodedString(),
                        "sighash": registration.sighash.base64EncodedString(),
                        "signed_note_nullifier": registration.signedNoteNullifier,
                        "cmx_new": registration.cmxNew,
                        "van_cmx": registration.vanCmx,
                        "gov_nullifiers": registration.govNullifiers,
                        "proof": registration.proof,
                        "vote_round_id": registration.voteRoundId.base64EncodedString()
                    ]
```

Fifth, a third `DelegationRegistration(...)` call site this same field-type change breaks: the
test fixture. In `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift`, replace:

```swift
    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            signedNoteNullifier: Data(repeating: 0x03, count: 32),
            cmxNew: Data(repeating: 0x04, count: 32),
            vanCmx: Data(repeating: 0x05, count: 32),
            govNullifiers: [Data(repeating: 0x06, count: 32)],
            proof: Data(repeating: 0x07, count: 32),
            voteRoundId: Data([0xAA, 0xBB]),
            sighash: sighash
        )
    }
```

with:

```swift
    private static func makeDelegationRegistration(
        rk: Data = Data(repeating: 0x01, count: 32),
        spendAuthSig: Data = Data(repeating: 0x02, count: 64),
        sighash: Data = Data(repeating: 0x08, count: 32)
    ) -> DelegationRegistration {
        DelegationRegistration(
            rk: rk,
            spendAuthSig: spendAuthSig,
            signedNoteNullifier: Data(repeating: 0x03, count: 32).base64EncodedString(),
            cmxNew: Data(repeating: 0x04, count: 32).base64EncodedString(),
            vanCmx: Data(repeating: 0x05, count: 32).base64EncodedString(),
            govNullifiers: [Data(repeating: 0x06, count: 32).base64EncodedString()],
            proof: Data(repeating: 0x07, count: 32).base64EncodedString(),
            voteRoundId: Data([0xAA, 0xBB]),
            sighash: sighash
        )
    }
```

This test file is edited twice across this plan at two non-overlapping locations — this fixture
here (`:928-944` at plan-writing time) by step 9.0a, and the Keystone stub rename (`:1025`) by
Task 14 — so Task 14 will encounter this file already modified by this step; that is expected,
not a conflict.

- [ ] **Step 9.0b: Delete the dead `toSDK()` extension.** `private extension
VoteCommitmentBundle { func toSDK() -> VotingVoteCommitmentBundle { ... } }` references
`VotingVoteCommitmentBundle`, a type that exists nowhere in the real SDK (it was invented for
the pre-SDK-lane-Task-2 `buildSharePayloads`/`signCastVote` pipeline). Its only caller was
`signCastVote`'s `LiveKey` implementation, which step 8.8 already deleted — no task owns
deleting the now-dead extension itself. Verify first:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "VotingVoteCommitmentBundle\|private extension VoteCommitmentBundle" secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift
```

Expected: exactly the one extension block, no other reference anywhere in the file (confirming
it is genuinely unreferenced, not just unreferenced by the deleted closure). In the same file,
replace:

```swift
private extension VoteCommitmentBundle {
    func toSDK() -> VotingVoteCommitmentBundle {
        VotingVoteCommitmentBundle(
            vanNullifier: [UInt8](vanNullifier),
            voteAuthorityNoteNew: [UInt8](voteAuthorityNoteNew),
            voteCommitment: [UInt8](voteCommitment),
            proposalId: proposalId,
            proof: [UInt8](proof),
            encShares: encShares.map {
                VotingWireEncryptedShare(
                    ciphertext1: [UInt8]($0.c1),
                    ciphertext2: [UInt8]($0.c2),
                    shareIndex: $0.shareIndex
                )
            },
            anchorHeight: anchorHeight,
            voteRoundId: voteRoundId,
            sharesHash: [UInt8](sharesHash),
            shareBlinds: shareBlindFactors.map { [UInt8]($0) },
            shareComms: shareComms.map { [UInt8]($0) },
            rVpkBytes: [UInt8](rVpkBytes),
            alphaV: [UInt8](alphaV)
        )
    }
}
```

with nothing (delete the block and the blank line immediately above it, so the file reads
straight from whatever precedes it into whatever follows — verify at edit time that no other
blank-line adjustment is needed; do not leave two consecutive blank lines behind).

- [ ] **Step 9.1: Thread `txHash` through `markVoteSubmitted`.** In
`VotingCryptoClientInterface.swift`, replace:

```swift
    var markVoteSubmitted: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32) async throws -> Void
```

with:

```swift
    var markVoteSubmitted: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ txHash: String) async throws -> Void
```

- [ ] **Step 9.2: Add `confirmVoteSubmission` and `getCommitmentBundleJson`, drop the
`nullifier:` parameter from `recordShareDelegation`.** In the same file, replace:

```swift
    /// Persist a Keystone bundle signature so it survives app restarts.
```

with (inserting two new members immediately before the existing recovery-state section header
comment; the `///` doc line quoted is the anchor, unchanged, appearing again at the end of this
block):

```swift
    /// Record a confirmed cast-vote transaction in one atomic step.
    ///
    /// `eventsJson` is the confirmation-events array the app's existing confirmation polling
    /// already fetches (`VotingAPIClient.fetchTxConfirmation(_:).events`), serialized as JSON —
    /// a list of `{"type": …, "attributes": [{"key": …, "value": …}]}` objects. Callers must
    /// not parse `leaf_index` themselves; that is exactly the duplicated state this entry point
    /// exists to delete (spec `CHP_DESIGN.md` §3/A2 step 4).
    var confirmVoteSubmission: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32,
        _ txHash: String,
        _ eventsJson: String
    ) async throws -> VoteConfirmationInfo
    /// Read the persisted commitment-recovery bundle for a (round, bundle, proposal) as the
    /// raw JSON `commitVote` wrote — opaque to this layer; feed it straight into
    /// `recoverWireJson`. Distinct from `getVoteCommitmentBundle`/
    /// `getVoteCommitmentBundleWithPosition`, which decode it as the app's own
    /// `VoteCommitmentBundle` — a decode target that no longer matches what `commitVote`
    /// persists (see `## CORRECTIONS` item 13 in the T9 plan notes).
    var getCommitmentBundleJson: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ proposalId: UInt32
    ) async throws -> (bundleJson: String, vcTreePosition: UInt64)?
    /// Rebuild one helper-server share payload as `zcash_voting`'s own wire JSON, with the
    /// confirmed vote-commitment-tree position and the scheduled submit time late-bound into
    /// it. POST the returned string verbatim — do not decode, re-shape, or re-encode it.
    var recoverWireJson: @Sendable (
        _ commitmentBundleJson: String,
        _ proposalId: UInt32,
        _ shareIndex: UInt32,
        _ voteCommitmentTreePosition: UInt64,
        _ submitAt: UInt64
    ) async throws -> String
    /// Persist a Keystone bundle signature so it survives app restarts.
```

Then, still in the same file, replace:

```swift
    /// Record a share delegation after sending to helper servers.
    var recordShareDelegation: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ sentToURLs: [String], _ nullifier: [UInt8], _ submitAt: UInt64) async throws -> Void
```

with:

```swift
    /// Record a share delegation after sending to helper servers.
    ///
    /// The share's nullifier is no longer supplied by the caller: `zcash_voting` derives it
    /// from the committed vote's recovery state, so a caller cannot record a nullifier that
    /// disagrees with the share it belongs to. Read it back via `getShareDelegations`/
    /// `getUnconfirmedDelegations` when polling `VotingAPIClient.fetchShareStatus`.
    var recordShareDelegation: @Sendable (_ roundId: String, _ bundleIndex: UInt32, _ proposalId: UInt32, _ shareIndex: UInt32, _ sentToURLs: [String], _ submitAt: UInt64) async throws -> Void
```

Add the small result type this step's new member needs — append to the bottom of the file, just
above the closing `#endif`:

```swift

/// Positions a mined cast-vote transaction confirmed. Mirrors
/// `VotingRustBackend.VotingVoteConfirmation` (SDK-lane Task 3) field for field.
struct VoteConfirmationInfo: Equatable, Sendable {
    let txHash: String
    let vanLeafPosition: UInt32
    let voteCommitmentTreePosition: UInt64
}
```

- [ ] **Step 9.3: Implement `confirmVoteSubmission` in the LiveKey.** In
`VotingCryptoClientLiveKey.swift`, insert immediately before the `storeKeystoneBundleSignature:`
closure (which follows the block Step 9.2 targeted):

```swift
            confirmVoteSubmission: { roundId, bundleIndex, proposalId, txHash, eventsJson in
                let backend = try await dbActor.backend()
                let confirmation = try backend.confirmVoteSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    txHash: txHash,
                    eventsJson: eventsJson
                )
                publishState(backend: backend, roundId: roundId)
                return VoteConfirmationInfo(
                    txHash: confirmation.txHash,
                    vanLeafPosition: confirmation.vanLeafPosition,
                    voteCommitmentTreePosition: confirmation.voteCommitmentTreePosition
                )
            },
            getCommitmentBundleJson: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else {
                    return nil
                }
                return (bundleJson: result.bundleJson, vcTreePosition: result.voteCommitmentTreePosition)
            },
            recoverWireJson: { commitmentBundleJson, proposalId, shareIndex, voteCommitmentTreePosition, submitAt in
                try VotingRustBackend.recoverWireJson(
                    commitmentBundleJson: commitmentBundleJson,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    submitAt: submitAt
                )
            },
```

`VotingRustBackend.recoverWireJson` is `static` (SDK-lane Task 3) — no database handle needed;
called as a type method here, matching how `computeShareNullifier` is already called elsewhere
in this same file.

- [ ] **Step 9.4: Thread `txHash` through `markVoteSubmitted`'s implementation.** In the same
file, replace:

```swift
            markVoteSubmitted: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId)
                publishState(backend: backend, roundId: roundId)
            },
```

with:

```swift
            markVoteSubmitted: { roundId, bundleIndex, proposalId, txHash in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, txHash: txHash)
                publishState(backend: backend, roundId: roundId)
            },
```

- [ ] **Step 9.5: Drop the nullifier argument from `recordShareDelegation`'s implementation.**
In the same file, replace:

```swift
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, nullifier, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    nullifier: hexEncodedString(nullifier),
                    submitAt: submitAt
                )
            },
```

with:

```swift
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    submitAt: submitAt
                )
            },
```

`hexEncodedString(_:)` (private helper, `:794-796`) becomes unused by this change alone — leave
it; `computeShareNullifier`'s LiveKey closure (`:655-661`, untouched by this task) still calls
`VotingRustBackend.computeShareNullifier` directly and does not go through this helper either
way, so check at Step 9.10's build gate whether SwiftLint's unused-function pass flags it before
removing it in a later cleanup — do not remove it speculatively here.

- [ ] **Step 9.6: Re-shape `SharePayload` to carry the crate's opaque wire JSON.** In
`VotingModels.swift`, replace (lines 517-548):

```swift
/// Payload sent to helper servers for share delegation (not directly to chain).
struct SharePayload: Equatable, Sendable {
    let sharesHash: Data
    let proposalId: UInt32
    let voteDecision: UInt32
    let encShare: EncryptedShare
    let treePosition: UInt64
    /// All encrypted shares for this vote (needed by helper servers for verification).
    let allEncShares: [EncryptedShare]
    /// Pre-computed per-share Poseidon commitments (N x 32 bytes).
    let shareComms: [Data]
    /// Blind factor for this specific share (32 bytes).
    let primaryBlind: Data
    /// Unix seconds at which the helper should submit the share; 0 = immediate (last-moment).
    var submitAt: UInt64

    init(
        sharesHash: Data, proposalId: UInt32, voteDecision: UInt32, encShare: EncryptedShare,
        treePosition: UInt64, allEncShares: [EncryptedShare] = [], shareComms: [Data] = [],
        primaryBlind: Data = Data(), submitAt: UInt64 = 0
    ) {
        self.sharesHash = sharesHash
        self.proposalId = proposalId
        self.voteDecision = voteDecision
        self.encShare = encShare
        self.treePosition = treePosition
        self.allEncShares = allEncShares
        self.shareComms = shareComms
        self.primaryBlind = primaryBlind
        self.submitAt = submitAt
    }
}
```

with:

```swift
/// Payload sent to helper servers for share delegation (not directly to chain).
///
/// Wraps `zcash_voting`'s own wire JSON for one share — obtained from
/// `VotingCryptoClient.recoverWireJson(...)` — verbatim. Every field the old hand-built dialect
/// carried (`sharesHash`, `allEncShares`, `shareComms`, `primaryBlind`, the encoded `submitAt`)
/// is already inside `wireJson`; the crate produced and encoded it, so nothing here re-shapes
/// it. `shareIndex` is kept alongside only for local bookkeeping (matching a POST's outcome back
/// to the share it was for) — it is never written onto the wire a second time.
struct SharePayload: Equatable, Sendable {
    let wireJson: String
    let shareIndex: UInt32

    init(wireJson: String, shareIndex: UInt32) {
        self.wireJson = wireJson
        self.shareIndex = shareIndex
    }
}
```

- [ ] **Step 9.7: Parse the wire JSON straight into the POST body.** In
`VotingAPIClientLiveKey.swift`, replace (lines 352-380):

```swift
func sharePostBody(
    for payload: SharePayload,
    roundIdHex: String,
    submitAt: UInt64? = nil
) -> [String: Any] {
    [
        "shares_hash": payload.sharesHash.base64EncodedString(),
        "proposal_id": payload.proposalId,
        "vote_decision": payload.voteDecision,
        "enc_share": [
            "c1": payload.encShare.c1.base64EncodedString(),
            "c2": payload.encShare.c2.base64EncodedString(),
            "share_index": payload.encShare.shareIndex
        ],
        "share_index": payload.encShare.shareIndex,
        "tree_position": payload.treePosition,
        "vote_round_id": roundIdHex,
        "all_enc_shares": payload.allEncShares.map { share -> [String: Any] in
            [
                "c1": share.c1.base64EncodedString(),
                "c2": share.c2.base64EncodedString(),
                "share_index": share.shareIndex
            ]
        },
        "share_comms": payload.shareComms.map { $0.base64EncodedString() },
        "primary_blind": payload.primaryBlind.base64EncodedString(),
        "submit_at": submitAt ?? payload.submitAt
    ]
}
```

with:

```swift
/// `roundIdHex` is unused: the crate's wire JSON already carries `vote_round_id` (it was
/// derived from the same commitment record `recoverWireJson` read); the parameter is kept so
/// call sites that still pass it (unchanged by this task) do not need editing.
func sharePostBody(
    for payload: SharePayload,
    roundIdHex: String
) -> [String: Any] {
    let data = Data(payload.wireJson.utf8)
    guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return [:]
    }
    return body
}
```

- [ ] **Step 9.8: Update `sharePostBody`'s two call sites for the dropped `submitAt:`
parameter.** In the same file, replace:

```swift
                            let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

with:

```swift
                            let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

(no change needed — `delegateSharePayloads`'s call already omits the optional `submitAt:`).
Then replace:

```swift
    let body = sharePostBody(for: payload, roundIdHex: roundIdHex, submitAt: 0)
```

with:

```swift
    let body = sharePostBody(for: payload, roundIdHex: roundIdHex)
```

`resubmitSharePayload`'s old `submitAt: 0` override no longer applies: a resubmission must call
`recoverWireJson(..., submitAt: 0)` **before** constructing the `SharePayload` (Step 9.14 does
this), so the wire JSON already encodes `submit_at: 0` by the time it reaches this function.

- [ ] **Step 9.9: Rewire the main path — delete `leaf_index` parsing and the dead
`storeVanPosition`/`storeVoteCommitmentBundle`/`buildSharePayloads` calls, insert
`confirmVoteSubmission` + the `recoverWireJson` loop, thread `txHash` into
`markVoteSubmitted`.** In `VotingCoordFlowCoordinator.swift`, replace:

```swift
                        let voteDeadline = Date().addingTimeInterval(90)
                        var voteConfirmation: TxConfirmation?
                        repeat {
                            voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                            if voteConfirmation != nil { break }
                            try await Task.sleep(for: .seconds(2))
                        } while Date() < voteDeadline

                        guard let voteConfirmation, voteConfirmation.code == 0,
                              let leafPair = voteConfirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index")
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: voteConfirmation?.code ?? 0,
                                log: voteConfirmation?.log ?? ""
                            )
                        }
                        let leafParts = leafPair.split(separator: ",")
                        guard leafParts.count == 2,
                              let vanIdx = UInt32(leafParts[0]),
                              let vcIdx = UInt64(leafParts[1])
                        else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: 0,
                                log: "malformed cast_vote leaf_index: \(leafPair)"
                            )
                        }

                        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
                        var payloads = try await votingCrypto.buildSharePayloads(
                            builtBundle.encShares, builtBundle, choice, numOptions, vcIdx, singleShare
                        )
                        let nowSec = Date().timeIntervalSince1970
                        for i in payloads.indices {
                            if let deadline = submitAtDeadline, deadline > nowSec {
                                payloads[i].submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                            } else {
                                payloads[i].submitAt = 0
                            }
                        }
                        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, vcIdx)
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
                        shareServerURLs = batchDelegationResult.remainingServerURLs
                        for info in batchDelegationResult.delegatedShares {
                            guard let payload = payloads.first(where: {
                                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
                            }) else { continue }
                            let blindIndex = Int(info.shareIndex)
                            guard blindIndex < builtBundle.shareBlindFactors.count else { continue }
                            do {
                                let nullifierHex = try votingCrypto.computeShareNullifier(
                                    [UInt8](builtBundle.voteCommitment),
                                    info.shareIndex,
                                    [UInt8](builtBundle.shareBlindFactors[blindIndex])
                                )
                                try await votingCrypto.recordShareDelegation(
                                    roundId, bundleIndex, info.proposalId,
                                    info.shareIndex, info.acceptedByServers,
                                    [UInt8](votingDataFromHex(nullifierHex)), payload.submitAt
                                )
                            } catch {
                                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                            }
                        }
                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
```

with:

```swift
                        let voteDeadline = Date().addingTimeInterval(90)
                        var voteConfirmation: TxConfirmation?
                        repeat {
                            voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                            if voteConfirmation != nil { break }
                            try await Task.sleep(for: .seconds(2))
                        } while Date() < voteDeadline

                        guard let voteConfirmation, voteConfirmation.code == 0 else {
                            throw VotingFlowError.voteCommitmentTxFailed(
                                code: voteConfirmation?.code ?? 0,
                                log: voteConfirmation?.log ?? ""
                            )
                        }

                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, txResult.txHash)

                        let eventsPayload: [[String: Any]] = voteConfirmation.events.map { event in
                            [
                                "type": event.type,
                                "attributes": event.attributes.map { attribute in
                                    ["key": attribute.key, "value": attribute.value]
                                }
                            ]
                        }
                        let eventsData = try JSONSerialization.data(withJSONObject: eventsPayload)
                        let eventsJson = String(decoding: eventsData, as: UTF8.self)

                        let confirmation = try await votingCrypto.confirmVoteSubmission(
                            roundId, bundleIndex, proposalId, txResult.txHash, eventsJson
                        )

                        await send(.voteSubmissionStepUpdated(roundId: roundId, step: .sendingShares))
                        guard let stored = try await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                            throw VotingFlowError.missingVoteCommitmentBundle
                        }
                        let nowSec = Date().timeIntervalSince1970
                        var payloads: [SharePayload] = []
                        var submitAtByShareIndex: [UInt32: UInt64] = [:]
                        for share in builtBundle.encShares {
                            let submitAt: UInt64
                            if let deadline = submitAtDeadline, deadline > nowSec {
                                submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                            } else {
                                submitAt = 0
                            }
                            submitAtByShareIndex[share.shareIndex] = submitAt
                            let wireJson = try await votingCrypto.recoverWireJson(
                                stored.bundleJson, proposalId, share.shareIndex,
                                confirmation.voteCommitmentTreePosition, submitAt
                            )
                            payloads.append(SharePayload(wireJson: wireJson, shareIndex: share.shareIndex))
                        }
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
                        shareServerURLs = batchDelegationResult.remainingServerURLs
                        for info in batchDelegationResult.delegatedShares {
                            do {
                                try await votingCrypto.recordShareDelegation(
                                    roundId, bundleIndex, info.proposalId, info.shareIndex,
                                    info.acceptedByServers, submitAtByShareIndex[info.shareIndex] ?? 0
                                )
                            } catch {
                                LoggerProxy.warn("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                            }
                        }
```

Trap T3 (spec `CHP_DESIGN.md` §3/A2, CHP.md §11.9): between `markVoteSubmitted` and
`confirmVoteSubmission` returning, every position consumer inside `zcash_voting` hard-errors
("refusing to assume position 0") on any commit-adjacent read that assumes the provisional `0`.
This code path adds **no catch-and-ignore** around `confirmVoteSubmission` or `recoverWireJson`
— both `try await` directly into the enclosing `do`/`catch` at the top of this loop iteration
(unchanged, not shown above), which already surfaces the error to `.batchVoteFailed`. Verify
this at review time by confirming neither call is wrapped in its own local `try?` or
`do { } catch { }` inside this block — none is, in the replacement above.

- [ ] **Step 9.10: Progress gate.** Same two-command idiom as Step 8.13 — build, judged on its
own exit code; count, judged separately and never on its own exit code. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t9-build.log || true
```

Expected: a number, strictly less than Step 8.13's count (this command's own exit is not
judged — see Step 8.13 for why). `buildSharePayloads`, `storeVanPosition`, `leaf_index` must
**not** appear anywhere in the new log at the main-path location (`:1892`-region — the two
remaining `buildSharePayloads`/`storeVoteCommitmentBundle` call sites at the poll-resubmission
and crash-recovery regions, steps 9.11–9.13 below, are expected to still error).

- [ ] **Step 9.11: Rewire the share-status-poll resubmission region.** In
`VotingCoordFlowCoordinator.swift`, replace (inside `reducePollShareStatus`, the
`grouped`/`for (_, shares) in grouped` block):

```swift
            let grouped = Dictionary(grouping: pollResult.resubmissionShares) {
                "\($0.bundleIndex):\($0.proposalId)"
            }
            for (_, shares) in grouped {
                guard let first = shares.first else { continue }
                let bundleIndex = first.bundleIndex
                let proposalId = first.proposalId
                guard
                    let result = try? await votingCrypto.getVoteCommitmentBundleWithPosition(
                        roundId,
                        bundleIndex,
                        proposalId
                    ),
                    let choice = votes[proposalId]
                else {
                    continue
                }

                let numOptions = UInt32(proposals.first { $0.id == proposalId }?.options.count ?? 3)
                do {
                    var payloads = try await votingCrypto.buildSharePayloads(
                        result.bundle.encShares,
                        result.bundle,
                        choice,
                        numOptions,
                        result.vcTreePosition,
                        singleShare
                    )
                    for index in payloads.indices {
                        payloads[index].submitAt = 0
                    }

                    for share in shares {
                        guard let payload = payloads.first(where: {
                            $0.encShare.shareIndex == share.shareIndex
                        }) else {
                            continue
                        }
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
                            roundId,
                            share.sentToURLs
                        )
                        let newServers = acceptedServers.filter {
                            !share.sentToURLs.contains($0)
                        }
                        if !newServers.isEmpty {
                            try await votingCrypto.addSentServers(
                                roundId,
                                bundleIndex,
                                proposalId,
                                share.shareIndex,
                                newServers
                            )
                        }
                    }
                } catch {
                    LoggerProxy.warn("Share resubmission failed: \(error)")
                }
            }
```

with:

```swift
            let grouped = Dictionary(grouping: pollResult.resubmissionShares) {
                "\($0.bundleIndex):\($0.proposalId)"
            }
            for (_, shares) in grouped {
                guard let first = shares.first else { continue }
                let bundleIndex = first.bundleIndex
                let proposalId = first.proposalId
                guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
                    continue
                }

                do {
                    for share in shares {
                        let wireJson = try await votingCrypto.recoverWireJson(
                            stored.bundleJson, proposalId, share.shareIndex, stored.vcTreePosition, 0
                        )
                        let payload = SharePayload(wireJson: wireJson, shareIndex: share.shareIndex)
                        let acceptedServers = try await votingAPI.resubmitShare(
                            payload,
                            roundId,
                            share.sentToURLs
                        )
                        let newServers = acceptedServers.filter {
                            !share.sentToURLs.contains($0)
                        }
                        if !newServers.isEmpty {
                            try await votingCrypto.addSentServers(
                                roundId,
                                bundleIndex,
                                proposalId,
                                share.shareIndex,
                                newServers
                            )
                        }
                    }
                } catch {
                    LoggerProxy.warn("Share resubmission failed: \(error)")
                }
            }
```

This region resubmits shares `getUnconfirmedDelegations` already knows about — `share.shareIndex`
for each already came from a prior, successful `recordShareDelegation`, so no fresh share-index
enumeration is needed here (contrast step 9.13's finding). `votes`/`numOptions`/`singleShare`
become unused by this block specifically; leave them if `reducePollShareStatus`'s other code
still references them (verify at the build gate — do not remove speculatively).

- [ ] **Step 9.12: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9b-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t9b-build.log || true
```

Expected: a number, strictly less than Step 9.10's count (exit status not judged). Only
`tryRecoverInflightVote` (`:3419-3505`) should still reference
`buildSharePayloads`/`storeVanPosition`/`storeVoteCommitmentBundle`/`computeShareNullifier`
after this step.

- [ ] **Step 9.13: STOP-and-report — `tryRecoverInflightVote`'s share-index enumeration
(finding, not a code step).** This function recovers from a crash between broadcast and share
delegation, using only a **cached** tx hash (`getVoteTxHash`) and the **stored** recovery bundle
— unlike step 9.9's main path, it has no fresh `commitVote` result to read `encShares` from,
and unlike step 9.11's poll-resubmission region, it has no prior `recordShareDelegation` calls
to read share indices back from (the crash may have happened before any share was ever
recorded). `stored.bundleJson` (this task's own `getCommitmentBundleJson`) is explicitly
opaque-do-not-decode, so it cannot be inspected for a share count either. There is no verified
source for "how many shares, at which indices, does this bundle have" in this one scenario.

Decision procedure:
1. Confirm at a build gate that this function is in fact still referenced from a live call site
   (`grep -n tryRecoverInflightVote VotingCoordFlowCoordinator.swift` — at plan-writing time
   its only caller is the main batch-submission loop, guarding against exactly this crash
   window) — if it has become unreachable dead code by execution time, delete the whole
   function and skip the rest of this procedure.
2. Otherwise, check whether SDK-lane Task 3's `confirmVoteSubmission`/`recoverWireJson`
   landed with anything beyond `## INTERFACES-FOR-APP`'s documented shape — specifically
   whether `VotingVoteConfirmation` or any other confirmation-adjacent type gained a
   share-count/share-index-list field. If yes, use it; write the concrete call as a follow-up
   step before continuing.
3. If not (the expected outcome): do not guess a share count (not `numOptions`, not a
   protocol constant, not decoded from `stored.bundleJson`). Leave this function's body
   red at its `buildSharePayloads` call. Surface as a named, non-blocking finding — non-blocking
   because it only affects a same-launch-crash-recovery edge case, not the primary vote flow
   steps 9.9/9.11 already close, and not the T14/gate-5 acceptance criteria (zero *compile*
   errors, not zero *runtime* TODOs). Recommend it be resolved before the testnet E2E crash-
   recovery scenario (`CHP_PLAN.md` Task 16, step 16.3's matrix item) is run, not before T14.

- [ ] **Step 9.14: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Dependencies/VotingModels/VotingModels.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Wire the confirm/recover-share vote sequence and drop the leaf_index hand-parse" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9B: recovery-path closure — F3 resolution + SharePayload residue

*Code blocks by: Sonnet (app delegate).*

**Execution order note:** this section sits between Tasks 9 and 10 in this file (its subject —
the crash-recovery function Task 9's step 9.13 deliberately left red — is Task 9's own unclosed
scope) but **executes after Task 10**, per the coordinator's live-build sequencing. A Task 10
executor may be running concurrently on the same tree; Task 10's scope is hotkey/PCZT regions
only (`VotingCryptoClientInterface.swift`'s `generateHotkey`/`buildVotingPczt`/
`buildAndProveDelegation` members, `StoredVotingHotkey.swift`, `WalletStorage*.swift`,
`VotingModels.swift`'s `VotingHotkey`, and four `mnemonic.toSeed` coordinator sites far above
line 3300) — disjoint from everything this section touches. Every anchor below is stated as
**unique code content**, not a trusted line number, for exactly that reason: the tree this
section was written against is post-T9 `f8cdac12`, and by the time it executes (after Task 10)
line numbers upstream of `tryRecoverInflightVote` will have shifted from Task 10's own edits.

**Files:**
- Modify: `secant/Sources/Features/Voting/VotingHelpers.swift` (`Voting.delegateSharesWithFallback`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift` (`delegateShares`)
- Modify: `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift` (`delegateShares` closure, `delegateSharePayloads`)
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift` (the step-9.9 main-path `delegateSharesWithFallback` call site, and the full body of `static func tryRecoverInflightVote`)

**Interfaces:**
- Consumes: `zcash_voting` rc.5's own recovery surface, read directly from the vendored crate
  source (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/zcash_voting-2.0.0-rc.5/src/
  share.rs` — the standard cargo registry cache path for the crates.io registry, stable across
  machines that use the default registry) — `recover_payloads(bundle: &VoteRecoveryBundle) ->
  Result<Vec<SharePayload>, VotingError>` (`:148-188`) slices `bundle.encrypted_shares` by
  exactly `bundle.single_share` (`&all_enc_shares[..1]` if true, the full vector otherwise);
  `recover_payload`/`recover_wire_json` (`:135-145`, `:192-210`) are both single-`share_index`
  accessors built on top of it — the crate never exposes the plural form outward. Also
  consumes the already-landed `VotingCryptoClient.confirmVoteSubmission`/`.getCommitmentBundleJson`/
  `.recoverWireJson`/`.recordShareDelegation`/`.markVoteSubmitted` (Task 9) unchanged.
- Produces: `Voting.delegateSharesWithFallback(...)` and `VotingAPIClient.delegateShares(...)`
  both gain a `proposalId: UInt32` parameter; `tryRecoverInflightVote`'s body is fully rewired,
  its signature unchanged.

---

**F3 evidence and decision (read before step 9B.1).** The share-index-enumeration question
Task 9's step 9.13 left open now has a sourced answer, not a guess:

1. **The crate's own plural recovery function exists but is not the sanctioned host surface.**
   `zcash_voting-2.0.0-rc.5/src/share.rs:148` — `pub fn recover_payloads(bundle:
   &VoteRecoveryBundle) -> Result<Vec<SharePayload>, VotingError>` — reconstructs every share
   payload for a bundle in one call, slicing `bundle.encrypted_shares` by `bundle.single_share`
   (`:156-160`: `if bundle.single_share { &all_enc_shares[..1] } else { &all_enc_shares }`).
   This confirms the *crate-internal* fact this section needs: share count is a pure function
   of two values the app already threads through `tryRecoverInflightVote` today —
   `singleShare: Bool` and (when not single-share) `bundle.encrypted_shares.len()`, which
   `vote.rs:592-599`'s `db.build_vote_commitment(..., draft.num_options, ..., draft.
   single_share, ...)` sizes from `num_options` at commit time — i.e. `numOptions` when not
   single-share, `1` when single-share.
2. **Valar's own reference wallet does not expose the plural function either.** Fetched
   `chainapsis/vizor-wallet`'s `rust/src/api/voting.rs` (`gh api repos/chainapsis/vizor-wallet/
   contents/rust/src/api/voting.rs`, decoded, 3452 lines). Its FRB bridge function
   `recovered_vote_share_wire_json(commitment_bundle_json, proposal_id, share_index,
   vc_tree_position, submit_at) -> Result<String, String>` (`:362-379`) is a direct, thin
   passthrough to `zcash_voting::share::recover_wire_json(...)` — the exact same per-index
   function our SDK's `recoverWireJson` already wraps. Vizor's Rust layer has full, direct
   access to the crate (no FFI marshalling boundary the way our Swift app has) and *still*
   exposes only the per-index accessor to its own Dart layer above it. That is the sanctioning
   precedent: even the reference wallet resolves "how many shares, which indices" from
   app-layer round/bundle context, not from a crate list call.
3. **Decision: no new FFI symbol.** Both sources agree the per-index `recoverWireJson` already
   on this SDK (SDK-lane Task 3, already built into the current FFI slices) is the intended
   surface. Bounded enumeration over `0..<(singleShare ? 1 : numOptions)` — values already
   present in this function's own parameter list — is not a guess or a workaround; it is the
   same computation the crate performs internally and the same resolution Valar's own
   reference wallet's app layer performs externally. The ~1-hour FFI rebuild + gates 2–3
   re-run this would have cost is avoided correctly, not just conveniently.

**`DelegatedShareInfo` re-sourcing verdict (read before step 9B.1).** Traced
`DelegatedShareInfo`'s full consumer chain: it is constructed once
(`VotingAPIClientLiveKey.swift`'s `delegateSharePayloads`, currently reading the now-nonexistent
`payload.encShare.shareIndex`/`payload.proposalId`) and consumed twice — Task 9's step 9.9 main
path and this section's rewritten `tryRecoverInflightVote` — both of which call
`recordShareDelegation(..., info.proposalId, info.shareIndex, ...)`. `shareIndex` survives on the
Task-9-reshaped `SharePayload` unchanged (`payload.shareIndex` — a one-word fix). `proposalId`
does not survive on `SharePayload` at all, but every call site that builds a `[SharePayload]`
batch for `delegateSharePayloads` builds it for exactly one proposal at a time (Task 9's step 9.9
loop and this section's F3 rewrite both construct `payloads` once per `commitVote`/recovery pass,
one proposal each) — so `proposalId` is a per-*call* invariant, not a per-*payload* one. It
belongs as an explicit parameter threaded once through the transport chain, not reconstructed
per element from data that no longer carries it (§2.0: the app must not re-derive what it can be
handed directly).

- [ ] **Step 9B.1: Thread `proposalId` through the share-delegation transport chain.** In
`secant/Sources/Features/Voting/VotingHelpers.swift`, locate the unique block:

```swift
    static func delegateSharesWithFallback(
        _ payloads: [SharePayload],
        roundId: String,
        votingAPI: VotingAPIClient,
        serverURLs: [String],
        retryDelay: Duration = .seconds(2)
    ) async throws -> ShareDelegationResult {
        guard !serverURLs.isEmpty else {
            throw ShareDelegationError.noReachableVoteServers
        }
```

and replace it with:

```swift
    static func delegateSharesWithFallback(
        _ payloads: [SharePayload],
        roundId: String,
        proposalId: UInt32,
        votingAPI: VotingAPIClient,
        serverURLs: [String],
        retryDelay: Duration = .seconds(2)
    ) async throws -> ShareDelegationResult {
        guard !serverURLs.isEmpty else {
            throw ShareDelegationError.noReachableVoteServers
        }
```

Then, in the same function, locate the unique line:

```swift
                return try await votingAPI.delegateShares(payloads, roundId, serverURLs)
```

and replace it with:

```swift
                return try await votingAPI.delegateShares(payloads, roundId, proposalId, serverURLs)
```

Second, in `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift`, locate
the unique block:

```swift
    var delegateShares: @Sendable (
        _ payloads: [SharePayload],
        _ roundIdHex: String,
        _ serverURLs: [String]
    ) async throws -> ShareDelegationResult
```

and replace it with:

```swift
    var delegateShares: @Sendable (
        _ payloads: [SharePayload],
        _ roundIdHex: String,
        _ proposalId: UInt32,
        _ serverURLs: [String]
    ) async throws -> ShareDelegationResult
```

Third, in `secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift`, locate the
unique block:

```swift
            delegateShares: { payloads, roundIdHex, serverURLs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // Active foreground delivery uses the submission-local server set.
                    // POST failures prune that local set immediately; cached helper
                    // health and /status probes are intentionally not consulted here.
                    // Successful/failed foreground POSTs still update the tracker for
                    // later background recovery decisions.
                    let tracker = ServerHealthTracker.shared
                    return try await delegateSharePayloads(
                        payloads,
                        roundIdHex: roundIdHex,
                        initialServerURLs: serverURLs,
                        postShare: { server, body in
                            do {
                                _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                                await tracker.recordSuccess(for: server)
                            } catch {
                                await tracker.recordFailure(for: server)
                                throw error
                            }
                        }
                    )
                }
            },
```

and replace it with:

```swift
            delegateShares: { payloads, roundIdHex, proposalId, serverURLs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    // Active foreground delivery uses the submission-local server set.
                    // POST failures prune that local set immediately; cached helper
                    // health and /status probes are intentionally not consulted here.
                    // Successful/failed foreground POSTs still update the tracker for
                    // later background recovery decisions.
                    let tracker = ServerHealthTracker.shared
                    return try await delegateSharePayloads(
                        payloads,
                        roundIdHex: roundIdHex,
                        proposalId: proposalId,
                        initialServerURLs: serverURLs,
                        postShare: { server, body in
                            do {
                                _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                                await tracker.recordSuccess(for: server)
                            } catch {
                                await tracker.recordFailure(for: server)
                                throw error
                            }
                        }
                    )
                }
            },
```

Fourth, in the same file, locate the unique block:

```swift
func delegateSharePayloads(
    _ payloads: [SharePayload],
    roundIdHex: String,
    initialServerURLs: [String],
    postShare: @escaping SharePost,
    selectTargets: @escaping ShareTargetSelector = { Array($0.shuffled().prefix($1)) }
) async throws -> ShareDelegationResult {
```

and replace it with:

```swift
func delegateSharePayloads(
    _ payloads: [SharePayload],
    roundIdHex: String,
    proposalId: UInt32,
    initialServerURLs: [String],
    postShare: @escaping SharePost,
    selectTargets: @escaping ShareTargetSelector = { Array($0.shuffled().prefix($1)) }
) async throws -> ShareDelegationResult {
```

Then, still in `delegateSharePayloads`, locate the unique block:

```swift
        results.append(DelegatedShareInfo(
            shareIndex: payload.encShare.shareIndex,
            proposalId: payload.proposalId,
            acceptedByServers: acceptedServers
        ))
```

and replace it with:

```swift
        results.append(DelegatedShareInfo(
            shareIndex: payload.shareIndex,
            proposalId: proposalId,
            acceptedByServers: acceptedServers
        ))
```

- [ ] **Step 9B.2: Fix the one existing caller — Task 9's main-path `delegateSharesWithFallback`
call.** In `VotingCoordFlowCoordinator.swift`, locate the unique block (landed by Task 9's step
9.9):

```swift
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
```

and replace it with:

```swift
                        let batchDelegationResult = try await Voting.delegateSharesWithFallback(
                            payloads,
                            roundId: roundId,
                            proposalId: proposalId,
                            votingAPI: votingAPI,
                            serverURLs: shareServerURLs
                        )
```

`proposalId` is already in scope at this call site — it is the same `draftLoop`/`drafts.
enumerated()` loop variable step 9.9's surrounding code already reads throughout.

- [ ] **Step 9B.3: Rewrite `tryRecoverInflightVote` — F3.** In `VotingCoordFlowCoordinator.swift`,
verify the anchor first (content-based, not line-based — see this section's intro):

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "static func tryRecoverInflightVote" secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

Expected: one hit. Locate the full function by that signature and the matching closing `}` two
levels up (the function is `swiftlint:disable:next function_body_length cyclomatic_complexity
function_parameter_count`-annotated in the line immediately above its signature — that
attribute comment is untouched by this step and is not part of either block below). Replace the
entire function body — everything from the opening `{` of the signature through its closing
`}` — currently:

```swift
    ) async throws -> Bool {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return false
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
              confirmation.code == 0,
              let leafPair = confirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index") else {
            return false
        }
        let leafParts = leafPair.split(separator: ",")
        guard leafParts.count == 2,
              let vanIdx = UInt32(leafParts[0]),
              let vcIdx = UInt64(leafParts[1]) else {
            return false
        }

        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

        guard let savedBundle = try? await votingCrypto.getVoteCommitmentBundle(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, savedBundle, vcIdx)
        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        var payloads = try await votingCrypto.buildSharePayloads(
            savedBundle.encShares, savedBundle, choice, numOptions, vcIdx, singleShare
        )
        let now = Date().timeIntervalSince1970
        for i in payloads.indices {
            if let deadline = submitAtDeadline, deadline > now {
                payloads[i].submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                payloads[i].submitAt = 0
            }
        }

        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
        shareServerURLs = recoveryResult.remainingServerURLs
        for info in recoveryResult.delegatedShares {
            guard let payload = payloads.first(where: {
                $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
            }) else { continue }
            let blindIdx = Int(info.shareIndex)
            guard blindIdx < savedBundle.shareBlindFactors.count else { continue }
            do {
                let nfHex = try votingCrypto.computeShareNullifier(
                    [UInt8](savedBundle.voteCommitment),
                    info.shareIndex,
                    [UInt8](savedBundle.shareBlindFactors[blindIdx])
                )
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId,
                    info.shareIndex, info.acceptedByServers,
                    [UInt8](votingDataFromHex(nfHex)), payload.submitAt
                )
            } catch {
                LoggerProxy.warn("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
            }
        }
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
        return true
    }
```

with:

```swift
    ) async throws -> Bool {
        guard case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) else {
            return false
        }
        guard let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
              confirmation.code == 0 else {
            return false
        }

        let eventsPayload: [[String: Any]] = confirmation.events.map { event in
            [
                "type": event.type,
                "attributes": event.attributes.map { attribute in
                    ["key": attribute.key, "value": attribute.value]
                }
            ]
        }
        guard let eventsData = try? JSONSerialization.data(withJSONObject: eventsPayload) else {
            return false
        }
        let eventsJson = String(decoding: eventsData, as: UTF8.self)

        guard let voteConfirmation = try? await votingCrypto.confirmVoteSubmission(
            roundId, bundleIndex, proposalId, cachedTxHash, eventsJson
        ) else {
            return false
        }

        guard let stored = try? await votingCrypto.getCommitmentBundleJson(roundId, bundleIndex, proposalId) else {
            LoggerProxy.error(
                """
                Recovered on-chain vote \(proposalId) for bundle \(bundleIndex), \
                but the saved commitment bundle is missing; cannot delegate tally shares.
                """
            )
            throw VotingFlowError.missingVoteCommitmentBundle
        }

        await send(.voteSubmissionStepUpdated(roundId: roundIdAction(), step: .sendingShares))

        // Share count is `singleShare ? 1 : numOptions` — the same two values
        // `zcash_voting::share::recover_payloads` (rc.5 `share.rs:148-188`) slices its own
        // encrypted-share list by, and the same two values Valar's reference wallet (Vizor)
        // resolves client-side rather than asking the crate for a share list: its FRB bridge
        // exposes only the per-index `recovered_vote_share_wire_json` →
        // `zcash_voting::share::recover_wire_json`, never the plural `recover_payloads`. No new
        // FFI symbol; this is the sanctioned pattern on the surface already built.
        let shareCount = singleShare ? 1 : numOptions
        let now = Date().timeIntervalSince1970
        var payloads: [SharePayload] = []
        var submitAtByShareIndex: [UInt32: UInt64] = [:]
        for shareIndex: UInt32 in 0..<shareCount {
            let submitAt: UInt64
            if let deadline = submitAtDeadline, deadline > now {
                submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
            } else {
                submitAt = 0
            }
            submitAtByShareIndex[shareIndex] = submitAt
            let wireJson = try await votingCrypto.recoverWireJson(
                stored.bundleJson, proposalId, shareIndex,
                voteConfirmation.voteCommitmentTreePosition, submitAt
            )
            payloads.append(SharePayload(wireJson: wireJson, shareIndex: shareIndex))
        }

        let recoveryResult = try await Voting.delegateSharesWithFallback(
            payloads,
            roundId: roundId,
            proposalId: proposalId,
            votingAPI: votingAPI,
            serverURLs: shareServerURLs
        )
        shareServerURLs = recoveryResult.remainingServerURLs
        for info in recoveryResult.delegatedShares {
            do {
                try await votingCrypto.recordShareDelegation(
                    roundId, bundleIndex, info.proposalId, info.shareIndex,
                    info.acceptedByServers, submitAtByShareIndex[info.shareIndex] ?? 0
                )
            } catch {
                LoggerProxy.warn("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
            }
        }
        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId, cachedTxHash)
        return true
    }
```

`leaf_index` parsing, `storeVanPosition`, `getVoteCommitmentBundle`/`storeVoteCommitmentBundle`,
and `computeShareNullifier` are gone for the same reasons step 9.9 already removed them from the
main path: `confirmVoteSubmission` persists both positions atomically, and the crate derives the
share nullifier internally now (`## CORRECTIONS` item 13). `choice: VoteChoice` becomes an unused
parameter — left in the signature deliberately (the one call site already supplies it, and Swift
does not error on an unused function parameter); do not remove it or touch the call site as part
of this step. Every `try?`-guarded probe at the top keeps the function's own established idiom
("this recovery shortcut doesn't apply, fall through to a fresh build" is not the same as
swallowing a real error — the un-swallowed slow path re-attempts the identical calls with full
error propagation, satisfying Trap T3 at the system level even though this one fast-path
attempt tolerates a miss).

- [ ] **Step 9B.4: The honest-gate idiom, complete-error-list variant.** The T9 executor found
that a plain `xcodebuild build` stops emitting diagnostics after an early failure threshold,
under-reporting the true remaining count — this is why the coordinator's "16" is the *true* full
count and earlier gates in this plan may have under-counted. For this gate only (not any earlier
task's gates — do not retroactively change them), capture the complete list by temporarily
raising Xcode's own continue-past-errors limit, then revert it explicitly:

```bash
PRIOR_VALUE=$(defaults read com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors 2>/dev/null || echo "__unset__")
defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool YES
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t9b-full-build.log | tail -10; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` is `0` (this is the first gate in the plan expected to be green — Task
10 is assumed already landed per this section's execution-order note). Then, regardless of the
build's outcome, revert immediately — do not leave this set for the rest of the session:

```bash
if [ "$PRIOR_VALUE" = "__unset__" ]; then
    defaults delete com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors
else
    defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool "$PRIOR_VALUE"
fi
```

Then count on the complete log:

```bash
grep -c 'error:' /tmp/chp-t9b-full-build.log || true
```

Expected: **`0`**. Arithmetic: starting truth `16` (8 in Task 10's territory + 6 F3 + 2
`DelegatedShareInfo` residue, per the coordinator's live count) → post-Task-10 expected `8`
(the 6+2 this section owns; Task 10's own gate closes its 8) → post-9B expected `0` (this
section's two workstreams close the remaining 8: workstream 1 closes the 2 residue errors at
`VotingAPIClientLiveKey.swift:430-431`; workstream 2 closes F3's 6 —
`:3428` `storeVoteCommitmentBundle`, `:3431` `buildSharePayloads`, `:3451` the `SharePayload`
shape cascade, `:3465`×2 `recordShareDelegation`'s old signature, `:3471`
`markVoteSubmitted`'s missing `txHash` — all inside the one function this step replaces
wholesale). If the count is not `0`, do not treat any nonzero result as "close enough" — report
the full log tail per this plan's Global Constraint #4 (honest gates, never judged by grep
alone for pass/fail, only for the count once `BUILD_EXIT` itself is already the true signal).

- [ ] **Step 9B.5: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Features/Voting/VotingHelpers.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientInterface.swift secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Resolve F3: rewire tryRecoverInflightVote on the existing per-index recovery surface" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: A3 — hotkey container (`seedPhrase: String` → `storedSecret: Data`)

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` items 5 and 6 first. This task is bigger than "swap one field": it also
repairs `generateHotkey`, `buildVotingPczt`, and `buildAndProveDelegation`, because all three
were broken against the real SDK for hotkey-shaped reasons (item 5), and it catches one more
real bug along the way (step 10.2's note) that the spec never mentioned.

**Files:**
- Modify: `secant/Sources/Dependencies/WalletStorage/StoredVotingHotkey.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorage.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorageInterface.swift`
- Modify: `secant/Sources/Dependencies/WalletStorage/WalletStorageLiveKey.swift`
- Verify (no edit expected): `secant/Sources/Dependencies/WalletStorage/WalletStorageTestKey.swift`
- Modify: `secant/Sources/Dependencies/VotingModels/VotingModels.swift` (`VotingHotkey`)
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift:974-989,1770-1771,2042-2044,2626-2630,2793-2836,3513-3611`

**Interfaces:**
- Consumes: `VotingRustBackend.generateHotkey(networkId: UInt32) throws -> VotingHotkey` (SDK
  model: `storedSecret: [UInt8]`, `rawOrchardAddress: [UInt8]`, `addressIndex: UInt32`);
  `VotingRustBackend.generateDelegationInputs(senderSeed:hotkeyStoredSecret:networkId:
  accountIndex:)` / `(senderFvk:hotkeyStoredSecret:networkId:seedFingerprint:)` (both already
  take `hotkeyStoredSecret`, unaffected by this task's own edits);
  `VotingBuildPcztParams(roundId:bundleIndex:notes:keys: VotingDelegationKeyInputs:
  consensusBranchId:)`; `VotingDelegationProofParams(roundId:bundleIndex:notes:keys:)`.
- Produces: `StoredVotingHotkey(storedSecret: VotingHotkeySecret, version: Int)`;
  `WalletStorage.importVotingHotkey(_ storedSecret: Data, accountId:)`; app-level
  `VotingCryptoClient.generateHotkey(_ networkId: UInt32) async throws -> VotingHotkey`;
  `buildAndProveDelegation` gains a `roundName: String` parameter (see step 10.13).

---

- [ ] **Step 10.1: Give the voting hotkey its own keychain version, independent of the
wallet's.** `Constants.zcashKeychainVersion` (`WalletStorage.swift:39`) is shared with the
regular wallet's `StoredWallet` (`:101`, `:138`) — bumping it would invalidate every user's
*wallet* keychain entry, not just the (currently nonexistent) voting hotkey one. In
`WalletStorage.swift`, replace:

```swift
        static let zcashKeychainVersion = 1
```

with:

```swift
        static let zcashKeychainVersion = 1
        /// Independent from `zcashKeychainVersion`: voting hotkeys have their own storage
        /// generation so a hotkey-format change (like this one) never touches the wallet's own
        /// keychain entry. Bumped 1 → 2 for the `seedPhrase` → `storedSecret` container swap.
        static let zcashVotingHotkeyVersion = 2
```

- [ ] **Step 10.2: Re-shape `StoredVotingHotkey`.** In `StoredVotingHotkey.swift`, replace the
entire file content with:

```swift
//
//  StoredVotingHotkey.swift
//  Zashi
//

import Foundation

struct StoredVotingHotkey: Codable, Equatable {
    let storedSecret: VotingHotkeySecret
    let version: Int

    init(storedSecret: VotingHotkeySecret, version: Int) {
        self.storedSecret = storedSecret
        self.version = version
    }
}

/// Read-only redacted holder for a voting hotkey's stored secret.
///
/// Key material — same handling as `SeedPhrase` (`CHP_DESIGN.md` §0.5): never logged, never
/// printed via reflection. Mirrors `SeedPhrase`'s exact pattern (`Sources/Utils/
/// SensitiveData.swift`) rather than storing bare `Data` on `StoredVotingHotkey`.
struct VotingHotkeySecret: Codable, Equatable, Redactable {
    private let secret: Data

    init(_ secret: Data) {
        self.secret = secret
    }

    /// Returns the raw secret bytes with no `Redactable` protection. Use it only to hand the
    /// bytes to `VotingCryptoClient`/`VotingRustBackend`; never log or print the result.
    func value() -> Data {
        secret
    }
}
```

- [ ] **Step 10.3: Rewrite `importVotingHotkey`/`exportVotingHotkey`.** In
`WalletStorage.swift`, replace:

```swift
    func importVotingHotkey(_ phrase: String, accountId: AccountUUID) throws {
        let hotkey = StoredVotingHotkey(seedPhrase: SeedPhrase(phrase), version: Constants.zcashKeychainVersion)
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        do {
            guard let data = try encode(object: hotkey) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportVotingHotkey(accountId: AccountUUID) throws -> StoredVotingHotkey {
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        let reqData: Data?
        do {
            reqData = try data(forKey: key)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let reqData else { throw WalletStorageError.uninitializedWallet }
        guard let hotkey = try decode(json: reqData, as: StoredVotingHotkey.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        guard hotkey.version == Constants.zcashKeychainVersion else {
            throw WalletStorageError.unsupportedVersion(hotkey.version)
        }
        return hotkey
    }
```

with:

```swift
    func importVotingHotkey(_ storedSecret: Data, accountId: AccountUUID) throws {
        let hotkey = StoredVotingHotkey(
            storedSecret: VotingHotkeySecret(storedSecret),
            version: Constants.zcashVotingHotkeyVersion
        )
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        do {
            guard let data = try encode(object: hotkey) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        } catch KeychainError.duplicate {
            throw WalletStorageError.alreadyImported
        } catch {
            throw WalletStorageError.storageError(error)
        }
    }

    func exportVotingHotkey(accountId: AccountUUID) throws -> StoredVotingHotkey {
        let key = Constants.zcashStoredVotingHotkey(accountId: accountId)
        let reqData: Data?
        do {
            reqData = try data(forKey: key)
        } catch KeychainError.noDataFound {
            throw WalletStorageError.uninitializedWallet
        }
        guard let reqData else { throw WalletStorageError.uninitializedWallet }
        guard let hotkey = try decode(json: reqData, as: StoredVotingHotkey.self) else {
            throw WalletStorageError.uninitializedWallet
        }
        guard hotkey.version == Constants.zcashVotingHotkeyVersion else {
            throw WalletStorageError.unsupportedVersion(hotkey.version)
        }
        return hotkey
    }
```

No migration: a keychain entry written by the old `seedPhrase`-shaped struct fails
`decode(json:as:StoredVotingHotkey.self)` outright (the JSON has no `storedSecret` key), so
`exportVotingHotkey` throws `.uninitializedWallet` — exactly "no hotkey" — with no separate
handling needed (spec `CHP_DESIGN.md` §3/A3: "none exist in the wild").

- [ ] **Step 10.4: Re-type the interface member.** In `WalletStorageInterface.swift`, replace:

```swift
    var importVotingHotkey: @Sendable (_ phrase: String, _ accountId: AccountUUID) throws -> Void
```

with:

```swift
    var importVotingHotkey: @Sendable (_ storedSecret: Data, _ accountId: AccountUUID) throws -> Void
```

- [ ] **Step 10.5: Re-type the LiveKey closure.** In `WalletStorageLiveKey.swift`, replace:

```swift
            importVotingHotkey: { phrase, accountId in
                try walletStorage.importVotingHotkey(phrase, accountId: accountId)
            },
```

with:

```swift
            importVotingHotkey: { storedSecret, accountId in
                try walletStorage.importVotingHotkey(storedSecret, accountId: accountId)
            },
```

- [ ] **Step 10.6: Verify `WalletStorageTestKey.swift` needs no edit.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'importVotingHotkey' secant/Sources/Dependencies/WalletStorage/WalletStorageTestKey.swift
```

Expected: `importVotingHotkey: { _, _ in },` — both parameters already ignored positionally, so
the `String` → `Data` change requires no edit here (`## CORRECTIONS` item 2's same reasoning).

- [ ] **Step 10.7: Re-shape the app-level `VotingHotkey` model.** In `VotingModels.swift`,
replace (lines 257-267):

```swift
struct VotingHotkey: Equatable, Sendable {
    let secretKey: Data
    let publicKey: Data
    let address: String

    init(secretKey: Data, publicKey: Data, address: String) {
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.address = address
    }
}
```

with:

```swift
struct VotingHotkey: Equatable, Sendable {
    /// The material to persist via `WalletStorage.importVotingHotkey(_:accountId:)`. Treat it
    /// as key material, not as an identifier.
    let storedSecret: Data
    /// Raw Orchard address bytes for the hotkey, derived from `storedSecret`.
    let rawOrchardAddress: Data
    /// Address index the hotkey's Orchard address was derived at.
    let addressIndex: UInt32

    init(storedSecret: Data, rawOrchardAddress: Data, addressIndex: UInt32) {
        self.storedSecret = storedSecret
        self.rawOrchardAddress = rawOrchardAddress
        self.addressIndex = addressIndex
    }
}
```

This mirrors the SDK's `VotingHotkey` (`VotingTypes.swift:50-57`) field-for-field except for the
missing displayable address — see step 10.15's finding. `RoundStateInfo.hotkeyAddress: String?`
and `VotingCoordFlow.Action.hotkeyLoaded(roundId:address: String)` are untouched by this step;
step 10.13 is where their input has to come from something, which is exactly the finding.

- [ ] **Step 10.8: Re-type `generateHotkey`.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var generateHotkey: @Sendable (_ roundId: String, _ seed: [UInt8]) async throws -> VotingHotkey
```

with:

```swift
    /// Generate a new voting hotkey for `networkId`. The application must persist the returned
    /// `storedSecret` — it cannot be recovered from the wallet seed (spec `CHP_DESIGN.md` §7.5
    /// leak point 1 / CHP.md §11.5 N... hotkey is app-owned random material, not a wallet-seed
    /// derivation). Calling this again produces an unrelated hotkey, not a recovery of the
    /// previous one.
    var generateHotkey: @Sendable (_ networkId: UInt32) async throws -> VotingHotkey
```

- [ ] **Step 10.9: Re-implement `generateHotkey`.** In `VotingCryptoClientLiveKey.swift`,
replace:

```swift
            generateHotkey: { roundId, seed in
                let backend = try await dbActor.backend()
                let hotkey = try backend.generateHotkey(seed: seed)
                return VotingHotkey(
                    secretKey: Data(hotkey.secretKey),
                    publicKey: Data(hotkey.publicKey),
                    address: hotkey.address
                )
            },
```

with:

```swift
            generateHotkey: { networkId in
                let hotkey = try VotingRustBackend.generateHotkey(networkId: networkId)
                return VotingHotkey(
                    storedSecret: Data(hotkey.storedSecret),
                    rawOrchardAddress: Data(hotkey.rawOrchardAddress),
                    addressIndex: hotkey.addressIndex
                )
            },
```

`VotingRustBackend.generateHotkey(networkId:)` is `static` and takes no database handle
(`VotingRustBackend.swift:1280`) — no `dbActor.backend()` call needed, matching how
`warmProvingCaches`/`computeShareNullifier` (other static members) are already implemented in
this file.

- [ ] **Step 10.10: Rebuild `buildVotingPczt`'s parameter construction.** In the same file,
replace (the whole closure, currently spanning what was originally `:189-267` before Task 8's
edits shifted line numbers upstream — locate by the `buildVotingPczt:` label):

```swift
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeySeed, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                _ = try backend.generateHotkey(seed: hotkeySeed)
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderFvk: [UInt8](orchardFvkOverride),
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                let consensusBranchId: UInt32 = 0xC8E7_1055
                let coinType: UInt32 = networkId == 1 ? 133 : 1
                let result = try backend.buildPczt(VotingBuildPcztParams(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    fvk: actualFvkBytes,
                    hotkeyRawAddress: inputs.hotkeyRawAddress,
                    consensusBranchId: consensusBranchId,
                    coinType: coinType,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName,
                    addressIndex: 0
                ))
                publishState(backend: backend, roundId: roundId)
```

with:

```swift
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderFvk: [UInt8](orchardFvkOverride),
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                // Plan Task 11 replaces this literal with the SDK's public constant.
                let consensusBranchId: UInt32 = 0xC8E7_1055
                let keys = VotingDelegationKeyInputs(
                    fvk: actualFvkBytes,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName
                )
                let result = try backend.buildPczt(VotingBuildPcztParams(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    keys: keys,
                    consensusBranchId: consensusBranchId
                ))
                publishState(backend: backend, roundId: roundId)
```

`VotingDelegationKeyInputs` has no `hotkeyRawAddress` field — `zcash_voting` now derives the
hotkey's Orchard address from `hotkeyStoredSecret` internally (its own doc comment,
`VotingTypes.swift:450-454`), so `inputs.hotkeyRawAddress` is simply not needed here; `coinType`
and `addressIndex` are dropped for the same reason (`VotingBuildPcztParams` never had them —
they were invented fields on a struct literal that never matched the real type). The rest of
the closure (from `let pcztBytes: Data = Data(result.pcztBytes)` through the final `return
VotingPcztResult(...)`) is unchanged — leave it exactly as it stands.

- [ ] **Step 10.11: Rebuild `buildAndProveDelegation`'s parameter construction — and add the
`roundName` it now requires.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeySeed: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

with:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

`VotingDelegationKeyInputs` (bundled into the real `buildAndProveDelegation`'s
`VotingDelegationProofParams`) requires `roundName`, which this member never took — it is added
here as a new, required 8th parameter (both call sites, step 10.14, already have a round name in
scope).

- [ ] **Step 10.12: Re-implement `buildAndProveDelegation`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeySeed, networkId, accountIndex, pirEndpoints, expectedSnapshotHeight in
                AsyncThrowingStream<ProofEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let result = try await backend.buildAndProveDelegation(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                hotkeyRawAddress: inputs.hotkeyRawAddress,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                networkId: networkId,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            // Don't call publishState here — the Rust FFI may still hold
                            // a brief RefCell borrow on the DB connection, and publishState
                            // borrows it again. Let the store call refreshState after
                            // receiving .completed to avoid the concurrent borrow panic.
                            continuation.yield(.completed(Data(result.proof)))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
```

with:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight in
                AsyncThrowingStream<ProofEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let keys = VotingDelegationKeyInputs(
                                fvk: inputs.fvkBytes,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                seedFingerprint: inputs.seedFingerprint,
                                accountIndex: accountIndex,
                                roundName: roundName
                            )
                            let params = VotingDelegationProofParams(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                keys: keys
                            )
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            // Don't call publishState here — the Rust FFI may still hold
                            // a brief RefCell borrow on the DB connection, and publishState
                            // borrows it again. Let the store call refreshState after
                            // receiving .completed to avoid the concurrent borrow panic.
                            continuation.yield(.completed(Data(result.proof)))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
```

(This is where SDK-lane Task 1's `pirLayout:` parameter will also land — plan Task 12 adds it
on top of this same closure; do not add it here.)

- [ ] **Step 10.13: Rewire the hotkey load-or-generate site.** In
`VotingCoordFlowCoordinator.swift` (`:974-989` at plan-writing time — Tasks 8 and 9 already
edited this same file above this point in the ladder, so treat that line range as a hint and
the unique code block below as the authoritative locator), replace:

```swift
                    let phrase: String
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        phrase = stored.seedPhrase.value()
                    } else {
                        phrase = try mnemonic.randomMnemonic()
                        try walletStorage.importVotingHotkey(phrase, accountId)
                    }
                    let seed = try mnemonic.toSeed(phrase)
                    let hotkey = try await votingCrypto.generateHotkey(roundId, seed)
                    await send(.hotkeyLoaded(roundId: roundId, address: hotkey.address))
```

with:

```swift
                    let storedSecret: Data
                    if let stored = try? walletStorage.exportVotingHotkey(accountId) {
                        storedSecret = stored.storedSecret.value()
                    } else {
                        let hotkey = try await votingCrypto.generateHotkey(networkId)
                        storedSecret = hotkey.storedSecret
                        try walletStorage.importVotingHotkey(storedSecret, accountId)
                    }
                    await send(.hotkeyLoaded(roundId: roundId, address: ""))
```

`mnemonic.randomMnemonic()`/`mnemonic.toSeed(_:)` are no longer needed here: the SDK generates
the secret's randomness internally now (`VotingRustBackend.generateHotkey(networkId:)`'s own doc
comment — no seed in), so the app no longer produces or derives one for this purpose. The
`address: ""` is step 10.15's finding surfacing directly in the diff rather than being silently
dropped — see that step before treating this line as final.

- [ ] **Step 10.14: Delete the four remaining `mnemonic.toSeed` hotkey-derivation sites.** In
the same file, replace each of the following four two-line derivations with the one-line
`storedSecret` read shown, leaving every other line in each surrounding block untouched. Same
caveat as step 10.13: the four line numbers below (`:1770-1771`/`:2043-2044`/`:2629-2630`/
`:2835-2836`) are plan-writing-time hints, not guarantees — Tasks 8 and 9 already edited this
file above these points, so locate each site by its unique two-line snippet, not by number.

At `:1770-1771` (inside the batch vote-submission `.run` closure):

```swift
            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2043-2044` (inside `reduceMaybeStartDelegationPrecompute`'s `.run` closure):

```swift
            let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
            let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
            let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2629-2630` (inside the Keystone PCZT-prep `.run` closure):

```swift
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

At `:2835-2836` (inside `reduceKeystoneAllBundlesSigned`'s `.run` closure — note the sender-seed
derivation on the two lines immediately above this one, `:2833-2834`, is a **different** value,
the wallet's own seed, and is explicitly not touched by this task):

```swift
                let hotkeyPhrase = try walletStorage.exportVotingHotkey(accountId).seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
```

→

```swift
                let hotkeySeed = try [UInt8](walletStorage.exportVotingHotkey(accountId).storedSecret.value())
```

Then, in `reduceKeystoneAllBundlesSigned` (the same function as the fourth site above), add the
`roundName` local variable step 10.11's new parameter needs — replace:

```swift
        let bundleCount = session.bundleCount
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
```

with:

```swift
        let bundleCount = session.bundleCount
        let roundName = activeSession.title
        let storedSignatures = session.keystoneBundleSignatures.sorted { $0.bundleIndex < $1.bundleIndex }
```

(`activeSession` is already in scope in this function, bound a few lines above at
`guard let activeSession = state.allRounds.first(where: { $0.id == roundId })?.session else`.)
Then, in the same function's `buildAndProveDelegation` call, replace:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

with:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

Finally, in `runDelegationPipeline` (`static func`, `:3513-3611`), which already receives
`roundName: String` as its own parameter, replace its `buildAndProveDelegation` call:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

with:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

(`runDelegationPipeline`'s own `hotkeySeed` parameter is untouched by this task's four
derivation-site edits above — it is a function parameter supplied by its one caller, the batch
vote-submission closure at `:1770-1771`, and now carries the stored secret transparently once
that call site's own local is fixed.)

- [ ] **Step 10.15: STOP-and-report — the hotkey display-address encoding gap (finding, not a
code step).** Read `## CORRECTIONS` item 6. `RoundStateInfo.hotkeyAddress: String?`
(`VotingModels.swift:157`) and `VotingCoordFlow.Action.hotkeyLoaded(roundId:address: String)`
(`VotingCoordFlowStore.swift:264`, consumed at `VotingCoordFlowCoordinator.swift:1096`) both
require a human-displayable address string. The SDK's `VotingHotkey.rawOrchardAddress` is raw
bytes, and no encoder from raw Orchard address bytes to a UA/address string exists anywhere in
`secant/Sources/` or `zcash-swift-wallet-sdk/Sources/` at plan-writing time (`## CORRECTIONS`
item 6's grep).

Decision procedure:
1. Grep one more time, scoped to what actually landed: `grep -rn 'OrchardAddress\|unified.*[Aa]ddress.*encod\|encode.*[Aa]ddress' Sources/ZcashLightClientKit/` in the SDK worktree, and
   `grep -rn 'UnifiedAddress\|orchardReceiver' secant/Sources/Dependencies/SDKSynchronizer/` in the app. If
   a general Orchard/UA encoder now exists that takes raw receiver bytes, use it at step
   10.13's `await send(.hotkeyLoaded(roundId: roundId, address: ...))` call and remove the
   `address: ""` placeholder there.
2. If not: leave `address: ""` exactly as step 10.13 wrote it (a real empty string, not a
   crash — `hotkeyAddress` is already `String?`-shaped for a reason and every read site treats
   absence as "unknown", not as an error) and surface as a named, non-blocking finding: *"the
   voting hotkey's displayable address has no encoder under the 2.0 API; UI that shows it will
   render blank until one is added — this is the app rendering an engine value verbatim (per
   the no-corrections rule), not the app inventing one."* Confirm at review time that no screen
   this plan is required to leave frozen depends on this string being non-empty for correctness
   (only for display) before accepting the empty string as adequate for gate 5.

- [ ] **Step 10.16: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t10-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t10-build.log || true
```

Expected: a number, strictly less than Step 9.12's count (exit status not judged).
`seedPhrase\|mnemonic.toSeed.*hotkey` must not appear in the log at any of the four sites step
10.14 touched.

- [ ] **Step 10.17: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/WalletStorage/StoredVotingHotkey.swift secant/Sources/Dependencies/WalletStorage/WalletStorage.swift secant/Sources/Dependencies/WalletStorage/WalletStorageInterface.swift secant/Sources/Dependencies/WalletStorage/WalletStorageLiveKey.swift secant/Sources/Dependencies/VotingModels/VotingModels.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Swap the voting hotkey container from a seed phrase to a stored secret" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: A4 — Ironwood branch-ID fix

*Code blocks by: Sonnet (app delegate).*

**Files:**
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`

**Interfaces:**
- Consumes: `public extension ZcashSDK { static let nu63ConsensusBranchID: ConsensusBranchID }`
  (SDK-lane Task 4; `ConsensusBranchID = Int32`, per `## INTERFACES-FOR-APP`: *"the app's
  `VotingBuildPcztParams.consensusBranchId` is `UInt32`, so the app converts with
  `UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)`"* — confirmed against the real
  `VotingBuildPcztParams.consensusBranchId: UInt32` (`VotingTypes.swift:488`).
- Produces: no public surface change — internal literal only.

---

- [ ] **Step 11.1: Replace the hardcoded branch ID.** In
`VotingCryptoClientLiveKey.swift`, inside the `buildVotingPczt` closure Task 10's step 10.10
rebuilt, replace:

```swift
                // NU6 consensus branch ID; BIP44 coin type 133 = Zcash mainnet, 1 = testnet
                // (`network_id` 1 / 0 per `parse_network` in libzcashlc).
                // Plan Task 11 replaces this literal with the SDK's public constant.
                let consensusBranchId: UInt32 = 0xC8E7_1055
```

with:

```swift
                // Ironwood (NU6.3) consensus branch ID, published by the SDK so a future
                // network upgrade cannot go stale here the way the old hardcoded NU6 literal
                // did (CHP.md §11.5 N1).
                let consensusBranchId = UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)
```

- [ ] **Step 11.2: Single-source assert.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -rn '0xC8E7_1055\|0xC8E71055' secant/
```

Expected: no output. Any hit means the literal survives somewhere this task didn't reach
(check `zodlTests/` too — a hit there is a deviation to surface, not silently port).

- [ ] **Step 11.3: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift && git commit -m "[MOB-1678] Fix the hardcoded NU6 consensus branch ID to Ironwood (NU6.3)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: A5 — decode `pir_layout` + plumb to PIR entry points

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` item 9 first — `PirSnapshotResolver`'s `pir_depth` field is unrelated
decode, not "half" of this one. This task also fixes a pre-existing bug in
`precomputeDelegationPir`'s `LiveKey` closure it happens to touch (a `networkId:` argument the
real SDK function has never taken) — noted inline at step 12.5, not silently ported.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingModels/VotingServiceConfig.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift`
- Modify: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift`
- Modify: `secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift` (both `precomputeDelegationPir` and `buildAndProveDelegation` call sites)

**Interfaces:**
- Consumes: `VotingRustBackend.precomputeDelegationPir(...pirLayout: VotingPirLayout = .unknown...)` and `.buildAndProveDelegation(_:...pirLayout: VotingPirLayout = .unknown...)` (SDK-lane Task 1; default is fail-closed — `## INTERFACES-FOR-APP`: *"Leaving it at `.unknown` makes every PIR call throw"*).
- Produces: `VotingServiceConfig.pirLayout: VotingServiceConfig.PirLayout` (required, top-level, `pir_depth`/`tier0_layers`/`tier1_layers`); both app-level `VotingCryptoClient` PIR members gain three trailing `UInt32` parameters.

---

- [ ] **Step 12.1: Decode `pir_layout`.** In `VotingServiceConfig.swift`, replace:

```swift
struct VotingServiceConfig: Codable, Equatable, Sendable {
    let configVersion: Int
    let voteServers: [ServiceEndpoint]
    let pirEndpoints: [ServiceEndpoint]
    let supportedVersions: SupportedVersions
    let rounds: [String: RoundEntry]

    struct ServiceEndpoint: Codable, Equatable, Sendable {
```

with:

```swift
struct VotingServiceConfig: Codable, Equatable, Sendable {
    let configVersion: Int
    let voteServers: [ServiceEndpoint]
    let pirEndpoints: [ServiceEndpoint]
    let supportedVersions: SupportedVersions
    let rounds: [String: RoundEntry]
    /// PIR tree geometry the round's dynamic config advertises. Required, not optional:
    /// `zcash_voting` (rc.4+) runs a config/server layout handshake and fails closed before
    /// any private query if a caller's layout disagrees with what the PIR server serves, so a
    /// wallet that cannot decode this has nothing safe to fall back to.
    let pirLayout: PirLayout

    /// Mirrors `zcash_voting::config::PirLayout` field for field.
    struct PirLayout: Codable, Equatable, Sendable {
        let pirDepth: UInt32
        let tier0Layers: UInt32
        let tier1Layers: UInt32

        enum CodingKeys: String, CodingKey {
            case pirDepth = "pir_depth"
            case tier0Layers = "tier0_layers"
            case tier1Layers = "tier1_layers"
        }

        init(pirDepth: UInt32, tier0Layers: UInt32, tier1Layers: UInt32) {
            self.pirDepth = pirDepth
            self.tier0Layers = tier0Layers
            self.tier1Layers = tier1Layers
        }
    }

    struct ServiceEndpoint: Codable, Equatable, Sendable {
```

Then, in the same file, replace the memberwise `init` and `CodingKeys` (lines 68-90):

```swift
    init(
        configVersion: Int,
        voteServers: [ServiceEndpoint],
        pirEndpoints: [ServiceEndpoint],
        supportedVersions: SupportedVersions,
        rounds: [String: RoundEntry]
    ) {
        self.configVersion = configVersion
        self.voteServers = voteServers
        self.pirEndpoints = pirEndpoints
        self.supportedVersions = supportedVersions
        self.rounds = rounds
    }

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case voteServers = "vote_servers"
        case pirEndpoints = "pir_endpoints"
        case supportedVersions = "supported_versions"
        case rounds
    }

}
```

with:

```swift
    init(
        configVersion: Int,
        voteServers: [ServiceEndpoint],
        pirEndpoints: [ServiceEndpoint],
        supportedVersions: SupportedVersions,
        rounds: [String: RoundEntry],
        pirLayout: PirLayout
    ) {
        self.configVersion = configVersion
        self.voteServers = voteServers
        self.pirEndpoints = pirEndpoints
        self.supportedVersions = supportedVersions
        self.rounds = rounds
        self.pirLayout = pirLayout
    }

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case voteServers = "vote_servers"
        case pirEndpoints = "pir_endpoints"
        case supportedVersions = "supported_versions"
        case rounds
        case pirLayout = "pir_layout"
    }

}
```

A config JSON missing `pir_layout` now fails `Decodable` synthesis outright ("keyNotFound") —
this is the "REQUIRES" from spec `CHP_DESIGN.md` §2.4/A5, enforced by the type system rather
than a separate runtime check, matching how `configVersion`/`voteServers`/etc. are already
enforced in this same struct.

- [ ] **Step 12.2: Thread `pirLayout` into `precomputeDelegationPir`'s interface + fix its
pre-existing `networkId:` bug.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var precomputeDelegationPir: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32
    ) async throws -> DelegationPirPrecomputeResult
```

with:

```swift
    var precomputeDelegationPir: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ networkId: UInt32,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32
    ) async throws -> DelegationPirPrecomputeResult
```

- [ ] **Step 12.3: Re-implement `precomputeDelegationPir`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    networkId: networkId
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
```

with:

```swift
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId, pirDepth, tier0Layers, tier1Layers in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers)
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
```

`networkId` stays a parameter of the app-level member (its one call site already passes it, and
removing it would be an unrelated interface shrink this task does not need to make) — it is
simply no longer forwarded to `backend.precomputeDelegationPir`, because the real function has
never taken it (verified: `VotingRustBackend.swift:138-145`; the old code's `networkId:`
argument was never valid against this SDK generation).

- [ ] **Step 12.4: Thread `pirLayout` into `buildAndProveDelegation` — on top of Task 10's
`roundName` addition.** In `VotingCryptoClientInterface.swift`, replace:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

with:

```swift
    var buildAndProveDelegation: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ bundleNotes: [NoteInfo],
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String,
        _ pirEndpoints: [String],
        _ expectedSnapshotHeight: UInt64,
        _ pirDepth: UInt32,
        _ tier0Layers: UInt32,
        _ tier1Layers: UInt32
    ) -> AsyncThrowingStream<ProofEvent, Error>
        = { _, _, _, _, _, _, _, _, _, _, _, _, _ in AsyncThrowingStream { $0.finish() } }
```

- [ ] **Step 12.5: Re-implement `buildAndProveDelegation`.** In
`VotingCryptoClientLiveKey.swift`, replace:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight in
```

with:

```swift
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight, pirDepth, tier0Layers, tier1Layers in
```

Then, in the same closure, replace:

```swift
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
```

with:

```swift
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers),
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
```

- [ ] **Step 12.6: Thread the resolved layout through the three coordinator call sites.** In
`VotingCoordFlowCoordinator.swift`, in `reduceMaybeStartDelegationPrecompute`, replace:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }
```

with:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url).nonEmpty,
            let pirLayout = state.serviceConfig?.pirLayout,
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount),
            let accountId = state.selectedWalletAccount?.id
        else {
            return .none
        }
```

then, in the same function's `.run` closure, replace:

```swift
                let result = try await votingCrypto.precomputeDelegationPir(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    pirEndpoints,
                    expectedSnapshotHeight,
                    networkId
                )
```

with:

```swift
                let result = try await votingCrypto.precomputeDelegationPir(
                    roundId,
                    bundleIndex,
                    bundleNotes,
                    pirEndpoints,
                    expectedSnapshotHeight,
                    networkId,
                    pirLayout.pirDepth,
                    pirLayout.tier0Layers,
                    pirLayout.tier1Layers
                )
```

(`pirLayout` must be added to this `.run`'s capture list alongside `[votingCrypto, mnemonic,
walletStorage]` for the closure to see it.)

In `reduceKeystoneAllBundlesSigned`, replace:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
            !pirEndpoints.isEmpty,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
```

with:

```swift
        guard
            let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
            !pirEndpoints.isEmpty,
            let pirLayout = state.serviceConfig?.pirLayout,
            let accountId = state.selectedWalletAccount?.id
        else {
            LoggerProxy.error("serviceConfig/selectedAccount unexpectedly nil during Keystone delegation proof")
            return .none
        }
```

then, in the same function's `buildAndProveDelegation` call (as rewritten by Task 10's step
10.14), replace:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight
                    ) {
```

with:

```swift
                    for try await event in votingCrypto.buildAndProveDelegation(
                        roundId,
                        bundleIdx,
                        bundleNotes,
                        senderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        pirEndpoints,
                        expectedSnapshotHeight,
                        pirLayout.pirDepth,
                        pirLayout.tier0Layers,
                        pirLayout.tier1Layers
                    ) {
```

(`pirLayout` must be added to this function's `.run` capture list, `[backgroundTask,
votingCrypto, votingAPI, mnemonic, walletStorage]`.)

Finally, `runDelegationPipeline` (`static func`) needs the layout as three new parameters —
replace its signature:

```swift
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
```

with:

```swift
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        pirDepth: UInt32,
        tier0Layers: UInt32,
        tier1Layers: UInt32,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
```

its `buildAndProveDelegation` call (as rewritten by Task 10's step 10.14):

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight
                ) {
```

with:

```swift
                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                    pirEndpoints, expectedSnapshotHeight, pirDepth, tier0Layers, tier1Layers
                ) {
```

and its one call site (inside the batch vote-submission `.run` closure, `:1778-1793`):

```swift
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
```

with:

```swift
                    try await Self.runDelegationPipeline(
                        roundId: roundId,
                        cachedNotes: cachedNotes,
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        roundName: roundName,
                        pirEndpoints: pirEndpoints,
                        expectedSnapshotHeight: expectedSnapshotHeight,
                        pirDepth: pirLayout.pirDepth,
                        tier0Layers: pirLayout.tier0Layers,
                        tier1Layers: pirLayout.tier1Layers,
                        delegationPrepared: delegationPrepared,
                        seedFingerprint: seedFingerprint,
                        votingCrypto: votingCrypto,
                        votingAPI: votingAPI,
                        send: send
                    )
```

which requires `pirLayout` to be resolved earlier in that same enclosing reducer function
(alongside wherever `pirEndpoints`/`roundName` are already resolved for this call site) — locate
the `guard`/`let` that currently produces `pirEndpoints` for this call site and add
`let pirLayout = state.serviceConfig?.pirLayout` to it the same way step 12.6 did for the other
two sites; if no such single `guard` exists here (this call site may resolve `pirEndpoints` from
a different local than the other two), add the binding at the nearest point before this call
where `state`/`serviceConfig` is still reachable, failing the action with the same "serviceConfig
unexpectedly nil" pattern used at the other two sites if it is not.

- [ ] **Step 12.7: Prove no production call site was left on the fail-closed default.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'votingCrypto.precomputeDelegationPir(\|votingCrypto.buildAndProveDelegation(\|runDelegationPipeline(' secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift
```

For every `precomputeDelegationPir(`/`buildAndProveDelegation(` hit, manually confirm (by
reading the surrounding 15 lines) that the call passes `pirLayout.pirDepth`/
`.tier0Layers`/`.tier1Layers` (or, for `runDelegationPipeline`, `pirDepth:`/`tier0Layers:`/
`tier1Layers:`) and not a bare literal or an omitted argument. Any call site missing them is a
real bug this step must fix before proceeding — the app-level members have no default, so a
missed site is a compile error, not a silent fail-closed at runtime; if a *compile* error, it
surfaces at step 12.8 anyway.

- [ ] **Step 12.8: Progress gate.** Same two-command idiom as Step 8.13. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t12-build.log | tail -5; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT` still non-zero. Then:

```bash
grep -c 'error:' /tmp/chp-t12-build.log || true
```

Expected: a number, strictly less than Step 10.16's count (exit status not judged).

- [ ] **Step 12.9: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingModels/VotingServiceConfig.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientInterface.swift secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift secant/Sources/Features/CoordFlows/VotingCoordFlow/VotingCoordFlowCoordinator.swift && git commit -m "[MOB-1678] Decode pir_layout and thread it through the PIR entry points" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: A6 — static-config re-pin

*Code blocks by: Sonnet (app delegate).*

The URL below is verified two independent ways (`## VERIFICATION EVIDENCE`) — Android's actual
shipped diff (`gh pr diff 2406 --repo zodl-inc/zodl-android`) and an independent live
`curl` + `shasum -a 256` — and they agree byte-for-byte. No placeholder.

**Files:**
- Modify: `secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift:11-13`

**Interfaces:**
- Consumes: nothing (a literal only).
- Produces: `StaticVotingConfig.bundledPinnedSource: String`, unchanged type/usage — only the
  value changes.

---

- [ ] **Step 13.1: Replace the pinned fallback URL.** In `StaticVotingConfig.swift`, replace:

```swift
    static let bundledPinnedSource =
        "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/2785311d45758e85567d70a1f13709fa01b62c6b/prod/static-voting-config.json" +
        "?checksum=sha256:bed0116f961226b256a574b52461ce81d9f5294a57e190987dc155f07eb1e431"
```

with:

```swift
    static let bundledPinnedSource =
        "https://voting.valargroup.org/prod/static-voting-config.json" +
        "?checksum=sha256:c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d"
```

This moves the pin from a commit-pinned `raw.githubusercontent.com` snapshot to the live
checksummed URL, mirroring Android's `bugfix/MOB-1678` app PR (#2406) exactly — same host, same
path, same checksum. `PinnedConfigSource.parse(_:)` (`StaticVotingConfig.swift:143-185`, this
task does not touch it) already strips the `?checksum=sha256:...` query item and verifies the
remaining bytes against it (`StaticVotingConfig.decodeAndVerify(data:expectedSHA256:)`,
`:82-101`) — this string is consumed exactly the same way as the URL it replaces, so no other
code in this file changes.

- [ ] **Step 13.2: Re-verify the live content matches the pinned checksum, right before
committing.** Run:

```bash
curl -s -o /tmp/chp-t13-verify.json -w "HTTP_STATUS=%{http_code}\n" "https://voting.valargroup.org/prod/static-voting-config.json" && shasum -a 256 /tmp/chp-t13-verify.json
```

Expected: `HTTP_STATUS=200` and
`c06f1dfa2f0a30b3614aefcf00ac7e31d61ebc3cf551b3031d1b194232d1056d /tmp/chp-t13-verify.json`. If
the hash has changed since this plan was written (Valar rotated the live config between
plan-writing and execution), **STOP**: do not commit a stale checksum — recompute both the hash
and the constructed URL, re-verify HTTP 200 on the newly-constructed URL, and use the fresh
value instead of the one in step 13.1's code block.

- [ ] **Step 13.3: Confirm the string builds and decodes.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n 'bundledPinnedSource' -A2 secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift
```

Expected: the two-line concatenation from step 13.1, verbatim. (A dedicated
`swift build`/`xcodebuild` gate is unnecessary for this task alone — it is a single string
literal with no signature change; it rides Task 14's full build instead.)

- [ ] **Step 13.4: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift && git commit -m "[MOB-1678] Re-pin the static voting config to the live checksummed URL" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 14: Zero errors + the app voting tests return (gate 5)

*Code blocks by: Sonnet (app delegate).*

Read `## CORRECTIONS` item 8 in full before starting — the "5 files return unmodified" premise
is false in **two** independent ways, and this task's step 14.2 is a headline correction, not a
routine verification.

**Files:**
- Modify: `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift:1025`
- Modify: `zodlTests/VotingTests/VotingServiceConfigTests.swift:931-948`

**Interfaces:**
- Consumes: the unified `VotingCryptoClient.getDelegationSubmission(roundId:bundleIndex:
  signature:sighash:)` (Task 8) and the re-shaped `SharePayload { wireJson: String, shareIndex:
  UInt32 }` (Task 9).
- Produces: nothing new — this task only restores the two test files to compiling against
  Tasks 8–13's real shapes.

---

- [ ] **Step 14.1: Fresh full build — assert the error list is now empty.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t14-build.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, tail ends with `** BUILD SUCCEEDED **`. If any error remains, it is
either (a) one of the two explicit findings this plan carried forward and never resolved (the
software delegation-signing gap, `## CORRECTIONS` item 4 / Task 8 step 8.14; the hotkey-address
encoding gap, `## CORRECTIONS` item 6 / Task 10 step 10.15; the `tryRecoverInflightVote`
share-index gap, Task 9 step 9.13) — in which case this is the point those findings block gate 5
and must be resolved (not re-guessed) before continuing — or (b) a genuinely new error this plan
did not anticipate, which is its own finding: report the full log tail, do not patch around it
silently.

- [ ] **Step 14.2: Fix `VotingCoordFlowCoordinatorTests.swift` — the Keystone stub rename.**
In `zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift`, replace:

```swift
        dependencies.votingCrypto.getDelegationSubmissionWithKeystoneSig = { _, bundleIndex, sig, sighash in
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(
                rk: Data(repeating: UInt8(bundleIndex + 3), count: 32),
                spendAuthSig: sig,
                sighash: sighash
            )
        }
```

with:

```swift
        dependencies.votingCrypto.getDelegationSubmission = { _, bundleIndex, sig, sighash in
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(
                rk: Data(repeating: UInt8(bundleIndex + 3), count: 32),
                spendAuthSig: sig,
                sighash: sighash
            )
        }
```

Positionally mechanical: the closure body is untouched, only the member name changes, matching
Task 8 step 8.4/8.9's unification exactly (both the old member and the new one take
`(_, bundleIndex, sig, sighash)` in the same order).

- [ ] **Step 14.3: Fix `VotingServiceConfigTests.swift` — the `SharePayload` construction
helper.** In `zodlTests/VotingTests/VotingServiceConfigTests.swift`, replace:

```swift
private func makeRecoverySharePayload(index: UInt32 = 0) -> SharePayload {
    let share = EncryptedShare(
        c1: Data(repeating: UInt8(index + 1), count: 32),
        c2: Data(repeating: UInt8(index + 2), count: 32),
        shareIndex: index
    )
    return SharePayload(
        sharesHash: Data(repeating: 0x01, count: 32),
        proposalId: 1,
        voteDecision: 0,
        encShare: share,
        treePosition: 10,
        allEncShares: [share],
        shareComms: [Data(repeating: 0x03, count: 32)],
        primaryBlind: Data(repeating: 0x04, count: 32),
        submitAt: 99
    )
}
#endif
```

with:

```swift
private func makeRecoverySharePayload(index: UInt32 = 0) -> SharePayload {
    SharePayload(
        wireJson: "{\"share_index\":\(index),\"submit_at\":99}",
        shareIndex: index
    )
}
#endif
```

The `wireJson` content is test fixture data, not something any assertion in this file inspects
(verified: `## CORRECTIONS` item 8 — every one of the 7 call sites checks only
`recorder.servers()`/`acceptedServers`/`result.delegatedShares`/`.remainingServerURLs`, never
the POST body); it only needs to be well-formed enough that `sharePostBody`'s
`JSONSerialization.jsonObject(with:)` (Task 9 step 9.7) does not throw when a test path happens
to exercise it. No other line in this file changes — `EncryptedShare` stays defined and used
elsewhere in the file for unrelated fixtures; do not remove it.

- [ ] **Step 14.4: Re-run the broader grep to confirm no third file needs a change.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && grep -n "buildVoteCommitment\|signCastVote\|buildSharePayloads\|encryptShares\|decomposeWeight\|storeCommitmentBundle\|storeVoteCommitmentBundle\|getDelegationSubmissionWithKeystoneSig\|VotingSharePayload\|SharePayload(\|resubmitSharePayload\|delegateSharePayloads\|recordShareDelegation(.*nullifier\|\.markVoteSubmitted([^,]*,[^,]*,[^,)]*)\|seedPhrase\|StoredVotingHotkey(" zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift zodlTests/VotingTests/VotingSessionTests.swift zodlTests/VotingTests/VotingHelpersTests.swift zodlTests/VotingTests/VotingAPIResponseParserTests.swift zodlTests/VotingTests/VotingServiceConfigTests.swift
```

Expected, exactly: the two fixed-in-place occurrences from steps 14.2/14.3 (now using the new
names/shapes, so this pattern still matches their *presence* — read each hit and confirm it is
the corrected form, not a third stale usage). Any hit that is still the *old* member name or the
*old* 9-field `SharePayload` shape is a third file/site this task must also fix before
proceeding — do not defer it.

- [ ] **Step 14.5: Full internal-scheme test run.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:zodlTests/VotingTests 2>&1 | tee /tmp/chp-t14-votingtests.log | tail -20; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** TEST SUCCEEDED **`. If `-only-testing:zodlTests/VotingTests` is
rejected (the scheme's test plan may not expose that path — verify the exact target/class path
with `xcodebuild test -scheme zodl-internal -showBuildTimingSummary -list` or by reading
`zodlTests.xctestplan` first), fall back to the full suite:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t14-fulltests.log | tail -30; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** TEST SUCCEEDED **`. Either way, confirm the log shows the five
`VotingTests` classes actually ran (not skipped) —
`grep -c "Test Suite 'Voting" /tmp/chp-t14-*.log` should be ≥ 5.

- [ ] **Step 14.6: Commit the test fixes.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add zodlTests/VotingTests/VotingCoordFlowCoordinatorTests.swift zodlTests/VotingTests/VotingServiceConfigTests.swift && git commit -m "[MOB-1678] Port the two voting test files off the deleted Keystone member and the old SharePayload shape" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 14.7: First push.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git push origin chp-re-enable
```

Expected: the push succeeds (no force needed — this is the branch's first push in this
campaign, per `CHP_PLAN.md`'s workspace table: zodl pushes to `origin` at T14/T16). Report the
resulting commit range (`git log --oneline origin/chp-re-enable@{upstream}..HEAD` before the
push, or the pushed range from the `git push` output) so the orchestrator can cross-reference it
against `CHP_PLAN.md` Task 16's wrap-up log.

---

### Task 15: Standing gates + conformance sweep (gate 6)

*No code blocks (commands only) — orchestrator-authored.*

**Files:** none modified.

- [ ] **Step 15.1: Internal scheme full test run.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild test -scheme zodl-internal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/chp-t15-internal.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** TEST SUCCEEDED **` in the tail.

- [ ] **Step 15.2: Testnet generic device build.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && set -o pipefail; xcodebuild build -scheme zodl-testnet -destination 'generic/platform=iOS' 2>&1 | tee /tmp/chp-t15-testnet.log | tail -3; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `** BUILD SUCCEEDED **`. (This links the ios-device slice — T5's
full build covered it.)

- [ ] **Step 15.3: UI-freeze + trace audit.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git diff fea8d600 --name-only | grep -c 'xcstrings'; git diff fea8d600 --name-only | grep -v '^CHP\|^docs/' | sort
```

Expected: xcstrings count **0** (UI freeze held); every listed file traces to exactly one
lettered item in `CHP_DESIGN.md` §3 (the reviewer's diff-check rule, §7). Any file that
doesn't → deviation, surface it.

- [ ] **Step 15.4: Lint.** Run SwiftLint the way this repo's CI does (see `.swiftlint.yml`
at the zodl repo root):

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && swiftlint --quiet 2>&1 | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, no new violations against changed files.

---

### Task 16: Wrap-up — logs, hand-offs, the human list

*No code blocks (markdown + commands only) — orchestrator-authored.*

**Files:**
- Modify: `CHP.md` (§10 log + status line)

- [ ] **Step 16.1: Log the campaign state.** Add a §10 row to `CHP.md`: date, "EXECUTION
COMPLETE T0–T15", the zodl + SDK HEAD SHAs, gate results one line each. Update the status
line at the top of §0 accordingly. Commit:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zodl-ios && git add CHP.md CHP_PLAN.md && git commit -m "[MOB-1678] CHP: execution complete through gate 6 — log + plan checkboxes" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git push origin chp-re-enable
```

- [ ] **Step 16.2: The SDK push (Lukas, by hand).** The SDK worktree's remote is
push-guarded by design. Hand Lukas exactly this:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git log --oneline a3823651..HEAD && git push <his-writable-remote> chp-re-enable
```

- [ ] **Step 16.3: Gate 7 hand-off (humans).** The testnet E2E round is the exit gate and is
not delegate-executable. Hand over: the §5.7 matrix (multi-bundle software AND Keystone
delegation, vote, confirmation, shares, crash-recovery mid-flow, share resubmission), plus
the three QA preconditions from `CHP_DESIGN.md` §4 item 4 (test round serves `pir_layout`;
a testnet round or crate local-PIR harness is needed; `zvote.zodl.com` is ours). Remaining
human decisions: Q6, R5, Q3, Q5, CEO-5 (`CHP_DESIGN.md` §6) — production flag stays off
until Q6 + R5 rule.

---

## Post-plan checklist (orchestrator)

- [ ] Every task report archived; deviations surfaced to Lukas, none absorbed.
- [ ] Upstream PRs for the T3 passthroughs opened against `zcash/zcash-swift-wallet-sdk`
      main (spec S4 follow-up; Android precedent).
- [ ] Debt register untouched work re-confirmed deferred (`CHP_DESIGN.md` §6).
