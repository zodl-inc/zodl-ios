//
//  URIParserClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 17.05.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import ZcashPaymentURI

extension DependencyValues {
    var uriParser: URIParserClient {
        get { self[URIParserClient.self] }
        set { self[URIParserClient.self] = newValue }
    }
}

@DependencyClient
struct URIParserClient {
    var isValidURI: @Sendable (String, NetworkType) -> Bool = { _, _ in false }
    var checkRP: @Sendable (String, NetworkType) -> ParserResult? = { _, _ in nil }
}

extension ParserContext {
    static func from(networkType: NetworkType) -> ParserContext {
        switch networkType {
        case .mainnet:
            ParserContext.mainnet
        case .testnet, .regtest:
            // `.regtest` is aliased onto the testnet context only to satisfy exhaustiveness. It is
            // a known simplification, NOT a correct mapping: `ParserContext` declares its own
            // `.regtest` with different HRPs (`zregtestsapling`/`uregtest`/`texregtest`/`t3`), and
            // custom-network addresses are regtest-encoded, not testnet-encoded. Unreachable today
            // because `TargetConstants.zcashNetwork` only ever builds `.mainnet`/`.testnet`.
            //
            // A real regtest build must not simply add a `.regtest` arm here: the SDK hardcodes
            // `networkType = .regtest` for every custom network regardless of its base, so
            // `NetworkType` alone cannot say whether addresses are regtest- or mainnet-encoded
            // (a `base: .mainnet` Ironwood chain derives mainnet addresses). Dispatch on
            // `ZcashNetwork.customNetworkBase ?? networkType` instead of `NetworkType`.
            ParserContext.testnet
        }
    }
}
