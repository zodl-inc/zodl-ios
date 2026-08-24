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
        case nothingToShield
        case proposal(Proposal)
        case requested
        case succeeded
        case unknown
    }

    /// The single home of the shielding-eligibility rule, shared by the smart banner and the
    /// Balances sheet so the two can never disagree about the same wallet. Inclusive on purpose:
    /// the SDK's `proposeShielding` returns nil only when the balance "is zero or below
    /// `shieldingThreshold`", so a balance exactly at the threshold shields.
    static func isShieldable(balance: Zatoshi, threshold: Zatoshi) -> Bool {
        balance >= threshold
    }

    var observe: @Sendable () -> AnyPublisher<ShieldingProcessorClient.State, Never> = { Empty().eraseToAnyPublisher() }
    var shieldFunds: @Sendable () -> Void
}
