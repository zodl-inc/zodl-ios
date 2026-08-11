# CHP_PLAN — SDK lane (Tasks 1–4)

Authored by the Opus SDK delegate. Every code block below was written by this delegate and is
spliced verbatim into `CHP_PLAN.md`. Tasks 1–3 were additionally **executed and compiled** in a
throwaway git worktree of `zcash-swift-wallet-sdk @ a3823651` before being written down; see
`## PROBE EVIDENCE`.

---

## CORRECTIONS

Spec/skeleton claim vs. tree reality. Reality wins in every row below; the tasks implement reality.

1. **`${PIPESTATUS[0]}` is empty in this environment — the "honest gate" idiom silently reports
   nothing.** The tool shell here is **zsh 5.9**, where `PIPESTATUS` does not exist (`pipestatus`,
   1-indexed, does). Verified:
   `false | tee /dev/null >/dev/null; echo "[${PIPESTATUS[0]}]"` → `[]`, while the same line under
   `bash -c` → `[1]`. So `CHP_PLAN.md`'s Global constraint 4 and skeleton steps **0.4, 5.1, 6.1,
   6.2, 15.1, 15.2** print `REAL_EXIT=` (empty) on both success and failure — a failing gate reads
   as "not non-zero". Portable replacement used throughout my tasks, verified in both shells:
   `set -o pipefail; <cmd> 2>&1 | tee <log> | tail -N; echo "REAL_EXIT=$?"`.
   **Recommend the orchestrator apply the same substitution to Tasks 0/5/6/15** (review only — I
   did not rewrite them).
2. **`delegation.rs:419` is the declaration; the compiler error is at `:420`.** `:419` is
   `fn connect_pir_client(...)`, `:420` is the `PirClientBlocking::with_transport(...)` call the
   E0061 lands on — matching CHP.md §11.1's accidental-resolve observation, not §3/S2's `:419`.
   Call sites `:461` and `:542` are exactly as the spec states.
3. **The missing argument is a `NegotiatedPirLayout`, not a `PirLayout`.** The real error is
   `pir-client 0.4.0-rc.4`'s `PirClientBlocking::with_transport(url, NegotiatedPirLayout, transport)`.
   Passing a `NegotiatedPirLayout` straight through would **skip the crate's fail-closed handshake**.
   The sanctioned API is `zcash_voting::connect_pir_blocking(PirLayout, &str, Arc<dyn Transport>)`,
   which validates the config layout, rejects the `PirLayout::UNKNOWN` sentinel, converts, and maps
   a server mismatch to `VotingError::InvalidInput`. Task 1 routes through it. **Android PR #2157
   independently does exactly this** (`gh pr diff 2157 --repo zcash/zcash-android-wallet-sdk`,
   diff lines 740–752): same `voting::config::PirLayout` parameter, same `connect_pir_blocking`
   call, same three scalar fields across the FFI boundary.
4. **`json.rs` is 359 lines (spec correct) but cannot be retired *entirely*.** Of its 11 mirror
   types, only 4 mirror something the crate serializes. `voting::NoteInfo`, `GovernancePczt`,
   `WitnessData`, `DelegationProofResult`, `DelegationPirPrecomputeResult` and `SharePayload` derive
   **`Clone, Debug` only — no `Serialize`** (`EncryptedShare` carries a comment *forbidding* a
   `Serialize` derive because it holds `plaintext_value`/`randomness`), and `JsonDelegationInputs`
   has no crate counterpart at all. Those six are FFI transport for non-serializable internal types,
   not wire mirrors, and stay. Task 2 removes the four genuine wire mirrors
   (`JsonDelegationSubmission`, `JsonSharePayload`, `JsonWireEncryptedShare`, `JsonVanWitness`) and
   the wire tail of `JsonVoteCommit`: **359 → 223 lines (−136)**. Both spec acceptance greps still
   pass — `all_enc_shares` drops to **zero** hits in `rust/src/voting/`.
