# Panel A-S — Sonnet, with Android PR access

> Verbatim final report, 2026-08-10. Brief: minimal shared context + the two Android PRs.
> Adjudication note (orchestrator, not the arm): this report's §2 underscopes the app-side work —
> it misses the six-call→`commitVote` collapse because the Android PR only shows Android's *last*
> delta (their app already sat on the commitVote API). See CHP.md §11, divergence D1.

---

## 1. FINDINGS

**App (`zodl-ios`)** — the entire CHP UI/flow already exists and is fully built: ~15,071 lines across `secant/Sources/Features/Voting/`, `secant/Sources/Features/CoordFlows/VotingCoordFlow/`, and the `Voting*` dependency clients. All of it sits behind `#if VOTING_ENABLED`, and that symbol appears **nowhere** in any `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `secant.xcodeproj/project.pbxproj` — so in every current build config it compiles to nothing. Last real edit to `Voting/` was `ab109d8e "Disable Voting at compile time"`; the code has had zero compiler attention since and targets an **older** SDK contract than what's being restored: hotkey struct still `secretKey`/`publicKey` (`VotingCryptoClientLiveKey.swift:184-185`, `VotingModels.swift:258-264`) and the API body still sends `"sighash"` (`VotingAPIClientLiveKey.swift:898`) — both renamed upstream (see below). The app depends on the SDK via `XCLocalSwiftPackageReference relativePath = "../zcash-swift-wallet-sdk"` — a local-path checkout, not a pinned remote tag — so there is no SPM version to bump, only "the sibling checkout must contain the compiled voting surface."

**SDK-Swift/Rust** — `93a11081` (iOS team's current stack) already contains a full prior voting implementation in `rust/src/voting/*.rs`, just compiled out via `#[cfg(zcash_voting)]` + a commented `zcash_voting` Cargo dependency. `a3823651` (= that stack + origin/main's voting restoration, cargo-check green) shows the *entire* delta is isolated to `rust/src/voting/*`, four wholly-new Swift files (`Sources/ZcashLightClientKit/Rust/Voting/{PirSnapshotResolver,VotingConstants,VotingRustBackend,VotingTypes}.swift`, 1940+568+... lines), `Tests/OfflineTests/VotingRustBackendTests.swift` (1527 lines, no skip markers), and trivial repo metadata — nothing else in the SDK moves. The Rust module's public function signatures are **unchanged** between the two SHAs despite +664 lines; that growth is ~20 new `#[test]`s, not new production logic. The C ABI (`ffi_types.rs`) changed by only 30 lines: `FfiVotingHotkey.secret_key/public_key` → `stored_secret/raw_orchard_address/address_index`, plus one new `dropped_count` field. `orchard`'s `unstable-voting-circuits` feature does **not** need explicit requesting in the SDK's own Cargo.toml — confirmed the crate's own workspace root (`Cargo.toml@v2.0.0-rc.5`) requests it, so Cargo's feature unification turns it on transitively for any consumer; this is a verified non-issue, not a gap.

**Crate (`zcash_voting`)** — `a3823651` pins `2.0.0-rc.3` (2026-08-05). Latest is `2.0.0-rc.5` (2026-08-08); `rc.4` (2026-08-07) is a real breaking change: delegation submissions now carry an 821-byte versioned Ironwood `tx1_effects` blob instead of a raw `sighash`; `connect_pir`/`connect_pir_blocking` take an explicit `PirLayout` and fail closed on mismatch (no more compiled-in `COMPILED_PIR_LAYOUT`); vote-share wire JSON drops `all_enc_shares`. `rc.5` is a small Keystone display fix only. The crate has been **Ironwood/V3-only since rc.1** ("Pre-NU6.3 Orchard/V2 voting is no longer supported... Ironwood voting no longer requires a custom Rust compile flag") — Ironwood support is a side effect of the version bump, not separate work.

**Android reference** (`bugfix/MOB-1678`, both PRs MERGED) — this is Android's own rc.3→rc.4 migration plus one Android-specific bugfix: a locally-invented round-level `RoundPhase` write during PCZT construction raced the crate's own per-bundle `DelegationPhase` and crashed multi-bundle rounds ("refusing to regress round phase"). iOS's `rust/src/voting/delegation.rs` has **zero** "phase" references at `a3823651` — this bug class is very unlikely to be inherited on the Rust side.

## 2. PROPOSAL

1. **SDK-Rust** — land `a3823651`'s voting restoration for real (merge/cherry-pick onto the team's actual working branch, not just this exploratory SHA), then bump `zcash_voting` `2.0.0-rc.3 → 2.0.0-rc.5` in `Cargo.toml`. Adapt the three rc.4 touch points in `rust/src/voting/{delegation,helpers,ffi_types}.rs`: thread an explicit `PirLayout` into the PIR-connect call, add/rename the delegation-submission field to `tx1_effects` (821 bytes), drop `all_enc_shares` from vote-share assembly. **Size:** ~60-100 lines, same order as Android's Rust diff. This touches the FFI boundary → CLAUDE.md requires the full `./Scripts/init-local-ffi.sh`, not `rebuild-local-ffi.sh`.
2. **SDK-Swift** — mirror the same rename/threading in `Sources/ZcashLightClientKit/Rust/Voting/{VotingTypes,VotingRustBackend}.swift`. These files already exist and compile against rc.3's shape; only the rc.3→rc.5 delta needs hand-editing. **Size:** a few dozen lines across two already-correct files.
3. **App — the actual re-enable**: (a) add `VOTING_ENABLED` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the `SECANT_TESTNET` debug configs only in `project.pbxproj` — the literal switch flip; (b) rename the 7 hotkey-field occurrences (`VotingCryptoClientLiveKey.swift`, `VotingModels.swift`) to match step 2's new shape; (c) rename `sighash`→`tx1Effects` through `VotingModels.swift`, `VotingAPIClientLiveKey.swift` (JSON key `"sighash"`→`"tx1_effects"`), and the CoordFlow call sites. **Size:** bounded to the ~2,773-line SDK-boundary trio (`VotingCryptoClientLiveKey.swift` 879, `VotingModels.swift` 780, `VotingAPIClientLiveKey.swift` 1114 lines) — no `*View.swift` or UI-facing reducer should need to change, satisfying "keep UI/flows unchanged."
4. **App config data** — verify/update `StaticVotingConfig`'s pinned URL (`secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift:12`, currently `raw.githubusercontent.com/valargroup/...`) against Android's now-live `https://voting.valargroup.org/prod/static-voting-config.json`; add a `pirLayout` field mirroring `VotingServiceConfig`'s new `pir_layout` key. **Size:** ~10-20 lines, data only.
5. **Verify** — `swift build` + `swift test --filter OfflineTests` (existing `VotingRustBackendTests.swift`), then one live testnet round end-to-end, mirroring Android's own test plan.

Proactive add, not reactive: expose the crate's per-bundle `DelegationPhase` (Android's `delegationPhasesNative`/`resetVotingSessionStateNative`) in the iOS FFI surface now rather than after hitting the same multi-bundle crash — the primitive already exists in the crate, it's a passthrough, and Android already proved it's needed.

## 3. RISKS (ranked)

1. **FFI-boundary build cost** — `ffi_types.rs` changes force the full 5-arch `init-local-ffi.sh`; Android's own CI timeout for this exact change went 30→60 min from Halo2 voting-circuit codegen. Untested here whether iOS pays the same tax, and this collides with the project's known FFI-slice-staleness traps.
2. **App-SDK drift beyond what's visible from source** — the app's Voting code predates even rc.3 and was never flag-flipped since; I found two confirmed deltas (hotkey fields, sighash), but 15k LOC of never-compiled `#if` code could hide more. Only a real compile surfaces the full list.
3. **PIR/server lockstep** — rc.4's `PirLayout` fails closed on server mismatch; unverified whether the PIR/vote-chain servers iOS will hit are already rc.4-compatible (same servers Android hits, so likely yes, but not confirmed from iOS's side).
4. **Duplicated phase-tracking, unverified at the app layer** — Rust side is clean, but `VotingCoordFlowStore.swift`/`RoundSession.swift` haven't been read line-by-line for an independently-invented, differently-named round-phase gate.
5. **Test coverage gap** — `VotingRustBackendTests.swift` is DB/unit-level; Android's regression was NOT caught by their equivalent suite, only by a live multi-bundle on-device round.

## 4. FIRST VERIFICATIONS

1. Merge `a1234039`'s voting module onto the real working branch, bump to `2.0.0-rc.5`, `cargo check` — confirm the only breaks are the three Android already documented.
2. `swift build && swift test --filter OfflineTests` against that state — confirm `VotingRustBackendTests.swift` passes unmodified.
3. Flip `VOTING_ENABLED` on for one testnet config and compile the app — treat the compiler-error list as the authoritative "what else changed" diff, faster than manual audit.
4. Fetch both `StaticVotingConfig` URLs (current pin vs Android's) to confirm which is actually live.
5. Grep `VotingCoordFlow/*.swift` and `Voting/*/**Store.swift` for any home-grown round/bundle-phase gate before assuming Rust-layer cleanliness extends to the app.

## 5. ZERO-NEW-CODE CHECK

Combined Android PRs: 32 files, +888/-250 (app 374/-126, SDK 514/-124).

- **Autogenerated/pure infra:** `Cargo.lock` alone is 204 of the SDK PR's 514 additions (40%); CI timeout comment + `Cargo.toml`/`build.gradle.kts` uncomment-and-bump adds ~26 more. ~230 lines, effectively free.
- **Mechanical rename/parameter-threading**, repeated verbatim through JNI→TypesafeBackend→CryptoClient→Repository→UseCase: ~250-300 lines, same 3-line pattern copy-pasted 5-8× per field.
- **Pure 1:1 mirrors of crate-native types** (`DelegationPhase`, `BundleDelegationPhase`, `VotingPirLayout`, `JniDelegationPhase`): ~70 lines, transcription not design.
- **Net deletions** of the buggy zodl-only phase-advancement code + its dedicated tests: ~95 lines removed — negative new-code.
- **Genuinely authored logic, generously counted:** ~90-100 lines total, and all of it is stock defensive-programming idiom, not protocol/crypto work (that stays inside the untouched crate).

**Verdict: ~85% mechanical, ~15% authored, 0% novel algorithm.** Strong first-hand confirmation of "simple work."

Mechanical, verbatim:
```kotlin
// VotingRequests.kt / VotingApiProvider.kt
- val sighash: ByteArray                          → + val tx1Effects: ByteArray
- .put("sighash", sighash.toBase64String())        → + .put("tx1_effects", tx1Effects.toBase64String())
// MoreVM.kt — the switch itself
- internal const val VOTING_ENABLED = false        → + internal const val VOTING_ENABLED = true
```
```rust
// rounds.rs — new JNI export, entire body is a passthrough to a call the crate already had
let phases = db.delegation_phases(&round_id).map_err(|e| anyhow!("delegation_phases: {}", e))?;
make_jni_delegation_phases(env, phases)
```

New logic, verbatim:
```kotlin
// SubmitVotesUseCase.kt — staleness guard
var setupJustBuilt = false
...}.onSuccess { setupJustBuilt = true }.recoverCatching { if (!it.isDelegationSetupOverwrite()) throw it }.getOrThrow()
val alreadyProved = !setupJustBuilt && currentDelegationPhase(...).let { it == PROVED || it == SUBMITTED || it == CONFIRMED }
```
```kotlin
// VotingKeystoneRepository.kt — retry-once-after-reset
val governancePczt = runCatching { votingCryptoClient.buildGovernancePczt(...) }
    .recoverCatching { if (!it.isDelegationSetupOverwrite()) throw it
        votingCryptoClient.resetVotingSessionState(dbHandle, roundId)
        votingCryptoClient.buildGovernancePczt(...) }.getOrThrow()
```
