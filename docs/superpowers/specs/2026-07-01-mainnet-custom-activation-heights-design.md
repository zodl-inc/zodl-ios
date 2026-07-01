# Mainnet identity with custom activation heights (Ironwood custom network)

**Ticket:** MOB-1455 · **Date:** 2026-07-01
**Repos:** `zcash-swift-wallet-sdk` (Rust FFI + Swift SDK), `ZODLIronwoodMigrationRust` (migration crate), `zodl-ios` (app)

## Motivation

The Ironwood testing backend is a **modified mainnet** node (`chainName: "main"`, Sapling at 1, NU6.3 at
5000). It was previously modeled as **regtest** because that was the SDK's only vehicle for custom
activation heights — but regtest identity gave wrong (regtest-encoded) addresses, failed the server
chain-name check, and the migration engine rejects regtest. The correct model is **mainnet identity with
custom activation heights**: `network_type() == Main` (mainnet addresses, `chainName "main"`) + custom
`activation_height()`.

`Parameters` is just `network_type()` + `activation_height()`, and all address encoding derives from
`network_type()`. `LocalNetwork` hardcodes `network_type() == Regtest`, so a new `Parameters` shape is
needed — built in the crates we own; **the `valargroup/librustzcash` fork is NOT modified.**

**Key routing constraint (revised approach).** The Swift SDK routes every FFI call by
`networkType.networkId`, so the *routing slot* and the *identity* are both derived from one `networkType`.
Making the Swift `networkType == .mainnet` would route to network_id 1 (real mainnet, baked-in heights) and
ignore the custom heights. Instead: the Swift network **stays on the id-2 "custom" slot
(`networkType == .regtest`)**, and identity is set in **Rust** via a configurable `base`. With
`base = Main`, the Rust core derives **mainnet-encoded addresses (`u1…`)** and runs mainnet consensus with
the custom heights — while the DB stays on the `ZcashSdk_regtest_` prefix, safely isolated from any real
mainnet wallet (no override needed). The `.regtest` tag leaks only into Swift-only checks (payment-URI
validation), handled/deferred as noted.

## Design (bottom-up)

### Layer 1 — SDK FFI (`zcash-swift-wallet-sdk/rust/src/lib.rs`)

Generalize the regtest plumbing to a configurable base identity:

- `NetworkParams::Regtest(LocalNetwork)` → **`NetworkParams::Custom { base: NetworkType, local: LocalNetwork }`**.
  `network_type()` returns `base`; `activation_height()` delegates to `local`.
- `REGTEST_PARAMS: RwLock<Option<LocalNetwork>>` → `CUSTOM_PARAMS: RwLock<Option<(NetworkType, LocalNetwork)>>`.
- `zcashlc_set_regtest_activation_heights(...)` → **`zcashlc_set_custom_network(base_network_id: u32, overwinter, …, nu6_3)`**;
  stores `(base, local)`.
- `parse_network(NETWORK_ID_REGTEST=2)` → `NetworkParams::Custom { base, local }`.
- **network_id 2 stays the dedicated "custom" slot** — real mainnet (id 1) is untouched, so production
  mainnet users are unaffected.
- Regenerate/patch `zcashlc.h` (check `rust/build.rs` / cbindgen).

### Layer 2 — Migration crate (`ZODLIronwoodMigrationRust`)

The crate's `Db` is pinned to `consensus::Network` (Main/Test only). **Genericize over `P: Parameters`**
(Approach 1 — keeps the Android `backend-lib` consumer source-compatible: it keeps passing
`consensus::Network`, which impls `Parameters`):
- `type Db = WalletDb<Connection, consensus::Network, …>` → `Db<P> = WalletDb<Connection, P, …>`.
- `MigrationContext` → `MigrationContext<P: Parameters>`; backend fns → `<P: Parameters>`.
- `network_str()` → derive from `P::network_type()` (so "main"/"test"/"regtest" fall out).
- `crate::types::Network` (`pub use consensus::Network`) kept for existing callers.

