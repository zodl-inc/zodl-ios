//
//  SyncStatusSnapshotTests.swift
//  zodlTests
//
//  Extended — pure logic. Covers SyncStatusSnapshot.snapshotFor message mapping
//  (Models/SyncStatusSnapshot.swift).
//

import Testing
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct SyncStatusSnapshotTests {
    @Test func snapshotProducesNonEmptyMessageForEachState() {
        #expect(!SyncStatusSnapshot.snapshotFor(state: .upToDate).message.isEmpty)
        #expect(!SyncStatusSnapshot.snapshotFor(state: .unprepared).message.isEmpty)
        #expect(!SyncStatusSnapshot.snapshotFor(state: .stopped).message.isEmpty)
    }

    @Test func snapshotPreservesSyncStatusForUpToDate() {
        #expect(SyncStatusSnapshot.snapshotFor(state: .upToDate).syncStatus == .upToDate)
    }
}
