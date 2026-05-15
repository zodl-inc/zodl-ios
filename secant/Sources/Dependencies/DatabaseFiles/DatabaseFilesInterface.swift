//
//  DatabaseFilesInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var databaseFiles: DatabaseFilesClient {
        get { self[DatabaseFilesClient.self] }
        set { self[DatabaseFilesClient.self] = newValue }
    }
}

@DependencyClient
struct DatabaseFilesClient {
    var documentsDirectory: @Sendable () -> URL = { .emptyURL }
    var fsBlockDbRootFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var cacheDbURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var dataDbURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var outputParamsURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var pendingDbURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var spendParamsURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var toDirURLFor: @Sendable (ZcashNetwork) -> URL = { _ in .emptyURL }
    var areDbFilesPresentFor: @Sendable (ZcashNetwork) -> Bool = { _ in false }
}