### Layer 3 — Migration FFI (`zcash-swift-wallet-sdk/rust/src/migration.rs`)

- Delete `migration_network()`'s MOB-1455 regtest-reject.
- Resolve the network via `crate::parse_network(network_id)` → `NetworkParams`, pass into
  `MigrationContext::<NetworkParams>::new(...)`.

### Layer 4 — SDK Swift (`ZcashLightClientKit`)

The custom network **keeps `networkType == .regtest`** (FFI calls route to the id-2 custom slot; DB stays on
`ZcashSdk_regtest_`, isolated from real mainnet). Identity is set in **Rust** via `base`:
- `ZcashRegtest` gains `let base: NetworkType` (default `.regtest`) exposed via the protocol as
  `customNetworkBase`. `ZcashNetworkBuilder.custom(base: NetworkType, activationHeights:)` builds it with
  `base = .mainnet`; `regtest(activationHeights:)` stays (`base = .regtest`).
- `ZcashRustBackend.setRegtestActivationHeights(_:)` → **`setCustomNetwork(base:_ heights:)`**, passing
  `base.networkId` to the FFI. `Initializer` calls it when `customActivationHeights != nil`.
- Because Rust derives addresses/consensus with `base = Main`, **addresses come out mainnet-encoded
  (`u1…`)** and consensus runs mainnet-with-custom-heights — even though the Swift tag is `.regtest`.
- `ValidateServerAction`: the `customActivationHeights != nil` relaxation (chain-name + branch-id
  tolerance) **stays** (the Swift tag is still `.regtest`, so the chain-name check is skipped as before).

### Layer 5 — ZODL app (`zodl-ios`)

Minimal — the network still reports `.regtest`, so the env wiring keyed on `.regtest` is unchanged:
- `IronwoodRegtestConfig.network` → `ZcashNetworkBuilder.custom(base: .mainnet, activationHeights:)`
  (was `.regtest(activationHeights:)`). Endpoint + heights unchanged.
- Migration is no longer network-blocked, so the `MigrationSDK` live engine works — no app gating needed;
  addresses now render `u1…`.
- **Deferred:** `ParserContext.from(.regtest)` still uses regtest HRPs, so payment-URI validation of the
  now-mainnet addresses would be wrong. This affects only the send/URI flow, not sync/balances/receive;
  tracked as a follow-up (map the Ironwood custom network to `ParserContext.mainnet`).

## What changes from the regtest attempt

- **Reworked:** the Rust FFI network enum + setter (`Custom { base, local }`, `zcashlc_set_custom_network`),
  the migration crate (genericized over `Parameters`) + migration FFI (stub removed), the SDK Swift network
  (`base` + `custom` builder + `setCustomNetwork`), and one line in `IronwoodRegtestConfig`.
- **Kept unchanged:** the `ValidateServerAction` relaxation, the app's `.regtest` env branches, and the
  `ZcashSdk_regtest_` DB namespace (data-safe for free).

## Verification

- Rust: `cargo build` + `cargo test` for the migration crate and the FFI crate (host target).
- `./Scripts/rebuild-local-ffi.sh ios-sim` — rebuild the simulator xcframework slice.
- App: `xcodebuild build-for-testing`/`test` scheme `zodl-internal`, `-skipMacroValidation` — compiles
  against the rebuilt FFI, full suite green.
- Live: user re-runs on the simulator against the Ironwood backend — mainnet-encoded addresses, sync,
  balances, and (previously blocked) migration status all work.

## Risks

- **DB collision** with real mainnet — mitigated by the distinct custom prefix (must verify the prefix is
  actually applied to all four db URLs).
- **Rebuild slice** — `rebuild-local-ffi.sh` produces a single-slice (ios-sim) xcframework; device/AppStore
  builds need their own rebuild. Fine for simulator testing.
- **Consensus correctness past NU6.3** vs the modified-Zebra backend — surfaced only by the live run.
