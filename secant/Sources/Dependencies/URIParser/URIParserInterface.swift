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
            // Regtest (SDK networkId 2, custom activation heights) has no URI context of its own;
            // its addresses are testnet-encoded, so the testnet context is the correct parser.
            ParserContext.testnet
        }
    }
}
