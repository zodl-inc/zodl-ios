//
//  LogsHandlerInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.01.2023.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var logsHandler: LogsHandlerClient {
        get { self[LogsHandlerClient.self] }
        set { self[LogsHandlerClient.self] = newValue }
    }
}

@DependencyClient
struct LogsHandlerClient {
    var exportAndStoreLogs: @Sendable (String, String, String) async throws -> URL?
}
