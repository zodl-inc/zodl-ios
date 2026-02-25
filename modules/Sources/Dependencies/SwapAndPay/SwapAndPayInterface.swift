//
//  SwapAndPayInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-15-2025.
//

import ComposableArchitecture
import Models

extension DependencyValues {
    public var swapAndPay: SwapAndPayClient {
        get { self[SwapAndPayClient.self] }
        set { self[SwapAndPayClient.self] = newValue }
    }
}

@DependencyClient
public struct SwapAndPayClient {
    public enum EndpointError: Equatable, Error {
        case message(String)
    }
    
    public enum Constants {
        /// Affiliate fee in basis points
        static public let zashiFeeBps = 50
        /// Address for the affiliate fees
        static let affiliateFeeDepositAddress = "zodlswaps.near"
        /// Address for the affiliate fees for CrossPay
        static let affiliateCrossPayFeeDepositAddress = "crosspay.near"
    }
    
    public let submitDepositTxId: (String, String) async throws -> Void
    public let swapAssets: () async throws -> IdentifiedArrayOf<SwapAsset>
    public let quote: (Bool, Bool, Bool, Int, SwapAsset, SwapAsset, String, String, String) async throws -> SwapQuote
    public let status: (String, Bool) async throws -> SwapDetails
}
