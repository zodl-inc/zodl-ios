//
//  RemoteStorageInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-27-2024.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var remoteStorage: RemoteStorageClient {
        get { self[RemoteStorageClient.self] }
        set { self[RemoteStorageClient.self] = newValue }
    }
}

@DependencyClient
struct RemoteStorageClient {
    var loadDataFromFile: @Sendable (String) throws -> Data
    var storeDataToFile: @Sendable (Data, String) throws -> Void
    var removeFile: @Sendable (String) throws -> Void
}
