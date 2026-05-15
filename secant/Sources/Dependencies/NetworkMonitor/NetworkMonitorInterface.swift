//
//  NetworkMonitorInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-07-2025.
//

import ComposableArchitecture
@preconcurrency import Combine

extension DependencyValues {
    var networkMonitor: NetworkMonitorClient {
        get { self[NetworkMonitorClient.self] }
        set { self[NetworkMonitorClient.self] = newValue }
    }
}

@DependencyClient
struct NetworkMonitorClient {
    var networkMonitorStream: @Sendable () -> AnyPublisher<Bool, Never> = { Empty().eraseToAnyPublisher() }
}
