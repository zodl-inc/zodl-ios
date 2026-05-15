//
//  URIParserLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import ComposableArchitecture

extension URIParserClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            isValidURI: { uri, network in
                URIParser().isValidURI(uri, network: network)
            },
            checkRP: { data, network in
                RequestPaymentParser(network: network).checkRP(data)
            }
        )
    }
}
