//
//  DatabaseFilesLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 11.11.2022.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DatabaseFilesClient: DependencyKey {
    static let liveValue = DatabaseFilesClient.live()
        
    static func live(databaseFiles: DatabaseFiles = DatabaseFiles(fileManager: .live)) -> Self {
        Self(
            documentsDirectory: {
                databaseFiles.documentsDirectory()
            },
            fsBlockDbRootFor: { network in
                databaseFiles.documentsDirectory()
                    .appendingPathComponent(network.networkType.chainName)
                    .appendingPathComponent(ZcashSDK.defaultFsCacheName, isDirectory: true)
            },
            cacheDbURLFor: { network in
                databaseFiles.cacheDbURL(for: network)
            },
            dataDbURLFor: { network in
                databaseFiles.dataDbURL(for: network)
            },
            outputParamsURLFor: { network in
                databaseFiles.outputParamsURL(for: network)
            },
            pendingDbURLFor: { network in
                databaseFiles.pendingDbURL(for: network)
            },
            spendParamsURLFor: { network in
                databaseFiles.spendParamsURL(for: network)
            },
            toDirURLFor: { network in
                databaseFiles.toDirURL(for: network)
            },
            areDbFilesPresentFor: { network in
                databaseFiles.areDbFilesPresent(for: network)
            }
        )
    }
}
