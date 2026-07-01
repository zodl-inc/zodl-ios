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

- `ZcashNetworkBuilder.regtest(activationHeights:)` → **`.custom(base: NetworkType, activationHeights:)`**.
  The returned `ZcashNetwork` reports `networkType == base` (`.mainnet` here) and
  `customActivationHeights != nil`.
- `ZcashRustBackend.setRegtestActivationHeights(_:)` → **`setCustomNetwork(base:_ heights:)`**, passing the
  base network id to the renamed FFI. `Initializer` calls it when `customActivationHeights != nil`.
- **DB namespace (DATA SAFETY):** the custom network reports `.mainnet`, so its `constants` must return a
  **distinct** `defaultDbNamePrefix` (e.g. `ZcashSdk_ironwood_`) — never the real mainnet prefix. The
  custom `ZcashNetwork`'s `constants` provides this.
- `ValidateServerAction`: with `network_type == Main`, the chain-name check now passes on its own; the
  `customActivationHeights != nil` relaxation (branch-id `"ffffffff"` tolerance) **stays**.

### Layer 5 — ZODL app (`zodl-ios`)

- `IronwoodRegtestConfig` → **`IronwoodNetworkConfig`**: builds `.custom(base: .mainnet, activationHeights:)`;
  endpoint `lwd.157.245.208.35.sslip.io:443`; heights all-genesis + NU6.3 = 5000.
- Re-key the env branches previously tied to `.regtest` → **`customActivationHeights != nil`**
  (`ZcashSDKEnvironmentInterface.defaultEndpoint`/`endpoints`, `ZcashSDKEnvironmentLiveKey.serverConfig`
  short-circuit + `tokenName`, `AutoServerSelectionLiveKey` guard). The network now reports `.mainnet`, so
  `networkType == .regtest` no longer fires.
- `TargetConstants.useIronwoodRegtest` stays a dev hook (rename optional); addresses now render `u1…`.
- Migration is no longer network-blocked, so the `MigrationSDK` live engine works — no app gating needed.

## What changes from the regtest attempt

- **Reworked:** SDK `ZcashNetworkBuilder`, the Rust FFI network enum + setter, the app's `.regtest` env
  branches (→ `customActivationHeights != nil`), `IronwoodRegtestConfig` → custom-network config, DB prefix.
- **Kept:** the `ValidateServerAction` relaxation (still needed for the `"ffffffff"` branch id, still gated
  on custom networks) and the migration-crate genericization (now the primary enabler).

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
