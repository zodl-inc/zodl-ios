//
//  MigrationSDKLiveKey.swift
//  zodl
//
//  Production registration of `MigrationSDKClient`. For the prototype `liveValue` is backed by the
//  `DummyMigrationEngine`. Swapping in the real SDK = replace the closures below.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationSDKClient: DependencyKey {
    static let liveValue: MigrationSDKClient = Self.live()

    static func live(
        store: MigrationStateStore = .live(fileURL: MigrationStateStore.defaultFileURL)
    ) -> MigrationSDKClient {
        let engine = DummyMigrationEngine(store: store)

        return MigrationSDKClient(
            getMigrationState: { engine.currentState() },
            stateStream: { engine.statePublisher() },
            getMigrationProgress: { engine.progress() },
            isNoteSplitNeeded: { engine.noteSplitNeeded() },
            prepareNoteSplit: { await engine.prepareSplit() },
            submitNoteSplit: { await engine.submitSplit($0) },
            proposeMigrationTransfers: { await engine.propose() },
            signAndStoreMigrationSchedule: { await engine.signAndStore($0) },
            isSyncRequiredBeforeNextTransfer: { engine.syncRequiredBeforeNext() },
            executeNextPendingTransfer: { await engine.executeNext($0) },
            hasOverdueTransfers: { engine.overdue() },
            hasInvalidTransfers: { engine.invalid() },
            restartCurrentMigrationStep: { await engine.restart() },
            rescheduleStalledTransfer: { await engine.rescheduleStalled() },
            recreateInvalidTransfer: { await engine.recreateInvalid() },
            initializePostUpgrade: { engine.initializePostUpgrade() },
            selectMigrationMode: { engine.selectMode($0) },
            simulatedOrchardBalance: { engine.orchardBalance() },
            migrationSummary: { engine.summary() },
            migrationTransfers: { engine.transferRows() },
            debug: MigrationDebugControls(
                reset: { await engine.debugReset() },
                seed: { await engine.debugSeed(orchard: $0, noteCount: $1) },
                advanceHeight: { await engine.debugAdvanceHeight($0) },
                confirmSplitNow: { await engine.debugConfirmSplit() },
                armNextTransferResult: { await engine.debugArm($0) },
                jumpTo: { await engine.debugJump($0) },
                snapshotDescription: { engine.debugSnapshotDescription() }
            )
        )
    }
}
