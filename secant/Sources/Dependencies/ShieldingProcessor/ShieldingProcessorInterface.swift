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
        case proposal(Proposal)
        case requested
        case succeeded
        case unknown
    }
    
    var observe: @Sendable () -> AnyPublisher<ShieldingProcessorClient.State, Never> = { Empty().eraseToAnyPublisher() }
    var shieldFunds: @Sendable () -> Void
}
