# Panel A-O — Opus, with Android PR access

> Verbatim final report, 2026-08-10. Brief: minimal shared context + the two Android PRs.
> Adjudication note (orchestrator): strongest report of the panel — sole finder of the live
> consensus-branch-ID bug (N1) and the vc_tree_position sequencing risk (R1).

---

# 1. FINDINGS

**App (`_migration/zodl-ios` @ `fea8d600`) — nothing is broken, everything is switched off.**
- The entire feature is behind one Swift compile condition, `#if VOTING_ENABLED`, in **40 files**. `VOTING_ENABLED` is **defined in no build configuration** (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` carries only `DEBUG`/`UNREDACTED`/`SECANT_TESTNET`/`SECANT_MAINNET`/`SECANT_DISTRIB`). No runtime flag, no remote gate. Entry point is Settings → Coinholder Polling.
- The project uses `PBXFileSystemSynchronizedRootGroup` (4 of them) and contains **zero** "Voting" strings in `project.pbxproj` — so the files are already in the target. **Flipping the flag is a build-settings one-liner; no pbxproj surgery.**
- Size: 50 voting Swift files under `secant/Sources` (+5 test files; 17,647 lines total). **Only 13 touch the SDK; 37 are pure UI/TCA stores (5,944 lines in `Features/Voting`) and need no change at all.** The SDK boundary is essentially one file: `secant/Sources/Dependencies/VotingCryptoClient/VotingCryptoClientLiveKey.swift` (879 lines), plus its interface (265) and `VotingCoordFlowCoordinator.swift` (3,766) for orchestration.

**SDK-Swift + SDK-Rust — upstream already did this job, completely.**
- `93a11081` has voting **off**: `mod voting;` behind `#[cfg(zcash_voting)]` (never set), `zcash_voting` commented out of `Cargo.toml`, and the whole Swift layer deleted (`248d46f9` "[#1806] Remove the Swift voting surface").
- `a3823651` restores it: `zcash_voting = { version = "2.0.0-rc.3" }`, unconditional `mod voting;`, and 4 Swift files (`VotingRustBackend.swift` 1,940, `VotingTypes.swift` 568, `PirSnapshotResolver.swift` 268, `VotingConstants.swift` 20) + 1,527 lines of offline tests. 55 `zcashlc_voting_*` FFI exports, 48 public Swift methods.
- **`git diff --stat a1234039 a3823651` over every voting path returns only `Cargo.toml`.** The voting code at `a3823651` is byte-identical to `origin/main`. The iOS SDK work is *done and merged upstream*; `a3823651` is just the merge, and it is the tip of `chp-re-enable` with no descendants.
- Upstream wrote the migration guide for us: `a250cb76` (nuttycom) rewrites `MIGRATING.md` + `rust/CHANGELOG.md` with the exact app-facing delta.

**The real gap is app↔SDK API drift.** The app was written against the pre-1.0 crate API; the SDK now speaks 2.0. Six app-called methods no longer exist:

| App calls | Upstream replacement |
|---|---|
| `buildVoteCommitment`, `signCastVote`, `buildSharePayloads`, `encryptShares` | one `commitVote(...)` |
| `storeCommitmentBundle` | `recordVcPosition(...)` |
| `decomposeWeight` | removed, **no replacement** (share construction is crate-internal) |

Plus: `generateHotkey(roundId, seed)` → `generateHotkey(networkId)`; `open(path:networkId:)` now fixes the network (so `initRound`/`commitVote` dropped theirs); `markVoteSubmitted` requires the tx hash; `recordShareDelegation` drops the nullifier; `buildPczt`/`buildAndProveDelegation` take the stored secret; round IDs must be 64 lowercase hex canonical Pallas; `setupBundles` rejects an empty note set; `VotingBundleSetupResult` gained `droppedCount`.

**The hotkey change is much smaller for us than upstream's warning implies.** MIGRATING leads with "hotkeys are no longer wallet-seed derivations — the application must persist `storedSecret`". Zodl iOS **never derived from the wallet seed**: `WalletStorage.swift:476-499` already keeps a per-account `StoredVotingHotkey` in the keychain under `zcashStoredVotingHotkey_<accountUUIDhex>`, and the coordinator does `exportVotingHotkey(accountId).seedPhrase` → `mnemonic.toSeed`. We are already in the app-owned-persisted-secret model; only the **stored format** changes (mnemonic phrase → the SDK's `storedSecret` bytes), in one struct and two functions.

