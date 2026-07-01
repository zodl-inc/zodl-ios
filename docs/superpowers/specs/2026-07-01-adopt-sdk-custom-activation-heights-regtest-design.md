# Adopt SDK custom NU activation heights — Ironwood regtest dev hook

**Ticket:** MOB-1455
**Date:** 2026-07-01
**Branch:** `michal/MOB-1455-3-adopt-ironwood-sdk-custom-activation-height`
**SDK branch consumed (local package):** `michal/MOB-1455-4-set-activation-height`

## Context

The Zcash Swift SDK gained **configurable per-NU activation heights** (additive, opt-in). A new
`ZcashNetworkBuilder.regtest(activationHeights:)` produces a `ZcashNetwork` carrying custom heights, a
new public `NetworkType.regtest` case exists, and `ZcashNetwork` gained `saplingActivationHeight` /
`customActivationHeights`. This lets the app connect to a custom-parameter (regtest) `lightwalletd` —
the **Ironwood testing backend** — whose NUs activate at arbitrary heights.

The local SDK checkout (`../zcash-swift-wallet-sdk`) is already on the target branch with the full API,
so **no package-pin change is needed**. This spec covers the app-side adoption.

## Goal

Let a developer point the **internal (testnet) build** at the Ironwood regtest backend to **connect,
sync, and read balances**, selected by a **hardcoded dev hook** (no new scheme, no UI). Mainnet /
distribution builds are untouched and can never select regtest.

**Out of scope (SDK limitation):** the Orchard→Ironwood **migration is not supported on regtest** — the
migration FFI returns a "regtest not supported yet (MOB-1455)" error. This spec does connect/sync/balance
only.

## Concrete regtest configuration (provided)

- **Endpoint:** `lwd.157.245.208.35.sslip.io` : `443`, secure (TLS) = `true`.
- **Activation heights:** NU6.3 (Ironwood) = **5000**. All earlier upgrades active **from genesis
  (height 1)**.

> **Explicit assumption — easily changed.** Only NU6.3 = 5000 was specified. The design sets every
> upgrade below NU6.3 to height `1` (overwinter, sapling, blossom, heartwood, canopy, nu5, nu6, nu6_1,
> nu6_2) and NU6.3 to `5000` — the standard regtest shape (mature chain, Ironwood switches on at 5000).
> If the backend actually staggers NU6.1/NU6.2 (or others) at different heights, edit the single
> `NetworkActivationHeights` literal in `IronwoodRegtestConfig`. The handoff warns that a mismatch here
> makes the SDK's consensus-branch check disagree with the server between those heights.

- **Token name (UI):** `"TAZ"` (matches the testnet dev convention).
- **Chain name expected from the backend:** `"regtest"` (what the SDK maps). If the backend reports
  something else, the SDK team must add the mapping.

## Design

### 1. Compile-compat (required to build against the new SDK)

The new public `NetworkType.regtest` case breaks the one **active** exhaustive `NetworkType` switch:

- `ParserContext.from(networkType:)` in `Dependencies/URIParser/URIParserInterface.swift` — add
  `case .regtest: ParserContext.regtest`. The `ZcashPaymentURI` package already has `.regtest` with the
  correct `uregtest` / `zregtestsapling` / `texregtest` HRPs, so regtest addresses validate and parse
  correctly.

(`Features/Voting/VotingHelpers.swift` also switches exhaustively, but the whole file is behind
`#if VOTING_ENABLED`, which no build configuration defines — it does not compile, so no change there.)

### 2. `IronwoodRegtestConfig` — new single source of truth

New file `secant/Sources/Utils/IronwoodRegtestConfig.swift`:

```swift
import ZcashLightClientKit

/// Hardcoded dev configuration for pointing the app at the Ironwood regtest backend.
/// Activated by flipping `TargetConstants.useIronwoodRegtest` to `true` (testnet builds only).
enum IronwoodRegtestConfig {
    /// All upgrades below NU6.3 active from genesis; NU6.3 (Ironwood) at 5000.
    /// Adjust here if the backend staggers NU6.1/NU6.2 (or others) at other heights.
    static let activationHeights = NetworkActivationHeights(
        overwinter: 1, sapling: 1, blossom: 1, heartwood: 1, canopy: 1,
        nu5: 1, nu6: 1, nu6_1: 1, nu6_2: 1, nu6_3: 5000
    )

    static let endpoint = LightWalletEndpoint(
        address: "lwd.157.245.208.35.sslip.io",
        port: 443,
        secure: true,
        streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
    )

    static let tokenName = "TAZ"

    static var network: ZcashNetwork {
        ZcashNetworkBuilder.regtest(activationHeights: activationHeights)
    }
}
```

### 3. Dev hook in `TargetConstants` (`SecantApp.swift`)

