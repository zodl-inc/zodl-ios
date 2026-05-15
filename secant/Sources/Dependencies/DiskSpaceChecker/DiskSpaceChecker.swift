//
//  DiskSpaceChecker.swift
//  Zashi
//
//  Created by Michal Fousek on 28.09.2022.
//

import Foundation

enum DiskSpaceChecker {
    /// Free space on disk in bytes required to do sync
    static func freeSpaceRequiredForSync() -> Int64 {
        1 * 1024 * 1024 * 1024 // 1GB converted to bytes
    }

    static func hasEnoughFreeSpaceForSync() -> Bool {
        freeSpace() > freeSpaceRequiredForSync()
    }

    static func freeSpace() -> Int64 {
        do {
            let fileURL = URL(fileURLWithPath: NSHomeDirectory())
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            // If there is error getting information about free space from filesystem let's assume something is seriously wrong.
            return 0
        }
    }
}
