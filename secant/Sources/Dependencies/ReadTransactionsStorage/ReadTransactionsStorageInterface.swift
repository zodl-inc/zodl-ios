//
//  ReadTransactionsStorageInterface.swift
//  
//
//  Created by Lukáš Korba on 11.11.2023.
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var readTransactionsStorage: ReadTransactionsStorageClient {
        get { self[ReadTransactionsStorageClient.self] }
        set { self[ReadTransactionsStorageClient.self] = newValue }
    }
}

@DependencyClient
struct ReadTransactionsStorageClient {
    enum Constants {
        static let entityName = "ReadTransactionsStorageEntity"
        static let modelName = "ReadTransactionsStorageModel"
        static let availabilityEntityName = "ReadTransactionsStorageAvailabilityTimestampEntity"
    }
    
    enum ReadTransactionsStorageError: Error {
        case createEntity
        case availability
    }
    
    var markIdAsRead: @Sendable (RedactableString) throws -> Void
    var readIds: @Sendable () throws -> [RedactableString: Bool]
    var availabilityTimestamp: @Sendable () throws -> TimeInterval
    var resetZashi: @Sendable () throws -> Void
}