5. **`wire::WireEncryptedShare` base64-encodes `c1`/`c2`** (`#[serde(with = "serde_base64_bytes")]`),
   and `DelegationSubmissionWire` renames `nf_signed` → `"signed_note_nullifier"` and `gov_comm` →
   `"van_cmx"`. Adopting the crate's serialization therefore **changes the Swift decode shape** for
   `VotingDelegationSubmission` and `VotingWireEncryptedShare` from `[UInt8]` to base64 `String`.
   That is the point of S3 (the crate owns the encoding) but it is a public-API break — it is
   itemised in `## INTERFACES-FOR-APP`. **Blast radius is zero inside the SDK:**
   `grep -rn 'VotingWireEncryptedShare\|VotingSharePayload\|VotingDelegationSubmission\|VotingVoteCommit\|sharePayloads\|encShares' Tests/`
   returns nothing.
6. **`cargo check` does not compile `#[cfg(test)]` code, so the spec's S2 acceptance misses two real
   breaks.** With `cargo check` green, `cargo test --lib voting` still failed with **2 × E0061** in
   `rust/src/voting/delegation.rs`'s own unit tests (`precompute_delegation_pir_rejects_null_db` and
   the prove-delegation null-handle test), which call the FFI with the old arity. Task 1 fixes both
   and adds `cargo test --lib voting` as a gate step (72 tests, all green after the fix).
7. **A *required* Swift `pirLayout:` parameter would break the "voting suite unmodified" assert.**
   Four calls in `Tests/OfflineTests/VotingRustBackendTests.swift` (lines 1052, 1111, 1134, 1315)
   invoke `precomputeDelegationPir`/`buildAndProveDelegation`; a new required parameter forces
   edits to a pre-existing voting test file, which trips skeleton step 6.3. Task 1 therefore
   defaults it to `VotingPirLayout.unknown` — **the crate's own `impl Default for PirLayout`**
   (`PirLayout::UNKNOWN`, `{0,0,0}`), which `zcash_voting` rejects with *"pir_layout is unknown;
   resolve a current dynamic voting config first"*. So the default is fail-closed and adds no
   semantics; the app plumbs the real layout in plan Task 12 (A5). If the orchestrator prefers a
   compile-time forcing function over the T6.3 assert, make the parameter required and edit those
   four call sites — that is a one-line change to each and a deliberate deviation, not a silent one.
8. **This FFI does not hand-maintain a C header, so Task 3 has no header step.** `rust/build.rs`
   runs cbindgen over the whole crate and writes `target/Headers/zcashlc.h`; `rust/wrapper.h` only
   declares the three `os_log`/`os_signpost` shims for bindgen. Verified in the probe: after adding
   the two functions, the generated header contains
   `struct FfiBoxedSlice *zcashlc_voting_confirm_vote_submission(...)` (line 5474) and
   `struct FfiBoxedSlice *zcashlc_voting_recover_wire_json(...)` (line 6226) with no manual edit.
9. **`nu63ConsensusBranchID` cannot be "made public" where it lives.** It is declared at
   `Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift:27` on `final class
   ValidateServerAction`, which is **internal**; adding `public` to a member of an internal type
   does not raise its effective access. Task 4 moves it to `public enum ZcashSDK`
   (`Sources/ZcashLightClientKit/Constants/ZcashSDK.swift:140`) and points the one existing use site
   at it, so there is exactly one declaration.
10. **CHANGELOG/MIGRATING are repo-mandated and the spec omits them.** The SDK's own `CLAUDE.md`
    requires a `CHANGELOG.md` entry for every user-visible change and `MIGRATING.md` for breaking
    API changes. Tasks 1–4 each carry one CHANGELOG step; Task 2 (the only source-incompatible
    change for an app already on this branch) also carries a MIGRATING step.
11. **Skeleton review, no action needed:** step 0.2's expected `origin/main` is correct — the ref in
    this worktree still reads `a1234039 Merge pull request #1954 …` (checked without fetching).
    Step 5.2's `find LocalPackages -name 'libzcashlc' -path '*macos*'` is also correct: the built
    binary really is a file named `libzcashlc` inside
    `LocalPackages/libzcashlc.xcframework/macos-arm64_x86_64/libzcashlc.framework/`
    (`Scripts/init-local-ffi.sh:107-109`), and `-name 'libzcashlc'` does not match the
    `.xcframework`/`.framework` directories.
