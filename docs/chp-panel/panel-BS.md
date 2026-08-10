# Panel B-S — Sonnet, blind (no Android materials)

> Verbatim final report, 2026-08-10. Brief: minimal shared context; Android repos/PRs barred.
> Adjudication note (orchestrator): the "SDK glue dodges the rc.4 PIR break" inference in
> FINDINGS was refuted by compiler evidence (E0061 at delegation.rs:420 on an accidental rc.5
> resolve) — see CHP.md §11, divergence D2. The report's own risk #2 anticipated exactly this.

---

FINDINGS

**App** (`/Users/lukaskorba/Dev/Xcode/GitHub/LukasKorba/_migration/zodl-ios`, working tree): Coinholder Polling is fully built — ~15,071 lines across `secant/Sources/Features/Voting/`, `Features/CoordFlows/VotingCoordFlow/`, `Dependencies/Voting{API,Crypto,Storage,MetadataProvider}Client/`, `Dependencies/VotingModels/`, plus 2,469 lines of tests in `zodlTests/VotingTests/`. All of it is wrapped in `#if VOTING_ENABLED`/`#endif` by commit `ab109d8e` ("Disable Voting at compile time," 2026-07-25) and untouched since. `VOTING_ENABLED` is not defined in any build config in `secant.xcodeproj/project.pbxproj` (no xcconfig files exist) — it's a total, clean off-switch, no partial gating found anywhere (Settings entry point, CoordFlow presentation, reducer wiring, all 5 test files consistently gated). `docs/voting-service-discovery.md` (ZIP 1244: pinned static config → CDN dynamic config → chain REST for rounds) is still accurate — I hit the live pinned URL and it's HTTP 200, serving a real production config with 9 vote-server operators including `zvote.zodl.com`. The app consumes the SDK via a **local sibling SPM path** (`../zcash-swift-wallet-sdk`, no `Package.resolved`), so "update the SDK" is just advancing that sibling checkout — no tag/URL bump.

