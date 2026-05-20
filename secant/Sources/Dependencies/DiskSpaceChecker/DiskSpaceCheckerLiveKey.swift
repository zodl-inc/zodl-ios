//
//  DiskSpaceCheckerLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 10.11.2022.
//

import ComposableArchitecture

extension DiskSpaceCheckerClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            freeSpaceRequiredForSync: { DiskSpaceChecker.freeSpaceRequiredForSync() },
            hasEnoughFreeSpaceForSync: { DiskSpaceChecker.hasEnoughFreeSpaceForSync() },
            freeSpace: { DiskSpaceChecker.freeSpace() }
        )
    }
}
