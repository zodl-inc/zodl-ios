//
//  MigrationSDKStubTests.swift
//  zodlTests
//
//  MOB-1469: `live()`'s software-path migration members are now backed by `LiveMigrationEngine`
//  (see `LiveMigrationEngineTests.swift`), so this suite no longer pins "every migration member is
//  an inert stub" — most aren't, once `.live()` is used. What's still true everywhere, including
//  `.live()`, is the 6 Keystone/PCZT members (`proposeNoteSplitPCZT`, `proposeMigrationPCZTs`,
//  `storeSignedMigrationTransactions`, `submitSignedNoteSplit`, `urEncoderForMigrationPCZTBatch`,
//  `parseMigrationPCZTBatch`): they remain inert stubs pending a later phase's Keystone rewiring.
//  This suite covers that inert contract on `SDKSynchronizerClient.noOp` and `.mocked()` — the
//  hardcoded defaults every non-`.live()` construction gets — plus the handful of non-Keystone
//  getters that happen to share the same "does nothing" defaults on those two constructions. No
//  shared/global state -> no `.serialized`.
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

        // MOB-1468: Keystone batch-signing stubs.
        let noteSplitResult = await client.submitSignedNoteSplit(Pczt())
        #expect(noteSplitResult == TransferResult.success(txId: ""))
        #expect(client.urEncoderForMigrationPCZTBatch([Pczt()]) == nil)
        #expect(client.parseMigrationPCZTBatch(Data()) == nil)
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

        // MOB-1468: Keystone batch-signing stubs.
        let noteSplitResult = await client.submitSignedNoteSplit(Pczt())
        #expect(noteSplitResult == TransferResult.success(txId: ""))
        #expect(client.urEncoderForMigrationPCZTBatch([Pczt()]) == nil)
        #expect(client.parseMigrationPCZTBatch(Data()) == nil)
    }
}