**SDK-Swift** (`zcash-swift-wallet-sdk`, dev tip = branch `fable/gardening-test` @ `93a11081`): the Swift wrapper the app needs (`VotingRustBackend.swift` 1940 lines/~69 public members, `VotingTypes.swift`, `VotingConstants.swift`, `PirSnapshotResolver.swift` — 2,796 lines total) **does not exist** on this branch. It exists complete on origin/main (`a1234039`, via PR #1954), unconditionally compiled — SPM needs no extra wiring, `Package.swift` has zero voting-specific gating. A same-day merge (`a3823651`, authored by Lukas today, branch `chp-re-enable`) already proves origin/main's voting reinstatement merges cleanly onto the current stack with **Rust `cargo check` green**, deliberately keeping this branch's newer librustzcash pin and its own `zodl-slipstream` dep over main's older ones.

**SDK-Rust** (`rust/src/voting/*.rs`, 5,785 dead lines on the current stack): gated by exactly one `#[cfg(zcash_voting)]` on `mod voting;` in `rust/src/lib.rs`, true only if the commented-out `zcash_voting` dependency/feature/`[patch.crates-io]` block in `Cargo.toml` were active. Same minimal-off-switch shape as the app. Origin/main's replacement is a near-total rewrite (+5957/-1756 across `voting/*.rs`) since the crate's API moved past whatever pre-rc.1 generation the dead code targeted. At origin/main `zcash_voting` is unconditional — no cfg, no Cargo feature — so once merged it just builds via the existing `init-local-ffi.sh`/release pipeline.

**Crate** (`valargroup/zcash_voting`): actively developed, 39 published versions. **2.0.0 is explicitly the Ironwood/NU6.3-native major line** — its own changelog for 2.0.0-rc.1: *"snapshot selection and governance PCZT construction [use] only Ironwood/V3 notes… Pre-NU6.3 Orchard/V2 voting is no longer supported... Ironwood voting no longer requires a custom Rust compile flag,"* hardened at rc.3 (*"NoteInfo::from_orchard_note now rejects non-Ironwood/V3 notes"*). So "Ironwood support" and "latest generation" are the same ask. **True latest is 2.0.0-rc.5** (2026-08-08, confirmed via crates.io API and the repo's own `main` `Cargo.toml`) — origin/main and the validated merge both pin **rc.3** (2026-08-05), two behind. rc.4 is a real diff: PIR connect functions gained an explicit `PirLayout` param and dropped `COMPILED_PIR_LAYOUT` from the prelude; the dynamic config gained a required top-level `pir_layout`; delegation-submission wire format changed; vote-share wire JSON dropped `all_enc_shares`. The SDK's glue builds its PIR client via `voting::PirClientBlocking::with_transport(...)` — not the changed free functions — so that specific break probably doesn't hit it, but `rust/src/voting/json.rs` still mirrors the now-dropped `all_enc_shares` field, and I confirmed **the live production dynamic config already serves `pir_layout`** (`pir_depth:19, tier0_layers:12, tier1_layers:7`) that the app's `VotingServiceConfig.swift` doesn't decode today. rc.5 is a small additive Keystone-signer-display fix, directly relevant to the app's existing `DelegationSigningStore.swift` hardware path.

**API drift, app↔SDK**: I checked 10 methods `VotingCryptoClientLiveKey.swift` calls against origin/main's `VotingRustBackend`: 8 match by name (`warmProvingCaches`, `verifyWitness`, `generateDelegationInputs`, `extractSpendAuthSig`, `extractPcztSighash`, `extractOrchardFvk`, `extractNcRoot`, `computeShareNullifier`); 2 don't (`signCastVote`, `decomposeWeight` — likely relocated into the crate's newer stateful session API). `VotingRustBackend` is not and never was hooked into the public `Synchronizer` protocol — it's a standalone class, so the app's own `Synchronizer` usage elsewhere is unaffected.

PROPOSAL

1. **SDK, Rust+Swift merge (~1 day)** — On the real dev branch, land what `a3823651` already proved: merge origin/main, same conflict policy (voting→main, migration/slipstream→ours, librustzcash pin→ours). Not new work, just landing a validated merge.
2. **SDK, Rust, rc.3→rc.5 (~0.5 day)** — Bump `zcash_voting` to rc.5 in the same motion so we don't land two revisions stale. Reconcile `rust/src/voting/json.rs`'s `all_enc_shares` mirror against the crate's new wire shape; grep for any other rc.4-renamed symbols the glue touches.
3. **SDK, full Swift build (~0.5-1 day)** — `a3823651` only proved `cargo check`; nobody has built the Swift side yet. Expect it clean since the wrapper arrives unmodified from origin/main.
4. **App, flip the flag (~1-2 days)** — Add `VOTING_ENABLED` to the relevant build configs in `project.pbxproj` (mirror how `SECANT_MAINNET`/`SECANT_TESTNET` are scoped), point the local SPM reference at the updated SDK checkout, compile, fix call sites. Expect on the order of the 2 confirmed renames plus whatever else the compiler finds — plumbing only, zero UI/flow redesign, since the disablement commit added guards and touched nothing else.
5. **App, config decode (~1-2 hrs)** — Add `pir_layout` to `VotingServiceConfig` to match what the live config already serves. Additive, inert until something reads it.
6. **App, tests (~0.5 day)** — Re-enable the 5 `VotingTests` files (already gated identically); fastest signal step 4's fixes are correct, not just compiling.
7. **Both, E2E pass (~1 day)** — Full round on testnet against the live config (already confirmed reachable) before flipping the flag on a mainnet release build.

**~1 focused engineer-week total**, dominated by steps 1 and 4. This matches the owner's framing exactly: "a lot of work" because it touches ~20K existing lines across 4 layers, "simple work" because it's a merge + compile-fix loop, not new design.

RISKS (ranked)

1. **Medium-High** — librustzcash pin coupling is standing, not one-time: `a3823651` had to override main's rev to satisfy this branch's newer `zcash_pool_migration`/`zcash_client_sqlite` floors. Every future librustzcash bump here must keep satisfying zcash_voting's own floor (`zcash_client_backend` 0.24.0-rc.7, `zcash_client_sqlite` 0.22.0-rc.7, `zcash_keys` 0.16.1, `zcash_protocol` 0.10.4, `pczt` ~0.9.2-3, orchard 0.15.x) or voting becomes the next casualty of a deadline.
2. **Medium** — rc.3→rc.5 is unproven anywhere; my read that the SDK glue dodges rc.4's PIR-signature change is inference from one call site, not a build.
3. **Medium** — I sampled 10 of the ~20+ SDK calls in the 879-line crypto client and 1114-line API client; the rest are unverified until a real compile. Budget a compile-fix loop, not a fixed patch list.
4. **Low-Medium** — Cross-org schema coupling: valargroup's dynamic config already moved past the app's decode once (`pir_layout`); fails safe today, but future publisher-side moves are outside this repo's control.
5. **Low** — Swift 6 strict concurrency: shapes look compatible (`VotingRustBackend` is `@unchecked Sendable`/NSLock-guarded, app code was made Swift-6-clean right before disablement) but unverified together.

FIRST VERIFICATIONS

1. Actually perform the origin/main merge on the real dev branch and run a **full Swift build**, not just `cargo check` — get the true compile-error list instead of my 10-method sample.
2. Bump to `zcash_voting` 2.0.0-rc.5 in that same merge and re-run `cargo check` — confirm for real whether rc.4's PIR-layout/wire changes touch `rust/src/voting/*.rs`.
3. Grep the merged tree for `signCastVote`/`decomposeWeight`-equivalent functionality to find their actual new home before touching the app's crypto client.
4. Flip `VOTING_ENABLED` in a scratch app build and let the compiler enumerate every broken call site in one pass rather than hand-diffing 2000+ lines.
5. Once compiling, drive the live dynamic config (confirmed reachable today, `pir_layout` included) through the app's actual `VotingConfigError`/`WalletCapabilities` path to confirm real end-to-end acceptance, not just schema compatibility on paper.
