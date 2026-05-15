//
//  RequestPaymentParser.swift
//
//
//  Created by Lukáš Korba on 24.05.2024.
//

import Foundation
import ZcashPaymentURI
@preconcurrency import ZcashLightClientKit

struct RequestPaymentParser {
    let network: NetworkType 

    enum URIParserError: Error { }

    func checkRP(_ dataStr: String) -> ParserResult? {
        try? ZIP321.request(from: dataStr, context: ParserContext.from(networkType: network))
    }
}

