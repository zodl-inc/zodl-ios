//
//  IronwoodRegtestConfig.swift
//  secant
//
//  Hardcoded dev configuration for pointing the app at the Ironwood regtest backend (MOB-1455).
//

import ZcashLightClientKit

/// Hardcoded dev configuration for connecting the app to the **Ironwood regtest backend** — a
/// custom-parameter `lightwalletd` whose network upgrades activate at arbitrary heights.
///
/// Activated by flipping ``TargetConstants/useIronwoodRegtest`` to `true`, which is honored only in
/// `SECANT_TESTNET` builds. Connect / sync / read balances only — the Orchard→Ironwood migration is
/// not supported on regtest yet (the SDK returns a "regtest not supported yet (MOB-1455)" error).
enum IronwoodRegtestConfig {
    /// The backend's NU activation heights (`nuparams`). Every upgrade below NU6.3 is active from
    /// genesis (height 1); NU6.3 (Ironwood) activates at 5000. Adjust here if the backend staggers
    /// NU6.1 / NU6.2 (or others) at different heights — a mismatch makes the SDK's consensus-branch
    /// check disagree with the server between those heights.
    static let activationHeights = NetworkActivationHeights(
        overwinter: 1,
        sapling: 1,
        blossom: 1,
        heartwood: 1,
        canopy: 1,
        nu5: 1,
        nu6: 1,
        nu6_1: 1,
        nu6_2: 1,
        nu6_3: 5000
    )

    /// The Ironwood regtest `lightwalletd` endpoint. Computed (not a stored `static let`) because
    /// `LightWalletEndpoint` is not `Sendable`; a stored global would fail Swift 6 concurrency checks.
    static var endpoint: LightWalletEndpoint {
        LightWalletEndpoint(
            address: "lwd.157.245.208.35.sslip.io",
            port: 443,
            secure: true,
            streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        )
    }

    /// Token name shown in the UI for the regtest build.
    static let tokenName = "TAZ"

    /// The regtest ``ZcashNetwork`` carrying the custom activation heights.
    static var network: ZcashNetwork {
        ZcashNetworkBuilder.regtest(activationHeights: activationHeights)
    }
}