- Add `static let useIronwoodRegtest = false` — the dev flips this to `true` to activate regtest.
- Reference it **only inside the `#if SECANT_TESTNET` branch**, so mainnet/distrib builds ignore it even
  if left `true`:
  - `zcashNetwork` (testnet branch) → `useIronwoodRegtest ? IronwoodRegtestConfig.network :
    ZcashNetworkBuilder.network(for: .testnet)`.
  - `tokenName` (testnet branch) → `useIronwoodRegtest ? IronwoodRegtestConfig.tokenName : "TAZ"`.

### 4. `ZcashSDKEnvironment` regtest wiring

- `defaultEndpoint(for:)` — return `IronwoodRegtestConfig.endpoint` when `network == .regtest`.
- `endpoints(for:)` — return `[IronwoodRegtestConfig.endpoint]` (or `[]` when `skipDefault`) for
  `.regtest`.
- `servers(for:)` — already returns `[.default]` for anything that is neither mainnet nor testnet, so
  regtest gets a single default server with **no code change** (no custom / benchmark list).
- `serverConfig(for:)` — short-circuit at the top: `if network == .regtest { return
  defaultEndpoint(for: .regtest).serverConfig() }`, bypassing the stored/custom-server logic and the
  mainnet/testnet migration helpers so a previously-stored testnet/mainnet server is never reused.
- `live(network:)` `tokenName` closure — switch on `network.networkType`: mainnet → `"ZEC"`, testnet →
  `"TAZ"`, regtest → `IronwoodRegtestConfig.tokenName`.

### 5. `AutoServerSelectionLiveKey.findBestServer`

Add `guard network != .regtest else { return nil }` after resolving `network`. `automaticServerSelection`
is a UserDefaults flag shared across networks, so a prior testnet run could leave it `true`; this makes
regtest explicitly never benchmark/switch away from the single fixed endpoint.

### 6. `WalletBirthdayStore` — use the instance Sapling height

Replace `zcashSDKEnvironment.network().constants.saplingActivationHeight` with
`zcashSDKEnvironment.network().saplingActivationHeight` (the `ZcashNetwork` instance value). Identical for
mainnet/testnet (instance defaults to `constants`), correct for regtest (instance carries the configured
Sapling height; `constants` is the fallback `1`).

### 7. Optional (nice-to-have)

Hide the Orchard→Ironwood migration CTA while the regtest hook is on, so a dev doesn't hit the SDK's
"regtest not supported" error mid-testing. Implement only if the gate is a trivial one-liner; otherwise
record in the final report.

## Testing (Swift Testing)

New suite (e.g. `zodlTests/RegtestActivationHeightsTests/RegtestActivationHeightsTests.swift`):

- `ParserContext.from(networkType: .regtest) == .regtest`.
- `ZcashSDKEnvironment.defaultEndpoint(for: .regtest)` host/port/secure match `IronwoodRegtestConfig`.
- `ZcashSDKEnvironment.endpoints(for: .regtest)` == `[IronwoodRegtestConfig.endpoint]`;
  `endpoints(for: .regtest, skipDefault: true) == []`.
- `ZcashSDKEnvironment.servers(for: .regtest) == [.default]`.
- `IronwoodRegtestConfig.network.customActivationHeights == IronwoodRegtestConfig.activationHeights` and
  `network.networkType == .regtest`, `network.saplingActivationHeight == 1`.
- `ZcashSDKEnvironment.live(network:).tokenName()` returns `"TAZ"` for the regtest network.

## Verification

CLI build of the `zodl-internal` scheme with `-skipMacroValidation` (CLI-first per global prefs) and run
the test suite. The regtest branches are ordinary runtime `if`s inside `#if SECANT_TESTNET`, so a normal
testnet build compiles and type-checks all new code with the hook left `false` (no behavior change).

## Files touched

- `secant/Sources/Utils/IronwoodRegtestConfig.swift` — **new**
- `secant/Sources/SecantApp.swift` — dev hook + network/token selection
- `secant/Sources/Dependencies/URIParser/URIParserInterface.swift` — `.regtest` ParserContext
- `secant/Sources/Dependencies/ZcashSDKEnvironment/ZcashSDKEnvironmentInterface.swift` —
  `defaultEndpoint` / `endpoints` for regtest
- `secant/Sources/Dependencies/ZcashSDKEnvironment/ZcashSDKEnvironmentLiveKey.swift` — `serverConfig`
  short-circuit + `tokenName`
- `secant/Sources/Dependencies/AutoServerSelection/AutoServerSelectionLiveKey.swift` — regtest guard
- `secant/Sources/Features/WalletBirthday/WalletBirthdayStore.swift` — instance Sapling height
- `zodlTests/RegtestActivationHeightsTests/RegtestActivationHeightsTests.swift` — **new**
- (optional) migration-CTA gate for regtest
