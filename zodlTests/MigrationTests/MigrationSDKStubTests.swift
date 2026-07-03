//
//  MigrationSDKStubTests.swift
//  zodlTests
//
//  Covers the inert "does nothing yet" contract of the stubbed migration members on
//  SDKSynchronizerClient (Dependencies/SDKSynchronizer/SDKSynchronizerInterface.swift). No
//  shared/global state -> no `.serialized`.
//
//  Deliberately NOT testing `liveValue`/`live()` — constructing the live client builds the
//  real synchronizer stack; unit tests never touch `liveValue` (TCA convention). The stub's
//  "never calls the SDK" property is enforced by review + the fact the SDK API doesn't exist
//  to call.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct MigrationSDKStubTests {
    @Test func noOpMigrationEndpointsAreInert() async {
        let client = SDKSynchronizerClient.noOp

        #expect(client.getMigrationState() == .notStarted)
        #expect(client.isNoteSplitNeeded() == false)
        #expect(client.hasOverdueMigrationTransfers() == false)
        #expect(client.hasInvalidMigrationTransfers() == false)
        #expect(client.getMigrationProgress() == nil)

        let executedTransfer = await client.executeNextPendingMigrationTransfer(
            NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        )
        #expect(executedTransfer == nil)

        let schedule = await client.proposeMigrationTransfers()
        #expect(schedule.transfers.isEmpty)

        #expect(client.migrationSummary() == MigrationSummary.zero)
        #expect(client.migrationTransfers().isEmpty)

        let pczts = await client.proposeMigrationPCZTs(
            MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        )
        #expect(pczts.isEmpty)
    }

    @Test func mockedMigrationEndpointsAreInert() async {
        // `mocked()` is the construction previews/tests reach for — its migration endpoints
        // must stay inert until the real SDK API exists. (A bare `SDKSynchronizerClient()` is
        // not constructible: the macro's memberwise init requires the non-defaulted `let`
        // members, so the interface defaults are not independently instantiable.)
        let client = SDKSynchronizerClient.mocked()

        #expect(client.getMigrationState() == .notStarted)
        #expect(client.isNoteSplitNeeded() == false)

        let executedTransfer = await client.executeNextPendingMigrationTransfer(
            NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        )
        #expect(executedTransfer == nil)
    }
}
