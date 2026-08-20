//
//  ShieldingProcessorInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-04-17.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import Combine

extension DependencyValues {
    var shieldingProcessor: ShieldingProcessorClient {
        get { self[ShieldingProcessorClient.self] }
        set { self[ShieldingProcessorClient.self] = newValue }
    }
}

@DependencyClient
struct ShieldingProcessorClient {
    enum State: Equatable {
        case failed(ZcashError)
        case grpc
        /// The SDK had nothing shieldable to propose (`proposeShielding` returned a nil proposal):
        /// the transparent balance the caller acted on is already spent or below the shielding
        /// threshold. A distinct state from `.failed` because nothing went wrong — surfacing it as
        /// a `ZcashError` is what produced the raw `ZUNKWN0001` alert in MOB-1755.
        case nothingToShield
        case proposal(Proposal)
        case requested
        case succeeded
        case unknown
    }
    
    var observe: @Sendable () -> AnyPublisher<ShieldingProcessorClient.State, Never> = { Empty().eraseToAnyPublisher() }
    var shieldFunds: @Sendable () -> Void
}