12. **Sizing.** Spec S4 estimates ~50+25 / ~40+20 Rust+Swift. Actual, probe-measured:
    `confirm_vote_submission` = **70 Rust** (of which 36 are doc/safety comments) + **43 Swift**;
    `recover_wire_json` = **45 Rust** + **30 Swift**. The overshoot is entirely doc comments and the
    repo's `# Safety` convention, which every `unsafe extern "C"` function here carries.

---

## PROBE EVIDENCE

**Setup.** `git worktree add <SCRATCH>/sdk-probe a3823651 --detach` from the read-only SDK worktree;
`Cargo.toml:105` → `zcash_voting = { version = "=2.0.0-rc.5" }`; `cargo update -p zcash_voting`;
all builds with `CARGO_TARGET_DIR=<SCRATCH>/probe-target` so nothing touched the real tree. The
worktree was removed afterwards (`git worktree remove --force`). The read-only worktree was never
modified, committed to, or switched.

**`cargo update -p zcash_voting` — actual output (6 packages, exactly the spec's expectation):**

```
    Updating imt-tree v0.2.0 -> v0.2.1
    Updating pir-client v0.4.0-rc.2 -> v0.4.0-rc.4
    Updating pir-types v0.3.0-rc.2 -> v0.3.0-rc.4
    Updating vote-commitment-tree v0.4.0-rc.1 -> v0.4.0-rc.2
    Updating vote-commitment-tree-client v0.6.0-rc.1 -> v0.6.0-rc.2
    Updating zcash_voting v2.0.0-rc.3 -> v2.0.0-rc.5
```

**The REAL initial rc.5 error list — exactly one error, whole graph:**

```
error[E0061]: this function takes 3 arguments but 2 arguments were supplied
   --> rust/src/voting/delegation.rs:420:5
    |
420 |     voting::PirClientBlocking::with_transport(pir_url, Arc::new(voting::HyperTransport::new()))
    |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^          --------------------------------------- argument #2 of type `NegotiatedPirLayout` is missing
    |
note: associated function defined here
   --> ~/.cargo/registry/src/index.crates.io-.../pir-client-0.4.0-rc.4/src/lib.rs:693:12
error: could not compile `libzcashlc` (lib) due to 1 previous error
```

`REAL_EXIT=101`. Nothing else in the 4,469-line voting FFI broke on rc.3 → rc.5. B-O's prediction
(CHP.md §11.4/D2) is confirmed and is the *whole* delta.

**Second, hidden error list — only visible to `cargo test`, not `cargo check`:**

```
error[E0061]: this function takes 22 arguments but 19 arguments were supplied
    --> rust/src/voting/delegation.rs:1225:17     (build_and_prove_delegation null-handle test)
error[E0061]: this function takes 11 arguments but 8 arguments were supplied
    --> rust/src/voting/delegation.rs:1527:13     (precompute_delegation_pir_rejects_null_db)
error: could not compile `libzcashlc` (lib test) due to 2 previous errors
```

**What ended green (final probe state):**

| Gate | Result |
|---|---|
| `cargo check` | `REAL_EXIT=0` (1 pre-existing unrelated warning: `migration_plan_cache.rs:77` dead field) |
| `cargo fmt -- --check` | clean (two of my blocks needed reflow; the plan carries the rustfmt-canonical form) |
| `cargo test --lib voting` | `REAL_EXIT=0` — **72 passed; 0 failed** |
| `git grep 'all_enc_shares' rust/src/voting/` | **0 hits** |
| `git grep 'sighash' rust/src/voting/` | only signer-input / Keystone-record / `extract_pczt_sighash` / `pczt_sighash` passthroughs |
| Lock asserts | zcash_voting 2.0.0-rc.5 · pir-client 0.4.0-rc.4 · pir-types 0.3.0-rc.4 · exactly one librustzcash rev `13ce6c4e…` |
| cbindgen header | both new symbols emitted automatically |

Probe diff: `Cargo.lock`, `Cargo.toml`, `rust/src/voting.rs`, `rust/src/voting/{delegation,json,share_tracking,tree}.rs`
(+121/−176) plus new `rust/src/voting/confirmation.rs`.

**Per-task provenance:**

| Task | Rust | Swift |
|---|---|---|
| **Task 1 (S2)** | **compiler-proven** — pin, `connect_pir_blocking`, both FFI signatures, both Rust test call sites; `cargo check` + `cargo fmt --check` + `cargo test --lib voting` all green | **written-from-reading** (`VotingPirLayout` + two defaulted parameters); Swift compiles at plan Task 6 |
| **Task 2 (S3)** | **compiler-proven** — mirror deletions, `delegate::submission` + `to_wire_json()`, `VanWitness` passthrough, `JsonVoteCommit` reshape; same three gates green | **written-from-reading**, but the field names/encodings are transcribed from the crate's own `wire.rs` structs and `serde` attributes, not inferred |
| **Task 3 (S4)** | **compiler-proven** — both `extern "C"` functions compile, cbindgen emits both, `cargo test --lib voting` green | **written-from-reading** (2 wrappers, 1 type, 2 test files) |
| **Task 4 (S5)** | n/a | **written-from-reading** — 1 constant moved, 1 use site repointed |

---

## INTERFACES-FOR-APP

Everything below is the **public Swift surface** the app lane (plan Tasks 8–13) consumes. This block
is self-sufficient: nothing else in the SDK's public API changes in Tasks 1–4.

### New types

```swift
/// PIR tree geometry the round's resolved dynamic voting config advertises.
public struct VotingPirLayout: Equatable, Sendable {
    public let pirDepth: UInt32
    public let tier0Layers: UInt32
    public let tier1Layers: UInt32

    /// `zcash_voting`'s `PirLayout::UNKNOWN` sentinel. The crate REJECTS it.
    public static let unknown: VotingPirLayout

    public init(pirDepth: UInt32, tier0Layers: UInt32, tier1Layers: UInt32)
}

/// Positions confirmed by a mined cast-vote transaction.
public struct VotingVoteConfirmation: Codable, Sendable, Equatable {
    public let txHash: String              // "tx_hash"
    public let vanLeafPosition: UInt32     // "van_leaf_position"
    public let voteCommitmentTreePosition: UInt64  // "vc_tree_position"
}
```

### New methods on `VotingRustBackend`

```swift
/// Record a confirmed cast-vote transaction in one atomic database transaction.
/// `eventsJson` is the confirmation-events array the app's existing confirmation
/// polling already fetches, serialized as JSON:
/// `[{"type":"cast_vote","attributes":[{"key":"leaf_index","value":"…"}]}, …]`.
/// Do NOT pre-parse `leaf_index` — the crate owns that.
public func confirmVoteSubmission(
    roundId: String,
    bundleIndex: UInt32,
    proposalId: UInt32,
    txHash: String,
    eventsJson: String
) throws -> VotingVoteConfirmation

/// Rebuild one helper-server share payload as the crate's own wire JSON, with the
/// confirmed position and the scheduled submit time late-bound into it. Static:
/// no database handle, no second commit. POST the returned string verbatim.
public static func recoverWireJson(
    commitmentBundleJson: String,
    proposalId: UInt32,
    shareIndex: UInt32,
    voteCommitmentTreePosition: UInt64,
    submitAt: UInt64
) throws -> String
```

`commitmentBundleJson` is `VotingStoredCommitmentBundle.bundleJson` from the existing
`getCommitmentBundle(roundId:bundleIndex:proposalId:)`.

### New public constant

```swift
public extension ZcashSDK {
    /// Consensus branch ID of NU6.3 ("Ironwood").
    static let nu63ConsensusBranchID: ConsensusBranchID  // 0x37a5_165b
}
```

Use `ZcashSDK.nu63ConsensusBranchID` at `VotingCryptoClientLiveKey.swift:218` in place of the
hardcoded `0xC8E7_1055`. Note the type is `ConsensusBranchID` = `Int32`;
`VotingBuildPcztParams.consensusBranchId` is `UInt32`, so the app converts with
`UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)`.

### Changed existing signatures

```swift
// gains `pirLayout:` (defaulted) between `expectedSnapshotHeight:` and `pirResolver:`
public func precomputeDelegationPir(
    roundId: String,
    bundleIndex: UInt32,
    notes: [VotingNoteInfo],
    pirEndpoints: [String],
    expectedSnapshotHeight: UInt64,
    pirLayout: VotingPirLayout = .unknown,
    pirResolver: PirSnapshotResolver = PirSnapshotResolver()
) async throws -> VotingDelegationPirPrecomputeResult

// gains `pirLayout:` (defaulted) between `expectedSnapshotHeight:` and `pirResolver:`
public func buildAndProveDelegation(
    _ params: VotingDelegationProofParams,
    pirEndpoints: [String],
    expectedSnapshotHeight: UInt64,
    pirLayout: VotingPirLayout = .unknown,
    pirResolver: PirSnapshotResolver = PirSnapshotResolver(),
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> VotingDelegationProofResult
```

**The default is fail-closed, not optional in practice.** Leaving it at `.unknown` makes every PIR
call throw `.rustError("… pir_layout is unknown; resolve a current dynamic voting config first")`.
The app MUST pass the layout from the resolved dynamic config (live prod serves
`{pir_depth: 19, tier0_layers: 12, tier1_layers: 7}`).

### Changed existing types

```swift
// base64 Strings, not [UInt8] — the crate now serializes these
public struct VotingWireEncryptedShare: Codable, Sendable {
    public let ciphertext1: String   // "c1", base64
    public let ciphertext2: String   // "c2", base64
    public let shareIndex: UInt32    // "share_index"
    public init(ciphertext1: String, ciphertext2: String, shareIndex: UInt32)
}

// crate-serialized wire body: `sighash` GONE, `tx1Effects` ADDED, all fields base64
public struct VotingDelegationSubmission: Codable, Sendable {
    public let randomizedKey: String  // "rk"
    public let spendAuthSig: String   // "spend_auth_sig"
    public let tx1Effects: String     // "tx1_effects" — 821 bytes decoded
    public let nfSigned: String       // "signed_note_nullifier"
    public let cmxNew: String         // "cmx_new"
    public let govComm: String        // "van_cmx"
    public let govNullifiers: [String]// "gov_nullifiers"
    public let proof: String          // "proof"
    public let voteRoundId: String    // "vote_round_id"
}

// `sharePayloads` REMOVED
public struct VotingVoteCommit: Codable, Sendable {
    public let proposalId: UInt32
    public let vanNullifier: [UInt8]
    public let voteAuthorityNoteNew: [UInt8]
    public let voteCommitment: [UInt8]
    public let proof: [UInt8]
    public let anchorHeight: UInt32
    public let voteKeyRandomizer: [UInt8]
    public let voteAuthSig: [UInt8]
    public let encShares: [VotingWireEncryptedShare]
}
```

### Removed public type

`VotingSharePayload` — deleted. It was the SDK's hand-mirror of the helper payload and carried
`allEncShares`, the field that leaked every helper's share to every helper. Helper payloads now come
from `recoverWireJson(...)` as opaque crate-serialized JSON strings, one per share index.

**Consequence for the app's vote sequence (spec §3/A2 steps 5–6):** `commitVote(...)` no longer
returns anything to POST. After `confirmVoteSubmission`, read the recovery bundle with
`getCommitmentBundle`, then call `recoverWireJson` once per share index and POST each returned
string as the helper request body. Nothing in the app builds or reshapes that JSON.

**Unchanged and still correct:** `VotingVanWitness` (`auth_path`/`position`/`anchor_height` — the
crate's own `VanWitness` serializes identically to the deleted mirror), `getCommitmentBundle`,
`recordVcPosition`, `markVoteSubmitted`, `storeKeystoneSignature`, `getKeystoneSignatures`, all
share-tracking members, and every round-lifecycle member.

---

## TASK 1

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

## TASK 2

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

## TASK 3

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

## TASK 4

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
