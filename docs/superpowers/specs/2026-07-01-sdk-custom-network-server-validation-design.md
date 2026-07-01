# SDK-Swift relaxation: custom-network server validation (Ironwood sync)

**Ticket:** MOB-1455
**Date:** 2026-07-01
**Code change repo:** `../zcash-swift-wallet-sdk` (SDK), branch `michal/MOB-1455-4-set-activation-height`
**App repo:** no code change (already regtest via `TargetConstants.useIronwoodRegtest = true`)

## Problem

With the app pointed at the Ironwood backend (regtest network + custom activation heights), syncing fails
immediately:

```
[ZCBPEO0012] compactBlockProcessorNetworkMismatch(regtest, mainnet)
```

**Root cause (verified via `grpcurl GetLightdInfo`):** the Ironwood backend is a *modified mainnet* node
(`/Zebra:5.0.0-test.8/…modified`) that reports `chainName: "main"`, `saplingActivationHeight: "1"`,
`consensusBranchId: "ffffffff"`. The SDK's `ValidateServerAction` derives the remote network purely from
`chainName` (`NetworkType.forChainName("main") → .mainnet`) and rejects it because the local wallet is
`.regtest`.

Full "mainnet identity + custom heights" is **not buildable in this repo** — `libzcashlc` is a prebuilt
binary xcframework (no Rust source), and its only custom-heights FFI
(`zcashlc_set_regtest_activation_heights`) binds heights to the **regtest** network id. So the wallet must
stay modeled as regtest (so the core applies the custom heights and scans correctly); the fix is to make
the SDK's Swift-level server validation tolerant of a custom network whose backend identifies differently.

## Goal

Let a custom-parameter network (`customActivationHeights != nil`) connect, sync, and read balances against
a backend that reports a different base `chainName` and a nonstandard consensus branch id. Mainnet/testnet
behavior is unchanged.

## Design

Single change in [`ValidateServerAction.swift`](../zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift).
Compute `let isCustomNetwork = localNetwork.customActivationHeights != nil`, then gate two of the four
checks on `!isCustomNetwork`:

| Check | Custom network | Rationale |
|-------|----------------|-----------|
| chainName parses (`forChainName != nil`) | **kept** | Still reject a totally unknown chain name. |
| network-type match (`remote == local`) | **skipped** | A custom backend may report `main`/`test`/`regtest`. This is the failing check today. |
| Sapling-activation match | **kept** | The safety net — a custom-heights wallet (sapling 1) is still rejected against a real main/test server (419200/280000), so we can't silently sync the wrong chain. |
| consensus-branch match | **skipped** | The backend may report a nonstandard/placeholder branch id (`"ffffffff"`); would fail next. |

```swift
let isCustomNetwork = localNetwork.customActivationHeights != nil

guard let remoteNetworkType = NetworkType.forChainName(info.chainName) else {
    throw ZcashError.compactBlockProcessorChainName(info.chainName)
}
if !isCustomNetwork {
    guard remoteNetworkType == localNetwork.networkType else {
        throw ZcashError.compactBlockProcessorNetworkMismatch(localNetwork.networkType, remoteNetworkType)
    }
}
guard saplingActivation == info.saplingActivationHeight else {
    throw ZcashError.compactBlockProcessorSaplingActivationMismatch(saplingActivation, BlockHeight(info.saplingActivationHeight))
}
if !isCustomNetwork {
    let localBranch = try rustBackend.consensusBranchIdFor(height: Int32(info.blockHeight))
    guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
        throw ZcashError.compactBlockProcessorConsensusBranchID
    }
    guard remoteBranchID == localBranch else {
        throw ZcashError.compactBlockProcessorWrongConsensusBranchId(localBranch, remoteBranchID)
    }
}
```

**Why safe:** the gate is `customActivationHeights != nil`, non-nil only for regtest/custom networks.
Mainnet and testnet keep all four checks exactly as before — zero behavioral change for real users.

**Second gate deliberately left unchanged:** `SDKSynchronizer.evaluateBestOf` (auto-server benchmark) has
a parallel chainName/branch filter, but the app disables auto-server-selection for regtest
(`AutoServerSelectionLiveKey.findBestServer` returns `nil`), so it never runs on the sync path. Relaxing it
too is a speculative (YAGNI) follow-up; noted, not done.

## Tests (SDK, XCTest — extend `ValidateServerActionTests`)

Add an `underlyingNetwork: ZcashNetwork?` override to `setupAction()` (falls back to the existing
`network(for: underlyingNetworkType)`), then:

1. `testValidateServerAction_CustomNetworkAcceptsMismatchedChainAndBranch` — regtest custom network,
   `chainName "main"`, branch `"ffffffff"`, matching Sapling → reaches `.fetchUTXO` (no throw).
2. `testValidateServerAction_CustomNetworkStillChecksSaplingActivation` — regtest custom network,
   `chainName "main"`, but `saplingActivationHeight 419200` → still throws
   `compactBlockProcessorSaplingActivationMismatch(1, 419200)`.

Existing mainnet/testnet cases must keep passing (regression guard).

## Verification

- SDK: `swift test --filter ValidateServerActionTests` (CLI-first) from `../zcash-swift-wallet-sdk`.
- App: `xcodebuild build`/`test` scheme `zodl-internal`, `-skipMacroValidation` — no compile break, full
  suite still green (the app links the SDK as a local package, so it picks up the source change).
- Live sync: user re-runs the app against the Ironwood backend and confirms the ZCBPEO0012 error is gone
  and syncing proceeds.

## Caveats (on the record)

- Addresses stay **regtest-encoded** (`uregtest…`) — cosmetic for read-only balances; correct
  mainnet-address display and sending need the deferred Rust rebuild.
- Scanning past NU6.3 (5000) relies on the binary core's Ironwood consensus matching the modified-Zebra
  backend — cannot be fully de-risked in this repo; surfaced by a live run.

## Files touched

- `../zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift`
- `../zcash-swift-wallet-sdk/Tests/OfflineTests/CompactBlockProcessorActions/ValidateServerActionTests.swift`
