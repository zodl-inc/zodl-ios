//
//  MigrationCoordFlowTests.swift
//  zodlTests
//
//  Covers `MigrationCoordFlow` (Features/CoordFlows/MigrationCoordFlow{Store,Coordinator}.swift)
//  for MOB-1466: re-entry routing (`.onAppear`), the chaining table from Entry through Complete
//  for all three modes (immediate/scheduled/manual), the permission-step helper's skip logic,
//  sendNow/reschedule/recovery orchestration, and every flow-root close path's `.flowFinished`
//  emission. Also covers MOB-1468's Keystone signing round-trip: each of the two remaining signing
//  sources' `.keystoneSignRequested` delegate sets `pendingKeystoneSigning` and pushes
//  `keystoneSign`; `keystoneSign(.delegate(.getSignature))` pushes `scan` configured with the
//  migration batch checker; `scan(.foundPCZTBatch)` stores the signed PCZTs, pops `scan`+
//  `keystoneSign`, and resumes the matching chain (plan post-confirm / immediate sending) — verified
//  with order-asserting spies; `.rejected` pops back to the signing source with its state intact and
//  clears the context; the no-partial-storage invariant (reject, or an empty scanned batch, never
//  calls store).
//
//  MOB-1478 reshapes the scheduled entry chain and adds the Tor bottom sheet:
//  - W2/W3: Entry (immediate) and How This Works (scheduled) both gate on the same
//    `walletStorage.exportTorSetupFlag()` check the old Network Privacy screen used, before either
//    pushing straight through (flag set) or presenting the coordinator-owned Tor sheet (flag unset)
//    and stashing the pending destination; "Got it" and swipe-dismissal (`torSheetPresentationChanged
//    (false)`) both persist + resume identically.
//  - W4: note splitting no longer gates or appears in forward routing at all — `MigrationNoteSplit`
//    is re-entry-only, and its old Keystone signing context folded into `TransferPlan`'s batch (a
//    signed-PCZT array can now be longer when the split was needed, but the coordinator still treats
//    it as one opaque atomic batch either way).
//  - W7: reschedule lands `.rescheduleCompleted` on the SAME status element instead of pushing a
//    fresh `TransferPlan`.
//  - W8: the Notifications variant now reaches `.manual` when delivery is manual (was previously
//    unreachable).
//  - W10: the Keystone scan push sets `instructions`/`forceLibraryToHide`.
//
//  `.serialized`: every `MigrationCoordFlow.State()` carries a `MigrationEntry.State` (`entryState`),
//  which reads the process-global `@Shared(.inMemory(.selectedWalletAccount))` on init — matching the
//  precedent in `MigrationEntryTests`, which mutates the same key directly.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationCoordFlowTests {
    // MARK: - Re-entry: .onAppear with empty path

    @MainActor @Test func onAppearWithEntryRouteAppendsNothing() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .entry }
        }

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.path.isEmpty)
    }

    @MainActor @Test func onAppearWithStatusProgressRouteAppendsFlowRootStatusScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 0,
            transfersTotal: 1,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusProgress }
            $0.migrationManager.sendGate = { .allowed }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
            $0.sdkSynchronizer.migrationSummary = { summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status as the only path element")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.progress)
        #expect(statusState.isFlowRoot == true)
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: rows))
        #expect(statusState.totalDurationHours == 24)
    }

    @MainActor @Test func onAppearWithRecoveryNotExpiredRouteAppendsFlowRootRecoveryScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .invalid, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(1_000), status: .invalid, hoursFromNow: 0)
        ]
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .recovery(isExpired: false) }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .recovery(recoveryState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery on the path")
            return
        }
        #expect(recoveryState.reason == MigrationRecovery.State.Reason.notesSpent)
        #expect(recoveryState.isFlowRoot == true)
        #expect(recoveryState.firstTransfer == 2)
        #expect(recoveryState.lastTransfer == 3)
    }

    @MainActor @Test func onAppearWithRecoveryExpiredRouteAppendsFlowRootRecoveryScreenWithExpiredReason() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .recovery(isExpired: true) }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { [] }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .recovery(recoveryState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery on the path")
            return
        }
        #expect(recoveryState.reason == MigrationRecovery.State.Reason.expired)
        #expect(recoveryState.isFlowRoot == true)
    }

    @MainActor @Test func onAppearWithStatusResumeRouteAppendsFlowRootStatusScreenInResumePresentation() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusResume }
            $0.migrationManager.sendGate = { .syncRequired }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
            $0.sdkSynchronizer.migrationSummary = { summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status on the path")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.resume)
        #expect(statusState.isFlowRoot == true)
        #expect(statusState.stalledNumber == 2)
        #expect(statusState.stalledHoursAgo == 5)
        #expect(statusState.isSendNowDisabled == true)
    }

    @MainActor @Test func onAppearWithCompleteRouteAppendsFlowRootCompleteScreen() async {
        let summary = MigrationSummary(
            transferred: Zatoshi(1_245_800_000),
            dust: Zatoshi(31_000),
            transfersSent: 5,
            transfersTotal: 5,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .complete }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationSummary = { summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .complete(completeState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete on the path")
            return
        }
        #expect(completeState.isFlowRoot == true)
        #expect(completeState.totalTransferred == Zatoshi(1_245_800_000))
        #expect(completeState.dust == Zatoshi(31_000))
        #expect(completeState.transfersSent == 5)
        #expect(completeState.transfersTotal == 5)
        #expect(completeState.durationHours == 24)
    }

    @MainActor @Test func onAppearWithNoteSplitProgressRouteAppendsFlowRootSplittingScreen() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .noteSplitProgress }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit on the path")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.splitting)
        #expect(noteSplitState.isFlowRoot == true)
    }

    @MainActor @Test func onAppearWithReviewManualRouteAppendsFlowRootManualStepReviewScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .active, hoursFromNow: 0)
        ]
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .reviewManual(step: 2, total: 5) }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.manualStep(number: 2, total: 5))
        #expect(reviewState.isFlowRoot == true)
        #expect(reviewState.amount == Zatoshi(2_000))
        #expect(reviewState.fee == Zatoshi(100_000))
    }

    // MARK: - Immediate flow (§6.1): Tor sheet gate

    @MainActor @Test func entryChoseImmediateWithTorFlagOnSkipsTorSheetAndPushesReview() async {
        let setMigrationModeCalls = LockIsolated<[MigrationMode]>([])
        let selectMigrationModeCalls = LockIsolated<[MigrationMode]>([])
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { mode in setMigrationModeCalls.withValue { $0.append(mode) } }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.selectMigrationMode = { mode in selectMigrationModeCalls.withValue { $0.append(mode) } }
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))

        #expect(store.state.mode == MigrationMode.immediate)
        #expect(setMigrationModeCalls.value == [MigrationMode.immediate])
        #expect(selectMigrationModeCalls.value == [MigrationMode.immediate])
        #expect(store.state.networkPrivacyOptions.useTor == true)
        #expect(store.state.isTorSheetPresented == false)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path (Tor sheet skipped)")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
    }

    @MainActor @Test func entryChoseImmediateWithTorFlagOffPresentsTorSheetAndStashesReviewDestination() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.reviewTransfer)
        // Nothing pushed yet — the sheet gates the push until confirmed/dismissed.
        #expect(store.state.path.isEmpty)
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): "Got it" and swipe-dismiss resume the stashed destination

    @MainActor @Test func torSheetGotItInImmediateModePersistsOptionsAndPushesReviewTransfer() async {
        let setOptionsCalls = LockIsolated<[NetworkPrivacyOptions]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: true)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { options in setOptionsCalls.withValue { $0.append(options) } }
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))

        let expectedOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        #expect(setOptionsCalls.value == [expectedOptions])
        #expect(store.state.networkPrivacyOptions == expectedOptions)
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
    }

    @MainActor @Test func torSheetSwipeDismissInImmediateModePersistsOptionsAndPushesReviewTransfer() async {
        // Spec: sheet dismissal by swipe is identical to "Got it" — same persist-then-proceed logic,
        // using whatever toggle state is showing at that moment.
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.torSheetPresentationChanged(false))

        #expect(store.state.networkPrivacyOptions == NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        guard case .reviewTransfer = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top (swipe-dismiss == Got it)")
            return
        }
    }

    @MainActor @Test func torSheetGotItInScheduledModeResumesPermissionChainAndPushesTransferPlan() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.torSheetState = MigrationTorSheet.State(isTorOn: false)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .permissionChain
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
    }

    @MainActor @Test func torSheetPresentationChangedToFalseWithNothingPendingIsANoOp() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        }

        await store.send(.torSheetPresentationChanged(false))
    }

    @MainActor @Test func manualDeliveryFreshPlanUsesManualVariant() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { true }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed on top")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.manual)
    }

    @MainActor @Test func reviewTransferConfirmedPushesSending() async {
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.networkPrivacyOptions == NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))
    }

    // MARK: - MOB-1468: Keystone signing — signRequested sets context + pushes keystoneSign

    @MainActor @Test func transferPlanKeystoneSignRequestedSetsPlanCommitContextAndPushesKeystoneSign() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [Pczt] = [Data([0xAA]), Data([0xBB])]
        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.keystoneSignRequested(pczts))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.planCommit)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == pczts)
    }

    @MainActor @Test func reviewTransferKeystoneSignRequestedSetsImmediateReviewContextAndPushesKeystoneSign() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [Pczt] = [Data([0xCC])]
        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.keystoneSignRequested(pczts))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == pczts)
    }

    // MARK: - MOB-1468/1478 (W10): Keystone signing — getSignature pushes scan configured for migration

    @MainActor @Test func keystoneSignGetSignaturePushesScanConfiguredWithMigrationBatchCheckerAndScanConfig() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [Pczt()])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.getSignature)))))

        guard case let .scan(scanState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scan pushed on top")
            return
        }
        #expect(scanState.checkers == [.keystoneMigrationBatchScanChecker])
        #expect(scanState.instructions == String(localizable: .migrationKeystoneScanInstructions))
        #expect(scanState.forceLibraryToHide == true)
    }

    // MARK: - MOB-1468: Keystone signing — foundPCZTBatch resumes planCommit (shared post-confirm chain)

    @MainActor @Test func foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant() async {
        let callOrder = LockIsolated<[String]>([])
        let signed: [Pczt] = [Data([0xAA]), Data([0xBB])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: signed)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in
                #expect(stored == signed)
                callOrder.withValue { $0.append("store") }
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(callOrder.value == ["store", "scheduleFirstWindow"])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed on top of the retained .transferPlan element")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (never re-signs again)")
            return
        }
    }

    // MOB-1478 (W4): TransferPlan's Keystone fork prepends the note-split PCZT when needed — the
    // coordinator treats the resulting (longer) batch opaquely and stores the WHOLE array atomically,
    // no per-element handling required.
    @MainActor @Test func foundPCZTBatchForPlanCommitContextWithNoteSplitPrefixStoresWholeBatchAtomically() async {
        let callOrder = LockIsolated<[String]>([])
        let splitPczt: Pczt = Data([0x01])
        let signed: [Pczt] = [splitPczt, Data([0xAA]), Data([0xBB])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: signed)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in
                #expect(stored == signed)
                callOrder.withValue { $0.append("store") }
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(callOrder.value == ["store", "scheduleFirstWindow"])
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
    }

    @MainActor @Test func foundPCZTBatchForPlanCommitContextPushesSendingForManualVariant() async {
        let signed: [Pczt] = [Data([0xCC])]
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .manual)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: signed)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top for the manual variant")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.networkPrivacyOptions == NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))
    }

    // MARK: - MOB-1468: Keystone signing — foundPCZTBatch resumes immediateReview

    @MainActor @Test func foundPCZTBatchForImmediateReviewContextStoresPopsAndPushesSending() async {
        let storeCalls = LockIsolated<[[Pczt]]>([])
        let signed: [Pczt] = [Data([0xDD])]
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: signed)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in storeCalls.withValue { $0.append(stored) } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [signed])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom")
            return
        }
    }

    // MARK: - MOB-1468: Keystone signing — empty batch never stores (no-partial-storage)

    @MainActor @Test func foundPCZTBatchWithEmptyArrayForPlanCommitContextAbandonsSessionWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [Pczt()])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch([])))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        // Deferred pop of scan + sign back to the plan, context cleared — the user re-initiates
        // signing from the confirm button (no-partial-storage invariant: nothing was stored).
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    // MARK: - MOB-1468: Keystone signing — rejected pops back with state intact, context cleared

    @MainActor @Test func keystoneSignRejectedPopsBackToUnsignedTransferPlanConfirmingScreenUntouched() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [Pczt(), Pczt()])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .transferPlan remaining on top, unsigned")
            return
        }
    }

    @MainActor @Test func keystoneSignRejectedNeverCallsStore() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [Pczt()])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(storeCalls.value == 0)
    }

    @MainActor @Test func sendingClosedInImmediateModeAcknowledgesCompleteAndFinishesFlow() async {
        let acknowledgeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.path.append(.sending(MigrationSending.State(phase: .success)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.acknowledgeComplete = { acknowledgeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .sending(.delegate(.closed)))))
        await store.receive(\.flowFinished)

        #expect(acknowledgeCalls.value == 1)
    }

    // MARK: - Scheduled flow (§6.2, MOB-1478 W3): Entry always pushes How This Works

    @MainActor @Test func entryChoseScheduledAlwaysPushesHowItWorksRegardlessOfNoteSplitNeed() async {
        // Note splitting no longer gates (or appears in) forward routing at all — it runs silently
        // under the commit CTAs (W4). `isNoteSplitNeeded` is stubbed `true` here specifically to
        // prove Entry doesn't even look at it any more.
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.privateScheduled))))

        #expect(store.state.mode == MigrationMode.privateScheduled)
        guard case .howItWorks = try? #require(store.state.path.last) else {
            Issue.record("Expected .howItWorks pushed")
            return
        }
    }

    // MARK: - HowItWorks (MOB-1478 W3) -> Tor sheet gate (W2) -> permission steps

    @MainActor @Test func howItWorksContinuedWithTorFlagOnSkipsTorSheetAndGoesStraightToPermissionSteps() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.networkPrivacyOptions.useTor == true)
        #expect(store.state.isTorSheetPresented == false)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (Tor sheet + all permission steps skipped)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
    }

    @MainActor @Test func howItWorksContinuedWithTorFlagOffPresentsTorSheetAndStashesPermissionChainDestination() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.permissionChain)
        // How This Works stays on top — nothing pushed yet, the sheet gates the push.
        guard case .howItWorks = try? #require(store.state.path.last) else {
            Issue.record("Expected .howItWorks still on top")
            return
        }
    }

    // MARK: - Scheduled flow (§6.2): permission-step skip combinations

    @MainActor @Test func backgroundDeliveryDeclinedSetsManualDeliveryAndContinuesToNotifications() async {
        let setManualDeliveryCalls = LockIsolated<[Bool]>([])
        var state = MigrationCoordFlow.State()
        state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setManualDelivery = { allowed in setManualDeliveryCalls.withValue { $0.append(allowed) } }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .notDetermined }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .backgroundDelivery(.delegate(.continued(backgroundAllowed: false))))))
        await store.receive(\.pushNextPermissionStep)

        #expect(setManualDeliveryCalls.value == [true])
        guard case .notifications = try? #require(store.state.path.last) else {
            Issue.record("Expected .notifications pushed (authorization not determined)")
            return
        }
    }

    // MOB-1478 (W8): mirrors `freshPlanVariant()`'s ternary — today `.manual` was unreachable since
    // this always defaulted to `.scheduled`.
    @MainActor @Test func notificationsVariantIsManualWhenManualDeliveryIsSet() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setManualDelivery = { _ in }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .notDetermined }
            $0.migrationManager.isManualDelivery = { true }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .backgroundDelivery(.delegate(.continued(backgroundAllowed: false))))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .notifications(notificationsState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .notifications pushed")
            return
        }
        #expect(notificationsState.variant == MigrationNotifications.State.Variant.manual)
    }

    @MainActor @Test func notificationsContinuedGoesStraightToTransferPlan() async {
        // Tor is no longer part of this chain at all (W2) — notifications-continued always resolves
        // straight to TransferPlan once background delivery + notifications are both settled.
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
    }

    @MainActor @Test func allPermissionStepsSkippedGoesStraightToTransferPlan() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .denied }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (all permission steps skipped)")
            return
        }
    }

    // MARK: - Scheduled flow (§6.2): plan confirm -> Scheduled

    @MainActor @Test func transferPlanConfirmedInScheduledVariantSchedulesFirstWindowAndPushesScheduled() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))

        #expect(scheduleFirstWindowCalls.value == 1)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
    }

    @MainActor @Test func scheduledDoneFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.scheduled(MigrationScheduled.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .scheduled(.delegate(.done)))))
        await store.receive(\.flowFinished)
    }

    // MARK: - Manual flow (§6.3)

    @MainActor @Test func transferPlanConfirmedInManualVariantSchedulesFirstWindowAndPushesSendingWithTotalCountOne() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .manual)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))

        #expect(scheduleFirstWindowCalls.value == 1)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.networkPrivacyOptions == NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))
    }

    @MainActor @Test func manualPlanConfirmPushesSendingWithSingleTransfer() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .manual, requiresSigning: true)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
    }

    @MainActor @Test func sendingClosedInManualModeWithNoStatusBeneathPushesFreshStatus() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi(1_000),
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 1,
            estimatedDurationHours: 24
        )
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.sending(MigrationSending.State(phase: .success)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.sendGate = { .allowed }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
            $0.sdkSynchronizer.migrationSummary = { summary }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .sending(.delegate(.closed)))))
        await store.receive(\.pushHydratedStatus)

        #expect(store.state.path.count == 2)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status pushed on top of the (still-present) .sending element")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.progress)
        #expect(statusState.isFlowRoot == false)
    }

    // MARK: - sendNow: overdue count drives Sending totalCount, completion returns to Status

    @MainActor @Test func statusSendNowPushesSendingConfiguredForOverdueCount() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 3)
        ]
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.sendNow)))))
        await store.receive(\.pushHydratedPathState)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 2)
        #expect(sendingState.networkPrivacyOptions == NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))
    }

    @MainActor @Test func sendingClosedAfterSendNowPopsBackToStatusWithRefreshedRows() async {
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        state.path.append(.sending(MigrationSending.State(phase: .success, totalCount: 2)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { refreshedRows }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .sending(.delegate(.closed)))))
        await store.receive(\.sendNowCompleted)

        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending popped, .status remaining on top")
            return
        }
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: refreshedRows))
        #expect(statusState.isFlowRoot == true)
    }

    // MARK: - Reschedule (MOB-1478 W7): SDK + scheduler spies called in order, lands .rescheduleCompleted
    // on the SAME status element — no new plan push.

    @MainActor @Test func statusRescheduleSetsIsReschedulingCallsSDKAndSchedulerThenLandsRescheduleCompletedInPlace() async {
        let callOrder = LockIsolated<[String]>([])
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 0,
            transfersTotal: 1,
            estimatedDurationHours: 18
        )
        var state = MigrationCoordFlow.State()
        state.path.append(
            .status(
                MigrationStatus.State(
                    presentation: .resume,
                    rows: [MigrationTransferRow(id: "old", index: 0, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5)],
                    stalledNumber: 1,
                    isFlowRoot: true
                )
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.rescheduleStalledMigrationTransfer = {
                callOrder.withValue { $0.append("reschedule") }
            }
            $0.sdkSynchronizer.migrationTransfers = { refreshedRows }
            $0.sdkSynchronizer.migrationSummary = { summary }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.reschedule)))))
        await store.receive(\.path)

        #expect(callOrder.value == ["reschedule", "scheduleFirstWindow"])
        // No new path element — the SAME status element lands the confirmation.
        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status still the only path element")
            return
        }
        #expect(statusState.isRescheduling == false)
        #expect(statusState.presentation == MigrationStatus.State.Presentation.rescheduleConfirmed(first: 1, last: 1))
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: refreshedRows))
        #expect(statusState.totalDurationHours == 18)
    }

    @MainActor @Test func rescheduledPlanConfirmDoesNotSignAndFinishesFlow() async {
        let signCalls = LockIsolated<Int>(0)
        var planState = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: false)
        planState.rows = [MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)]
        let store = TestStore(initialState: planState) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 0)
    }

    @MainActor @Test func rescheduledPlanConfirmedInCoordinatorFinishesFlowWithoutPushingScheduled() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled, requiresSigning: false)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        await store.receive(\.flowFinished)

        #expect(scheduleFirstWindowCalls.value == 0)
    }

    // MARK: - Recovery: restartCurrentMigrationStep spy, re-created plan injected, its confirm DOES sign

    @MainActor @Test func recoveryRecreateCallsRestartAndPushesRecreatedPlanWithInjectedSchedule() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let restartCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = {
                restartCalls.withValue { $0 += 1 }
                return schedule
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.pushHydratedPathState)

        #expect(restartCalls.value == 1)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan (re-created) pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == schedule)
        #expect(planState.requiresSigning == true)
    }

    @MainActor @Test func recreatedPlanConfirmDoesSign() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .recreated)
        planState.schedule = schedule
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        let store = TestStore(initialState: planState) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { signedSchedule.setValue($0) }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
    }

    // MARK: - Every flow-root back -> .flowFinished

    @MainActor @Test func statusDoneFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.done)))))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func recoveryCloseFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.close)))))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func reviewTransferClosedFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(
            .reviewTransfer(MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5), isFlowRoot: true))
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.closed)))))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func completeDoneAcknowledgesCompleteAndFinishesFlow() async {
        let acknowledgeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.acknowledgeComplete = { acknowledgeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.done)))))
        await store.receive(\.flowFinished)

        #expect(acknowledgeCalls.value == 1)
    }

    // MARK: - MOB-1480: Keystone signing — simulator-only bypass (no `.scan` ever pushed)

    @MainActor @Test func keystoneSignSimulateSignatureForImmediateReviewContextStoresPopsAndPushesSendingWithoutScan() async {
        let storeCalls = LockIsolated<[[Pczt]]>([])
        let signed: [Pczt] = [Data([0xEE])]
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: signed)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in storeCalls.withValue { $0.append(stored) } }
        }
        store.exhaustivity = .off

        // No `.scan` element on the path at all — the bypass button lives on `keystoneSign` itself
        // and the coordinator reads the batch straight off that element instead of a scanned
        // result. Deliberately NOT asserting `isSimulatorBypassVisible` here: this test target
        // (zodl-internal) always has `MigrationSimulatorFlag.isEnabled == false`, so the button
        // would never actually be visible in this build — the coordinator's handler is
        // intentionally not flag-gated (only the button's visibility is), so driving the delegate
        // directly is the correct boundary to test.
        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [signed])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom (only keystoneSign popped)")
            return
        }
    }

    @MainActor @Test func keystoneSignSimulateSignatureWithEmptyBatchFallsBackToPlaceholderAndResumesPlanCommit() async {
        let storeCalls = LockIsolated<[[Pczt]]>([])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }
        store.exhaustivity = .off

        // Unlike the real `.scan(.foundPCZTBatch([]))` path (which abandons the session — see
        // `foundPCZTBatchWithEmptyArrayForPlanCommitContextAbandonsSessionWithoutStoring` above),
        // the simulator bypass falls back to a single fabricated placeholder `Pczt` instead: this
        // button exists purely to exercise the resume chain for manual QA, never a real signing
        // session that could legitimately fail to decode.
        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [[Pczt()]])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed on top of the retained .transferPlan element")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (only keystoneSign popped)")
            return
        }
    }
}
