//
//  URIParser.swift
//  Zashi
//
//  Created by Lukáš Korba on 17.05.2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit

struct URIParser {
    enum URIParserError: Error { }
    
    func isValidURI(_ uri: String, network: NetworkType) -> Bool {
        DerivationToolClient.live().isZcashAddress(uri, network)
    }
}