**Two live correctness bugs I found in the app, independent of the API drift:**
1. `VotingCryptoClientLiveKey.swift:218` — `let consensusBranchId: UInt32 = 0xC8E7_1055` with the comment "NU6 consensus branch ID". Ironwood/NU6.3 is **`0x37a5_165b`** (`ValidateServerAction.nu63ConsensusBranchID`, currently `static let`, not public). Every governance PCZT built post-activation carries the wrong branch. The crate now rejects this hard: rc.5's `shielded_protocol.rs` has `VotingShieldedProtocol::for_branch_id` returning `Err` for anything but `BranchId::Nu6_3`.
2. `VotingAPIClientLiveKey.swift:898` sends `"sighash"` and `:369` sends `"all_enc_shares"` — the pre-rc.4 wire. Android's SDK PR quotes the live server rejecting it: *`vote-chain 400: "invalid message field: tx1 effects must be 821 bytes, got 0"`*.

**Crate.** Latest is **2.0.0-rc.5** (2026-08-08); rc.4 was 08-07. Our SDK pins **rc.3**; **Android ships rc.4**. No 2.0.0 final, `main` is 2 commits ahead of rc.5, 2 open PRs — this is moving daily. rc.4 is breaking in three ways that reach us: `connect_pir` takes an explicit `PirLayout` and fails closed (`COMPILED_PIR_LAYOUT` un-exported); delegation submissions carry `tx1_effects` (821 B) instead of `sighash`; vote-share JSON drops `all_enc_shares` for the single per-helper share. The crate resolves librustzcash purely from crates.io — our `[patch.crates-io]` git rev `13ce6c4e` is what forces it onto the Ironwood family, and that is why rc.3 builds green here. MSRV 1.88, edition 2021.

**One piece of good news from the Android reference:** their headline bug — `build_governance_pczt_for_bundle` calling `update_round_phase_forward`, which broke every multi-bundle round with "refusing to regress round phase" — was *"a zodl-SDK addition the crate itself never does"*. I grepped `a3823651:rust/src/voting`: **zero occurrences** of `update_round_phase_forward` or `require_round_phase_not_after`. **iOS does not have that bug**, so their entire per-bundle `DelegationPhase` apparatus is not our problem.

# 2. PROPOSAL

Ordered, simplest-first. The SDK is done; almost everything here is app-side rewiring.

**S1 — Bump the SDK to `zcash_voting` 2.0.0-rc.5.** *(SDK, ~30 lines Rust + Cargo)* Two adaptations, both already solved verbatim by Android: give `connect_pir_client` an explicit `PirLayout` (they added `pir_layout_from_jni` + a 3-field struct); and carry `tx1_effects` on the delegation submission (widen `VotingDelegationSubmission`, drop `sighash`). Do **not** stay on rc.3 — the vote-chain rejects its wire. *Alternative if S1 slips: ship rc.3 and accept that delegation submission will 400.* It won't work; don't.

**S2 — Build a local FFI with voting symbols.** *(build, 0 lines)* `Package.swift` still pins the released `2.8.0-rc.2` XCFramework, and the SDK CHANGELOG puts the voting restore under **Unreleased** ("changes are relative to 2.8.0-rc.3") — that binary has no `zcashlc_voting_*`. Run `./Scripts/init-local-ffi.sh --arm-ios`. Budget CI/build time: Android had to double their job timeout 30→60 min because `orchard`'s `unstable-voting-circuits` pulls the halo2 voting circuits in.

**S3 — Define `VOTING_ENABLED` on the testnet configs only.** *(app, 2 lines)* Add it to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the `SECANT_TESTNET` Debug/Release configs. Expect ~40 files to start compiling and fail loudly against the new API — that compiler error list *is* the work list for S4-S6.

**S4 — Migrate the hotkey to `storedSecret`.** *(app, ~60 lines across 4 files)* Add a `storedSecret: [UInt8]` case to `StoredVotingHotkey` (bump `version`), change `importVotingHotkey`/`exportVotingHotkey`, delete the 4 `mnemonic.toSeed(hotkeyPhrase)` sites in the coordinator and thread the secret through the 13 `hotkeySeed` references there and 12 in LiveKey. Any pre-existing hotkey is dead weight — old delegations can't be recovered; treat an old-format record as "no hotkey".

**S5 — Collapse the four vote-cast calls into `commitVote`.** *(app, ~120 lines, mostly deletions)* In `VotingCryptoClientInterface.swift` replace the 4 closures with one `commitVote`; in `LiveKey` delete `buildVoteCommitment`/`signCastVote`/`buildSharePayloads`/`encryptShares`/`decomposeWeight` and forward to `backend.commitVote(...)`, which returns `proof`, `voteAuthSig`, `encShares` **and** `sharePayloads` in one `VotingVoteCommit`. Rewrite `VotingCoordFlowCoordinator.swift:1872-1930` plus the two recovery paths at ~2171 and ~3463. Map `storeCommitmentBundle` → `recordVcPosition`. **Do not build a compatibility shim that fakes the old 4-call shape** — `commitVote` is idempotent per `(round, bundle, proposal)` and will hand back the persisted bundle, so a shim silently returns stale data.

