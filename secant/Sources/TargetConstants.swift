//
//  TargetConstants.swift
//  secant
//
//  Extracted from SecantApp so the network/token constants are available to every
//  app shell (the iOS `SecantApp` @main and the macOS entry), not just iOS.
//

import ZcashLightClientKit

// MARK: Zcash Network global type

/// Whenever the ZcashNetwork is required use this var to determine which is the
/// network type suitable for the present target.
enum TargetConstants {
    static var zcashNetwork: ZcashNetwork {
#if SECANT_MAINNET
    return ZcashNetworkBuilder.network(for: .mainnet)
#elseif SECANT_TESTNET
    return ZcashNetworkBuilder.network(for: .testnet)
#else
    fatalError("SECANT_MAINNET or SECANT_TESTNET flags not defined on Swift Compiler custom flags of your build target.")
#endif
    }

    static var tokenName: String {
#if SECANT_MAINNET
    return "ZEC"
#elseif SECANT_TESTNET
    return "TAZ"
#else
    fatalError("SECANT_MAINNET or SECANT_TESTNET flags not defined on Swift Compiler custom flags of your build target.")
#endif
    }
}
