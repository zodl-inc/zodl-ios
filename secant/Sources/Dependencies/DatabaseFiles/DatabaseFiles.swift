//
//  DatabaseFiles.swift
//  Zashi
//
//  Created by Lukáš Korba on 05.04.2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit

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
