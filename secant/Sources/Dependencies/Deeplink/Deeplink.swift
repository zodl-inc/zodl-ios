//
//  Deeplink.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.06.2022.
//

import Foundation
import URLRouting
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

enum Deeplink {
    enum Destination: Equatable {
        case home
        case send(amount: Int, address: String, memo: String)
    }
    
    static func resolveDeeplinkURL(
        _ url: URL,
        networkType: NetworkType,
        isValidZcashAddress: (String, NetworkType) throws -> Bool
    ) throws -> Destination {
        // simplified format zcash:<address>
        // TODO: [#109] simplified for now until ZIP-321 is implemented (https://github.com/Electric-Coin-Company/zashi-ios/issues/109)
        let address = url.absoluteString.replacingOccurrences(of: "zcash:", with: "")
        do {
            if try isValidZcashAddress(address, networkType) {
                return .send(amount: 0, address: address, memo: "")
            }
        }
      
        // regular URL format zcash://
        let appRouter = OneOf {
            // GET /home
            Route(.case(Destination.home)) {
                Path { "home" }
            }

            // GET /home/send?amount=:amount&address=:address&memo=:memo
            Route(.case(Destination.send(amount:address:memo:))) {
                Path { "home"; "send" }
                Query {
                    Field("amount", default: 0) { Digits() }
                    Field("address", .string, default: "")
                    Field("memo", .string, default: "")
                }
            }
        }

        switch try appRouter.match(url: url) {
        case .home:
            return .home

        case let .send(amount, address, memo):
            return .send(amount: amount, address: address, memo: memo)
        }
    }
}
