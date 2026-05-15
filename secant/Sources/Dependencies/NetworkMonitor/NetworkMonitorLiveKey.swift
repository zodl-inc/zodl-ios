//
//  NetworkMonitorLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-07-2025.
//

import Foundation
import Network
@preconcurrency import Combine
import ComposableArchitecture

extension NetworkMonitorClient: DependencyKey {
    static let liveValue: NetworkMonitorClient = Self.live()
    
    static func live() -> Self {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue.global(qos: .background)
        let subject = CurrentValueSubject<Bool, Never>(true)

        return NetworkMonitorClient(
            networkMonitorStream: {
                monitor.pathUpdateHandler = { subject.send($0.status == .satisfied) }
                monitor.start(queue: queue)

                return subject.eraseToAnyPublisher()
            }
        )
    }
}
