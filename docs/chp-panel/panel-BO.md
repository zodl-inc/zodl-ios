# Panel B-O — Opus, blind (no Android materials)

> Verbatim final report, 2026-08-10. Brief: minimal shared context; Android repos/PRs barred.

---

# 1. FINDINGS

**App (`zodl-ios`, branch `migration/gardening-test`) — the UI is intact and has never shipped.**
- The whole feature exists: 14 feature dirs under `secant/Sources/Features/Voting/`, `Features/CoordFlows/VotingCoordFlow/` (`VotingCoordFlowCoordinator.swift` = 3,766 lines), 4 dependency clients (`VotingCryptoClient` 879+265, `VotingAPIClient` 1,114+87, `VotingStorageClient`, `VotingMetadataProvider`), 6 test files, 74 localized voting/`coinholderPolling` strings. ~7,300 lines of voting code.
- All of it is behind `#if VOTING_ENABLED` (56 files). **`VOTING_ENABLED` appears in ZERO build configurations** in `secant.xcodeproj/project.pbxproj` — I checked every `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (only `DEBUG`, `UNREDACTED`, `SECANT_TESTNET`, `SECANT_MAINNET`, `SECANT_DISTRIB`). Targets: `zodl-testnet`, `zodl-production`, `zodl-internal`.
- **Consequence that shapes everything: the feature never reached a user.** No stored hotkeys, no cast votes, no persisted round state, no wire compatibility to preserve. Every compatibility question below collapses to "just change it."
- Model-only files are ungated and compile today: `VotingModels/*`, `Models/VotingMetadata.swift`, `WalletStorage/StoredVotingHotkey.swift`.
- The app consumes the SDK as `XCLocalSwiftPackageReference "../zcash-swift-wallet-sdk"` — a **local path**. Whatever ref that sibling working tree sits on is what the app builds.

**SDK-Swift — voting was deleted at the team's base, and already restored one merge away.**
- `93a11081` (team's stack): `Sources/ZcashLightClientKit/Rust/Voting/` **does not exist**; `Tests/OfflineTests/VotingRustBackendTests.swift` gone.
- `a3823651` (= `93a11081` + `origin/main`): restores 4 files (`VotingRustBackend.swift` 1,940 · `VotingTypes.swift` 568 · `PirSnapshotResolver.swift` 268 · `VotingConstants.swift` 20) + 1,527 lines of offline tests. **This merge already exists and is cargo-check green.** That is the free 80%.

**SDK-Rust — the module was never deleted, only switched off.**
- At `93a11081`: all 16 `rust/src/voting*` files present, but `mod voting;` carries `#[cfg(zcash_voting)]` and the dependency is commented out. Net effect: **libzcashlc contains zero `zcashlc_voting_*` symbols**. The `Package.swift` binary target (`2.8.0-rc.2` XCFramework) therefore cannot support voting at all.
- At `a3823651`: cfg gate removed, `zcash_voting = { version = "2.0.0-rc.3" }` straight from **crates.io** — the old `[patch.crates-io]` git pin to `valargroup/zcash_voting` is gone, and orchard needs no `unstable-voting-circuits` feature. Rust exports 64 `zcashlc_voting_*` symbols.
- **The real remaining seam is Swift-side, and it is small.** Seven exported FFI symbols are unbound by the Swift wrapper: `build_share_payloads`, `build_vote_commitment`, `encrypt_shares`, `sign_cast_vote`, `store_commitment_bundle`, `get_delegation_submission{,_with_keystone_sig}`. That is deliberate, not an oversight — `rust/src/voting.rs`'s module doc says the crate's one-shot commit flow *absorbed* them and they survive as "superseded" error stubs. `rust/src/voting/vote.rs:14-30` spells it out: `zcashlc_voting_commit_vote` replaces the four-call sequence, and it is idempotent per `(round_id, bundle_index, proposal_id)`.
- **The app is still written against the superseded four-call sequence.** Exact gap between what the app calls and what SDK Swift offers: `buildVoteCommitment`, `signCastVote`, `buildSharePayloads`, `storeCommitmentBundle`, `encryptShares`, `decomposeWeight`.
- Two corrections to that module doc, which I verified rather than took on faith: `generate_delegation_inputs` is **not** superseded — `rust/src/voting/util.rs:43` and `:96` are live implementations that now take a *stored hotkey secret* (see tests at `util.rs:330,364,385`). And `decompose_weight` is genuinely gone — it survives only as a word in that comment.

**Crate (`valargroup/zcash_voting`) — Ironwood is already native; latest is `2.0.0-rc.5`.**
- crates.io: `2.0.0-rc.5` (2026-08-08). `main` is `a7a8a45b` (2026-08-08, one PR past the rc.5 tag). The SDK's rc.3 is 3 days stale.
- **Ironwood needs no work.** v2.0.0-rc.1: *"snapshot selection and governance PCZT construction use only Ironwood/V3 notes… Ironwood voting no longer requires a custom Rust compile flag."* rc.3 adds `NoteInfo::from_orchard_note` rejecting non-Ironwood/V3 at ingestion (PRs #152/#153), rc.4 adds Ironwood delegation signing effects (#156). The SDK's `rust/src/voting/notes.rs:84-92` already reads weight from `get_unspent_ironwood_notes_at_historical_height`. The SDK's own Ironwood plumbing (subtree roots, NU6.3 branch ID `0x37a5165b`, `Checkpoint.ironwoodTree`) is in place from the `merge/ironwood-slipstream` PR.
- **rc.3 → rc.5 is a drop-in for the librustzcash graph.** I diffed the dependency requirements: both demand `zcash_client_backend ^0.24.0-rc.7`, `zcash_client_sqlite ^0.22.0-rc.7`, `zcash_keys ^0.16.1`, `zcash_protocol ^0.10.4`, `pczt ^0.9.2`, `orchard ^0.15`, `voting-circuits =0.9.0-rc.3`. Only Valar-side crates move (`imt-tree` 0.2.0→0.2.1, `pir-client`/`pir-types` rc.2→rc.4, `vote-commitment-tree{,-client}` rc.1→rc.2). **No librustzcash re-pin.**
- One genuine rc.4 breaking change matters: `pir::connect_pir` now takes an explicit `PirLayout` and fails closed on mismatch; `COMPILED_PIR_LAYOUT` is no longer re-exported; dynamic config must carry top-level `pir_layout`. The SDK's `rust/src/voting/delegation.rs:419` `connect_pir_client(&pir_url)` uses the old signature (2 call sites, `:461`, `:542`).
- **I checked the live service: it is already on the rc.4+ contract.** `https://voting.valargroup.org/prod/dynamic-voting-config.json` returns 200 with top-level `"pir_layout": {"pir_depth": 19, "tier0_layers": 12, "tier1_layers": 7}` — plus one registered round. The app's `VotingServiceConfig` does not decode that field yet. Going to rc.5 moves *toward* the deployed service, not away from it.

# 2. PROPOSAL

Simplest thing that works, in dependency order. Total: roughly 2 focused days, and the bulk is deletion.

**S1 — Take the merge that already exists. (zero code, ~1h)**
Base the SDK work on `a3823651` rather than re-deriving it. It is `93a11081` + `origin/main`, restores the Swift voting layer, un-gates the Rust module, moves `zcash_voting` to crates.io, and is already cargo-check green. Do not hand-port; merge.

**S2 — Bump the crate to `2.0.0-rc.5`. (SDK-Rust, ~80 lines)**
`Cargo.toml`: `2.0.0-rc.3` → `2.0.0-rc.5`; `cargo update`. Then fix the one compile break: give `connect_pir_client` an explicit `PirLayout` parameter (`delegation.rs:419` + call sites `:461`, `:542`), threaded from the round's resolved config. Add the three layout fields to whichever FFI struct feeds `precompute_delegation_pir` / `build_and_prove_delegation`. Pin `main`'s `a7a8a45b` only if #168's tree-sync bounding is wanted before it is tagged — otherwise take the tag.

**S3 — Collapse the app's four-call vote flow into `commitVote`. (App, net −150 lines)**
This is the only substantive app change, and it *removes* code. `VotingRustBackend.commitVote(...)` returns `VotingVoteCommit` carrying everything the four superseded calls used to return separately: `voteCommitment` + `proof` + `vanNullifier` + `voteAuthorityNoteNew` + `anchorHeight` + `voteKeyRandomizer` (was `buildVoteCommitment`), `voteAuthSig` (was `signCastVote`), `encShares` (was `encryptShares`), `sharePayloads` (was `buildSharePayloads`); persistence is internal (was `storeCommitmentBundle`).
- `VotingCryptoClient`: replace 4 members with 1. Delete `encryptShares` and `decomposeWeight` outright — **both have 0 consumers** in the entire app, they are dead weight the compiler will not miss.
- `VotingCoordFlowCoordinator.swift`: rewrite one region (~`:1876-1940`) — `buildVoteCommitment` (1 call site), `signCastVote` (1), `storeVoteCommitmentBundle` (3), `buildSharePayloads` (3). Keep the progress-callback plumbing; `commitVote` takes the same `progress:` closure, so `RoundSession.preparingProof` / `.sendingShares` phases and every screen stay exactly as they are.
- The UI is untouched. The `.fullScreenCover` in `SettingsView.swift:169`, all 14 feature screens, all 74 strings: unchanged.

**S4 — Hotkey: mnemonic → stored secret. (App, ~40 lines)**
The crate moved to app-owned `stored_secret` material (`VotingHotkey.storedSecret`, `VOTING_HOTKEY_STORED_SECRET_LEN`); `hotkeyStoredSecret` replaces `hotkey_seed` everywhere. The app already generates *random* hotkey material (`VotingCoordFlowCoordinator.swift:984` `mnemonic.randomMnemonic()`), so the security model is already right — only the format is stale. Swap `StoredVotingHotkey.seedPhrase` for `storedSecret: Data`, bump its existing `version` field, drop the four `mnemonic.toSeed(hotkeyPhrase)` derivations (`:1770`, `:2043`, `:2629`, `:2835`). **No migration code** — nothing shipped, so nobody has a stored hotkey.

**S5 — Decode `pir_layout` in the app config. (App, ~30 lines)**
Add `pirLayout` (3 `UInt32`s) to `VotingServiceConfig`, plumb it to the SDK PIR entry points. Production already serves it. Keep `WalletCapabilities.pir = ["v0"]` as-is — `supported_versions` did not change.

**S6 — Rebuild the FFI locally, then flip the flag. (~1h + build time)**
The released `2.8.0-rc.2` XCFramework has no voting symbols at all, so `Scripts/init-local-ffi.sh --arm-all` (or `--universal` before any archive) is mandatory, not optional. Then add `VOTING_ENABLED` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for `zodl-internal` and `zodl-testnet` first; `zodl-production` only after S7.

**S7 — Turn the tests back on.** The 6 `zodlTests/VotingTests/*` files and the SDK's 1,527-line `VotingRustBackendTests.swift` come back for free once the flag and the merge land. They are the cheapest regression signal available; run them before touching `zodl-production`.

# 3. RISKS

1. **`commitVote` semantics differ from the four-call sequence in ways the coordinator assumes.** Highest risk because it is the only real logic rewrite. Specifically: the old flow stored the bundle *twice* (`:1888` with position 0, then `:1937` with the real `vcIdx`) — that two-phase "store before I know the tree position" dance may not survive a one-shot call. Mitigated by `commit_vote` being documented idempotent per `(round_id, bundle_index, proposal_id)`, but the tree-position ordering needs reading before writing.
2. **PIR layout fail-closed.** rc.4 turns a layout mismatch into a hard `VotingError::InvalidInput` before any query. If the app ships a hardcoded layout instead of reading the config's, a future service-side layout change silently bricks delegation. Read it from config; never compile it in.
3. **FFI slice staleness.** This project's most-repeated failure mode. A single-arch `rebuild-local-ffi.sh` downgrades universal slices; archives and generic-simulator gate builds then link a slice with no voting symbols and fail with confusing link errors. Use `--universal` before any archive; verify with `lipo -archs`.
4. **rc.5 is 2 days old and the crate ships ~1 release/day.** Pinning it means re-bumping soon. Acceptable — the librustzcash requirements have been stable across rc.3→rc.5, so bumps stay cheap.
5. **Only one round is registered in production config**, with a fixed snapshot. `PirSnapshotResolver` refuses any endpoint not serving exactly the expected height, so end-to-end testing is gated on that round's PIR servers being live and in sync. Plan a testnet or local-PIR harness (the crate added one in #166) rather than depending on prod.
6. **`zodl-production` flag flip.** Lowest technical risk, highest blast radius: it exposes a never-shipped 7,300-line surface to real funds. Gate it behind internal/testnet soak, not behind confidence.

# 4. FIRST VERIFICATIONS

1. **`git merge --no-commit origin/main` onto the team's base and confirm it reproduces `a3823651`'s tree** for `Cargo.toml`, `rust/src/voting/`, `Sources/.../Rust/Voting/`. If it does, S1 is free and the plan holds. If it conflicts, the whole sizing changes and I want to know first.
2. **`cargo check` with `zcash_voting = "2.0.0-rc.5"` on the `a3823651` tree.** This is the single cheapest test of my central claim that rc.3→rc.5 is a drop-in. Expected outcome: exactly one class of error, at `delegation.rs:419/461/542` on `connect_pir`. Any librustzcash resolution error refutes me and S2 needs re-planning.
3. **Read `rust/src/voting/vote.rs`'s `commit_vote` body and `json.rs`'s `JsonVoteCommit`** against `VotingCoordFlowCoordinator.swift:1876-1940`, specifically for how vote-commitment-tree position is supplied and when the bundle is persisted. This decides whether S3 is a 1-hour collapse or a real refactor — it is the one place my line estimate could be off by 3x.
4. **Build `zodl-internal` with `VOTING_ENABLED=1` against the `a3823651` SDK, before any other change.** The compiler enumerates the app↔SDK gap for free and confirms (or corrects) my six-symbol list. Do this before writing a single line.
5. **`nm -gU` the freshly built `libzcashlc.a` for `zcashlc_voting_commit_vote`.** Trivial, and it catches the FFI-staleness class of failure (risk 3) at the point where it is still cheap instead of at archive time.
