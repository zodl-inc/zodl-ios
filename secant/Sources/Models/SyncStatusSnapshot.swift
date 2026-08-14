//
//  SyncStatusSnapshot.swift
//  Zashi
//
//  Created by Lukáš Korba on 07.07.2022.
//

import Foundation
@preconcurrency import ZcashLightClientKit

struct SyncStatusSnapshot: Equatable {
    let message: String
    let syncStatus: SyncStatus
    
    init(_ syncStatus: SyncStatus = .unprepared, _ message: String = "") {
        self.message = message
        self.syncStatus = syncStatus
    }
    
    static func snapshotFor(state: SyncStatus) -> SyncStatusSnapshot {
        switch state {
        case .upToDate:
            return SyncStatusSnapshot(state, String(localizable: .syncMessageUptodate))
            
        case .unprepared:
            return SyncStatusSnapshot(state, String(localizable: .syncMessageUnprepared))
            
        case .error(let error):
            let zcashError = error.toZcashError()
            // A server-validation failure gets a written explanation naming the server and the
            // consensus branch IDs, used verbatim: it reads as prose, so it takes neither the
            // "Error: " prefix nor the SDK's raw dump. Every other error keeps the existing format.
            if let message = zcashError.incompatibleServerMessage {
                return SyncStatusSnapshot(state, message)
            }
            return SyncStatusSnapshot(state, String(localizable: .syncMessageError(zcashError.detailedMessage)))

        case .stopped:
            return SyncStatusSnapshot(state, String(localizable: .syncMessageStopped))

        case let .syncing(syncProgress, _):
            return SyncStatusSnapshot(state, String(localizable: .syncMessageSync(String(format: "%0.1f", syncProgress * 100))))
        }
    }
}

extension SyncStatusSnapshot {
    static let initial = SyncStatusSnapshot()
    
    static let placeholder = SyncStatusSnapshot(.unprepared, "23% synced")
}