**S6 — Fix the two wire/consensus bugs.** *(app, ~25 lines)* Branch ID `0xC8E7_1055` → `0x37a5_165b` — better, make `nu63ConsensusBranchID` public in the SDK and read it rather than re-hardcoding. Rename `"sighash"` → `"tx1_effects"` in the delegation body, switch `all_enc_shares` to the single per-helper share, and add `pir_layout` (`pir_depth`/`tier0_layers`/`tier1_layers`) to `VotingServiceConfig` — `PirSnapshotResolver.swift:249` already parses `pir_depth`, so half the plumbing exists.

**S7 — Point the static config at the live source and run a testnet round.** *(app, 2 lines)* Android moved their pinned fallback from a commit-pinned `raw.githubusercontent.com` URL to `https://voting.valargroup.org/prod/static-voting-config.json?checksum=sha256:…`. Match it.

Rough total: **~240 lines of app change and ~30 lines of SDK change**, against 17,647 lines of existing voting code. That is the shape of the owner's "a lot of work, but simple work" — except for R1 below.

# 3. RISKS

**R1 (highest, and the only genuine design risk) — the `vc_tree_position` sequencing.** `commitVote` takes `voteCommitmentTreePosition` *up front*, and I traced it in rc.5 straight into `db.build_share_payloads(…, draft.vc_tree_position, …)` (`vote.rs:615`). But the app only learns that position *after* the tx confirms, by parsing the `cast_vote` `leaf_index` = `"vanIdx,vcIdx"`. `record_vc_position` then refuses a value that disagrees with an already-stored one (`vc_position_already_recorded_error`). It *does* rewrite the recovery JSON when the column was previously unset — so a provisional value at commit followed by the real one at confirmation may be the sanctioned path, and `session::resume_plan` yields `SubmitShares { vc_tree_position }` from the corrected recovery. **I could not settle from source alone whether the share payloads built at commit time survive that correction.** If they don't, the app needs either a pre-commit tree-size query (which neither `VotingAPIClient` nor `syncVoteTree` — it returns a *height* — provides today) or a payload rebuild. This is the one item that could turn simple work into design work.

**R2 — the crate is a moving target.** rc.4 and rc.5 landed a day apart; `main` is already ahead with two open PRs touching round authentication and PIR layout validation. Pin an exact version (`=2.0.0-rc.5`) and expect to chase it. Note plain `cargo add zcash_voting` resolves to **1.0.0** — Cargo won't pick a pre-release unless pinned exactly.

**R3 — the SDK's FFI omits the crate's recovery surface.** No `resume_plan`, `recover_commit`, `confirm_vote_submission`, `recovery_bundle`, `delegation_phases`, or `reset_voting_session_state` among the 55 exports. The app's own hand-rolled resume logic in `VotingCoordFlowCoordinator` will keep carrying that weight. Fine for a testnet round; it is the thing most likely to need SDK work later.

**R4 — build time and binary size.** `unstable-voting-circuits` + halo2. Android measured 30m+ per ABI from cold. Also confirm the released XCFramework story before anyone assumes a plain `swift build` works.

**R5 — silent hotkey loss.** A seed-phrase restore does not recover a lost `storedSecret`, and any voting power already delegated to it is unusable. The UI has no concept of this. Not a blocker for testnet; it is a product conversation before mainnet.

**R6 — round-ID validation.** `initRound` now rejects anything that isn't 64 lowercase hex encoding a canonical Pallas field element. If any fixture, deep link, or config carries a short/uppercase ID, it fails at round open, not at parse.

# 4. FIRST VERIFICATIONS

