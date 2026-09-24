//
//  DatabaseFiles.swift
//  Zashi
//
//  Created by Lukáš Korba on 05.04.2022.
//

import Foundation
@preconcurrency import ZODLSwiftWalletSDK

/// Resolves the on-disk locations of the SDK wallet database files — `data.db` (with its
/// SQLite sidecars), `cache.db`, `pending.db`, the sapling params and `to-dir` — all kept
/// in the app's Documents directory.
///
/// These files are intentionally left eligible for system backups: we deliberately do
/// **not** set `isExcludedFromBackup` on them, even though a security report flagged that
/// wallet data then flows into iCloud/iTunes backups and device-migration transfers.
///
/// This is a conscious trade-off between security and UX. Some of this data lives *only*
/// in these local files; it is not stored on any server or backend. Excluding the files
/// from backups would therefore make the user permanently lose that information when
/// migrating to a new device, so keeping them in backups is exactly what lets that data
/// survive a device change. Do not add `isExcludedFromBackup` here without revisiting this
/// decision.
struct DatabaseFiles {
    enum DatabaseFilesError: Error {
        case getFsBlockDbRoot
        case getDocumentsURL
        case getCacheURL
        case getDataURL
        case getOutputParamsURL
        case getPendingURL
        case getSpendParamsURL
        case nukeFiles
        case filesPresentCheck
    }
    
    private let fileManager: FileManagerClient
    
    init(fileManager: FileManagerClient) {
        self.fileManager = fileManager
    }
    
    func documentsDirectory() -> URL {
        do {
            return try fileManager.url(.documentDirectory, .userDomainMask, nil, true)
        } catch {
            // This is not super clean but this is second best thing when the above call fails.
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        }
    }

    func cacheDbURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)cache.db",
                isDirectory: false
            )
    }

    func dataDbURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)data.db",
                isDirectory: false
                )
    }

    func outputParamsURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)sapling-output.params",
                isDirectory: false
            )
    }

    func pendingDbURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)pending.db",
                isDirectory: false
            )
    }

    func spendParamsURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)sapling-spend.params",
                isDirectory: false
            )
    }
    
    func toDirURL(for network: ZcashNetwork) -> URL {
        return documentsDirectory()
            .appendingPathComponent(
                "\(network.constants.defaultDbNamePrefix)to-dir",
                isDirectory: false
            )
    }

    func areDbFilesPresent(for network: ZcashNetwork) -> Bool {
        let dataDbURL = dataDbURL(for: network)
        return fileManager.fileExists(dataDbURL.path)
    }
}
