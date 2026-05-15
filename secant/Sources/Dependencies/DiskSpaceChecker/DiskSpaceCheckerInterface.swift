//
//  DiskSpaceCheckerInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 10.11.2022.
//

import ComposableArchitecture

extension DependencyValues {
    var diskSpaceChecker: DiskSpaceCheckerClient {
        get { self[DiskSpaceCheckerClient.self] }
        set { self[DiskSpaceCheckerClient.self] = newValue }
    }
}

@DependencyClient
struct DiskSpaceCheckerClient {
    var freeSpaceRequiredForSync: @Sendable () -> Int64 = { 0 }
    var hasEnoughFreeSpaceForSync: @Sendable () -> Bool = { false }
    var freeSpace: @Sendable () -> Int64 = { 0 }
}
