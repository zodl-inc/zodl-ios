//
//  FlexaHandlerInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-09-2024
//

import Foundation
import ComposableArchitecture
@preconcurrency import Combine
import Flexa
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var flexaHandler: FlexaHandlerClient {
        get { self[FlexaHandlerClient.self] }
        set { self[FlexaHandlerClient.self] = newValue }
    }
}

@DependencyClient
struct FlexaHandlerClient {
    var prepare: @Sendable () -> Void
    var open: @Sendable () -> Void
    var onTransactionRequest: @Sendable () -> AnyPublisher<FlexaTransaction?, Never> = { Just(nil).eraseToAnyPublisher() }
    var clearTransactionRequest: @Sendable () -> Void
    var transactionSent: @Sendable (String, String) -> Void
    var updateBalance: @Sendable (Zatoshi, Zatoshi?) -> Void
    var flexaAlert: @Sendable (String, String) -> Void
    var signOut: @Sendable () -> Void
}
