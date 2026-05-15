//
//  SyncProgressTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 21.12.2023.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

@MainActor
final class SyncProgressTests: XCTestCase {
    func testSyncingData() async throws {
        let store = TestStore(
            initialState: SyncProgress.State(
                lastKnownSyncPercentage: 0.0,
                synchronizerStatusSnapshot: .snapshotFor(state: .syncing(0.513, 0))
            )
        ) {
            SyncProgress()
        }
        
        XCTAssertTrue(store.state.isSyncing)
        XCTAssertEqual(store.state.syncingPercentage, 0.513 * 0.999)
    }
    
    func testlastKnownSyncingPercentage_Zero() async throws {
        let store = TestStore(
            initialState: SyncProgress.State(
                lastKnownSyncPercentage: 0.0,
                synchronizerStatusSnapshot: .placeholder
            )
        ) {
            SyncProgress()
        }

        XCTAssertEqual(store.state.lastKnownSyncPercentage, 0)
        XCTAssertEqual(store.state.syncingPercentage, 0)
    }
    
    func testlastKnownSyncingPercentage_MoreThanZero() async throws {
        let store = TestStore(
            initialState: SyncProgress.State(
                lastKnownSyncPercentage: 0.15,
                synchronizerStatusSnapshot: .placeholder
            )
        ) {
            SyncProgress()
        }

        XCTAssertEqual(store.state.lastKnownSyncPercentage, 0.15)
        XCTAssertEqual(store.state.syncingPercentage, 0.15)
    }
    
    func testlastKnownSyncingPercentage_FromSyncedState() async throws {
        let store = TestStore(
            initialState: SyncProgress.State(
                lastKnownSyncPercentage: 0.15,
                synchronizerStatusSnapshot: .snapshotFor(state: .syncing(0.513, 0))
            )
        ) {
            SyncProgress()
        }

        var syncState: SynchronizerState = .zero
        syncState.syncStatus = .upToDate
        let snapshot = SyncStatusSnapshot.snapshotFor(state: syncState.syncStatus)
        
        await store.send(.synchronizerStateChanged(syncState.redacted)) { state in
            state.synchronizerStatusSnapshot = snapshot
            state.syncStatusMessage = String(localizable: .balancesSynced)
            state.lastKnownSyncPercentage = 1.0
        }
    }
    
    func testlastKnownSyncingPercentage_FromSyncingState() async throws {
        let store = TestStore(
            initialState: SyncProgress.State(
                lastKnownSyncPercentage: 0.15,
                synchronizerStatusSnapshot: .snapshotFor(state: .syncing(0.513, 0))
            )
        ) {
            SyncProgress()
        }

        var syncState: SynchronizerState = .zero
        syncState.syncStatus = .syncing(0.545, 0)
        let snapshot = SyncStatusSnapshot.snapshotFor(state: syncState.syncStatus)
        
        await store.send(.synchronizerStateChanged(syncState.redacted)) { state in
            state.synchronizerStatusSnapshot = snapshot
            state.syncStatusMessage = String(localizable: .balancesSyncing)
            state.lastKnownSyncPercentage = 0.545
        }
    }
}