1. **Settle R1 before writing any app code.** Write one Rust test against `zcash_voting 2.0.0-rc.5`: `vote::commit` with a provisional `vc_tree_position`, then `record_vc_position` with a different value, then read `recovery_bundle` and compare `share_payloads` byte-for-byte against a commit made with the correct position up front. Equal → S5 is pure rewiring. Not equal → we need a pre-commit position source and the plan changes.
2. **Does `a3823651` still `cargo check` on rc.5?** Bump `=2.0.0-rc.5`, apply the `PirLayout` and `tx1_effects` adaptations, `cargo check`. This is the cheapest test of whether the Ironwood `[patch.crates-io]` graph survives the bump — the crate's own lockfile is all-crates.io, so patch compatibility is the load-bearing assumption.
3. **Flip `VOTING_ENABLED` on a scratch branch and capture the raw compiler error list.** Zero cost, and it converts my six-method gap analysis into the authoritative work list. My prediction: errors cluster in `VotingCryptoClientLiveKey.swift` and the three coordinator regions, and nothing in `Features/Voting`.
4. **Confirm which wire generation the live vote-chain speaks.** Hit the testnet delegate-vote endpoint with an rc.3-shaped body and see whether it 400s on `tx1_effects`. If it accepts `sighash`, S1 can be deferred and the whole thing gets meaningfully smaller.
5. **Check `2.8.0-rc.2`'s XCFramework for `zcashlc_voting_*`** (`nm -gU` on the slice). I believe it has none — S2 assumes local FFI, and a surprise here is cheap to find and expensive to hit late.

# 5. ZERO-NEW-CODE CHECK

**Combined Android footprint: 32 files, 1,138 lines churned** (app #2406: 17 files, +374/−126; SDK #2157: 15 files, +514/−124).

| Bucket | Files | Lines | Share |
|---|---|---|---|
| Mechanical rewiring | 22 | 542 | **48%** |
| Genuinely new logic | 12 | 486 | 43% |
| Test/fixture churn | 3 | 110 | 10% |

**But the headline number understates the case badly, and the correction is the real finding.** Both PRs are titled `MOB-1678: Fix multi-bundle CHP…` — the re-enablement is 8 of 500 lines in the app PR (1.6%). Nearly the whole "new logic" bucket in *both* repos is one bug and its plumbing: `update_round_phase_forward` writes that made bundle 1+ fail with "refusing to regress round phase". Their own PR body calls it *"a zodl-SDK addition the crate itself never does"* — and **`a3823651:rust/src/voting` contains zero occurrences of it**. So the `DelegationPhase`/`BundleDelegationPhase` model, `delegationPhasesNative`, `resetVotingSessionStateNative`, `make_jni_delegation_phases`, the `setupJustBuilt`/`alreadyProved` tracking, and the three "attempt-and-treat-overwrite-as-success" rewrites — **none of it applies to iOS.**

Netting that out, **the iOS-applicable Android work is ~48% mechanical plus roughly 35 lines of PIR-layout/`tx1_effects` adaptation. Effectively 0% of their new-logic bucket transfers.** Their genuinely new code was paying down an Android-only debt we never incurred.

**Verbatim — mechanical:**

```diff
-internal const val VOTING_ENABLED = false
+internal const val VOTING_ENABLED = true
```
*(`ui-lib/.../screen/more/MoreVM.kt` — the entire re-enablement act, exactly our S3)*

```diff
-        .put("sighash", sighash.toBase64String())
+        .put("tx1_effects", tx1Effects.toBase64String())
```
*(`VotingApiProvider.kt` — our S6, one line)*

```diff
             pirServerUrl: String,
+            pirDepth: Int,
+            pirTier0Layers: Int,
+            pirTier1Layers: Int,
             notes: List<JniNoteInfo>
```
*(`VotingRustBackend.kt` — same threading repeated 6× in the file; pure parameter plumbing)*

**Verbatim — new logic (and why it isn't ours):**

```diff
     let bundle_notes = bundled_notes_for_index(notes, bundle_index)?;
-    update_round_phase_forward(db, round_id, RoundPhase::HotkeyGenerated)?;
```
*(`voting/delegation.rs` — the fix. The line being deleted does not exist in our tree.)*

```kotlin
enum class DelegationPhase { PREPARED, PCZT_BUILT, PROVED, SUBMITTED, CONFIRMED; … }
data class BundleDelegationPhase(val bundleIndex: Int, val phase: DelegationPhase)
```
*(`RoundStateInfo.kt`, 33 new lines — exists only to route around the phase-regression bug)*

```rust
pub extern "C" fn Java_…_VotingRustBackend_delegationPhasesNative<'local>( … ) -> jobjectArray {
    let phases = db.delegation_phases(&round_id)…
```
*(`voting/rounds.rs`, 19 lines — and even this is a thin passthrough to crate-owned logic, not new algorithm)*

The one piece of their new logic that *is* ours: the `VotingPirLayout` wire class (~14 lines), because rc.4 made `connect_pir` fail closed without an explicit layout.

**Bottom line: the owner's read is right, and stronger than he put it.** The SDK half is already merged upstream and byte-identical to `origin/main`; the app half is one build flag, one adapter file, and three regions of one coordinator. The single thing that could make this not-simple is R1 — verify it first, in an afternoon, before anyone writes app code.
