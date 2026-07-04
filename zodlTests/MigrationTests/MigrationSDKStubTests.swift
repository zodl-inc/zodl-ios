//
//  MigrationSDKStubTests.swift
//  zodlTests
//
//  MOB-1469: `live()`'s migration members — the software path AND the 4 Keystone/PCZT members —
//  are backed by `LiveMigrationEngine` (see `LiveMigrationEngineTests.swift`), so this suite no
//  longer pins "every migration member is an inert stub" — none are, once `.live()` is used. This
//  suite covers the inert contract on `SDKSynchronizerClient.noOp` and `.mocked()` — the hardcoded
//  defaults every non-`.live()` construction gets — plus the handful of getters that happen to
//  share the same "does nothing" defaults on those two constructions. No shared/global state -> no
//  `.serialized`.
//
//  Deliberately NOT testing `liveValue`/`live()` — constructing the live client builds the real
//  synchronizer stack; unit tests never touch `liveValue` (TCA convention). `.noOp`/`.mocked()`
//  are separate, hardcoded closures (SDKSynchronizerTest.swift) untouched by `.live()`'s wiring.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
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

        // MOB-1468/1469: Keystone (PCZT) members' inert defaults.
        let noteSplitResult = await client.submitSignedNoteSplit(Pczt())
        #expect(noteSplitResult == TransferResult.success(txId: ""))
        let noteSplitPczt = await client.proposeNoteSplitPCZT()
        #expect(noteSplitPczt.isEmpty)
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

        // MOB-1468/1469: Keystone (PCZT) members' inert defaults.
        let noteSplitResult = await client.submitSignedNoteSplit(Pczt())
        #expect(noteSplitResult == TransferResult.success(txId: ""))
    }
}
