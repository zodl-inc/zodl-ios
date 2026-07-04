//
//  MigrationCoordFlowTests.swift
//  zodlTests
//
//  Covers `MigrationCoordFlow` (Features/CoordFlows/MigrationCoordFlow{Store,Coordinator}.swift)
//  for MOB-1466: re-entry routing (`.onAppear`), the chaining table from Entry through Complete
//  for all three modes (immediate/scheduled/manual), the permission-step helper's skip logic,
//  sendNow/reschedule/recovery orchestration, and every flow-root close path's `.flowFinished`
//  emission. Also covers MOB-1468/1469's SEQUENTIAL Keystone signing queue: each of the three
//  signing sources' `.keystoneSignRequested` delegate seeds `pendingKeystoneSigning` and pushes
//  `keystoneSign` for session 1 of N; `keystoneSign(.delegate(.getSignature))` pushes `scan`
//  configured with the send flow's single-PCZT checker; each `scan(.foundPCZT)` collects the
//  signature and either advances the queue (pop scan+sign, push the next session) or, after the
//  last session, submits/stores the FULL set ONCE in proposal order and resumes the matching chain
//  (noteSplit splitting phase / plan post-confirm / immediate sending) — verified with
//  order-asserting spies; `.rejected` and a mid-queue scan cancel discard EVERY collected
//  signature and pop back to the signing source with its state intact (no-partial-storage
//  invariant: neither path ever calls submit/store); an unusable propose hand-off (empty array or
//  empty placeholder PCZTs) starts no session at all. `.serialized`: every
//  `MigrationCoordFlow.State()` carries a `MigrationEntry.State` (`entryState`), which reads the
//  process-global `@Shared(.inMemory(.selectedWalletAccount))` on init — matching the precedent in
//  `MigrationEntryTests`, which mutates the same key directly.
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

    // MARK: - Immediate flow (§6.1)

    @MainActor @Test func entryChoseImmediateWithTorFlagOnSkipsNetworkPrivacyAndPushesReview() async {
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
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path (NetworkPrivacy skipped)")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
    }

    @MainActor @Test func entryChoseImmediateWithTorFlagOffShowsNetworkPrivacy() async {
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

        guard case let .networkPrivacy(networkPrivacyState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .networkPrivacy on the path (Tor flag off)")
            return
        }
        #expect(networkPrivacyState.variant == MigrationNetworkPrivacy.State.Variant.immediate)
    }

    @MainActor @Test func networkPrivacyConfirmedInImmediateModePushesReviewTransferImmediate() async {
        let setOptionsCalls = LockIsolated<[NetworkPrivacyOptions]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State(variant: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { options in setOptionsCalls.withValue { $0.append(options) } }
        }
        store.exhaustivity = .off

        let options = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        await store.send(.path(.element(id: 0, action: .networkPrivacy(.delegate(.confirmed(options))))))

        #expect(setOptionsCalls.value == [options])
        #expect(store.state.networkPrivacyOptions == options)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
    }

    @MainActor @Test func networkPrivacyConfirmedInScheduledModePushesTransferPlan() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State(variant: .scheduled(transferCount: 5))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
        }
        store.exhaustivity = .off

        let options = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        await store.send(.path(.element(id: 0, action: .networkPrivacy(.delegate(.confirmed(options))))))

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed on top")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
    }

    @MainActor @Test func manualDeliveryFreshPlanUsesManualVariant() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State(variant: .scheduled(transferCount: 5))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
            $0.migrationManager.isManualDelivery = { true }
        }
        store.exhaustivity = .off

        let options = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        await store.send(.path(.element(id: 0, action: .networkPrivacy(.delegate(.confirmed(options))))))

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

    // MARK: - MOB-1468/1469: Keystone signing — signRequested seeds the queue + pushes session 1

    @MainActor @Test func noteSplitKeystoneSignRequestedSeedsNoteSplitQueueAndPushesFirstSession() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [Pczt] = [Data([0xAA])]
        await store.send(.path(.element(id: 0, action: .noteSplit(.delegate(.keystoneSignRequested(pczts))))))

        let queue = store.state.pendingKeystoneSigning
        #expect(queue?.context == MigrationCoordFlow.KeystoneSigningContext.noteSplit)
        #expect(queue?.pending == pczts)
        #expect(queue?.signed.isEmpty == true)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczt == pczts[0])
        #expect(signState.sessionIndex == 1)
        #expect(signState.sessionTotal == 1)
    }

    @MainActor @Test func transferPlanKeystoneSignRequestedSeedsPlanCommitQueueAndPushesSessionOneOfN() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [Pczt] = [Data([0xAA]), Data([0xBB])]
        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.keystoneSignRequested(pczts))))))

        let queue = store.state.pendingKeystoneSigning
        #expect(queue?.context == MigrationCoordFlow.KeystoneSigningContext.planCommit)
        #expect(queue?.pending == pczts)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        // Session 1 of 2 signs the FIRST proposed PCZT — the order pairs with the engine's cached
        // transfer ids by index, so it is load-bearing.
        #expect(signState.pczt == pczts[0])
        #expect(signState.sessionIndex == 1)
        #expect(signState.sessionTotal == 2)
    }

    @MainActor @Test func reviewTransferKeystoneSignRequestedSeedsImmediateReviewQueue() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [Pczt] = [Data([0xCC])]
        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.keystoneSignRequested(pczts))))))

        let queue = store.state.pendingKeystoneSigning
        #expect(queue?.context == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        #expect(queue?.pending == pczts)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczt == pczts[0])
    }

    @MainActor @Test func keystoneSignRequestedWithNoUsablePCZTsStartsNoSession() async {
        // The engine signals a failed propose with an empty array (plan/immediate) or an empty
        // placeholder `Pczt()` (note split) — neither may start a signing session: the user stays
        // on the source screen and re-initiates from its confirm button. A partially empty set is
        // refused whole too: dropping only the empty ones would silently break the index pairing
        // with the engine's cached transfer ids.
        var state = MigrationCoordFlow.State()
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .noteSplit(.delegate(.keystoneSignRequested([Pczt()]))))))
        await store.send(.path(.element(id: 1, action: .transferPlan(.delegate(.keystoneSignRequested([]))))))
        await store.send(.path(.element(id: 1, action: .transferPlan(.delegate(.keystoneSignRequested([Data([0x01]), Pczt()]))))))

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
    }

    // MARK: - MOB-1468/1469: Keystone signing — getSignature pushes scan with the send flow's checker

    @MainActor @Test func keystoneSignGetSignaturePushesScanConfiguredWithSinglePCZTChecker() async {
        let resetCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .noteSplit, pending: [Data([0xAA])])
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0xAA]))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.keystoneHandler.resetQRDecoder = { resetCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.getSignature)))))

        guard case let .scan(scanState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scan pushed on top")
            return
        }
        #expect(scanState.checkers == [.keystonePCZTScanChecker])
        // The UR decoder latches after a completed decode — every session's scan must be preceded
        // by a reset or the next session decodes nothing.
        #expect(resetCalls.value == 1)
    }

    // MARK: - MOB-1469: Keystone signing — sequential queue runs one session per PCZT

    @MainActor @Test func twoTransferPlanQueueRunsTwoSessionsThenStoresOnceInProposalOrder() async {
        let storeCalls = LockIsolated<[[Pczt]]>([])
        let scheduleCalls = LockIsolated<Int>(0)
        let pending: [Pczt] = [Data([0x01]), Data([0x02])]
        let signedFirst: Pczt = Data([0xA1])
        let signedSecond: Pczt = Data([0xA2])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .planCommit, pending: pending)
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: pending[0], sessionIndex: 1, sessionTotal: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.keystoneHandler.resetQRDecoder = { }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        // Session 1 of 2: the scanned signature is collected, scan+sign pop, session 2 pushes.
        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signedFirst)))))
        await store.receive(\.keystoneNextSigningSession)

        #expect(storeCalls.value.isEmpty)
        #expect(store.state.pendingKeystoneSigning?.signed == [signedFirst])
        #expect(store.state.path.count == 2)
        guard case let .keystoneSign(secondSession) = try? #require(store.state.path.last) else {
            Issue.record("Expected session 2's .keystoneSign pushed after session 1 completed")
            return
        }
        #expect(secondSession.pczt == pending[1])
        #expect(secondSession.sessionIndex == 2)
        #expect(secondSession.sessionTotal == 2)

        // Session 2 of 2: scan pushes again, the final signature triggers ONE store with the full
        // collected set in proposal order, then the scheduled screen resumes the chain.
        await store.send(.path(.element(id: 3, action: .keystoneSign(.delegate(.getSignature)))))
        await store.send(.path(.element(id: 4, action: .scan(.foundPCZT(signedSecond)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [[signedFirst, signedSecond]])
        #expect(scheduleCalls.value == 1)
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

    // MARK: - MOB-1468/1469: Keystone signing — final foundPCZT resumes noteSplit

    @MainActor @Test func foundPCZTForNoteSplitContextSubmitsSignedPcztPopsAndMutatesNoteSplitIntoSplittingPhase() async {
        let callOrder = LockIsolated<[String]>([])
        let signed: Pczt = Data([0xAA])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .noteSplit, pending: [Data([0x0A])])
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0A]))))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitSignedNoteSplit = { pczt in
                callOrder.withValue { $0.append("submitSignedNoteSplit(\(pczt))") }
                return .success(txId: "keystone-split-tx-id")
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in
                callOrder.withValue { $0.append("storeSignedMigrationTransactions") }
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        // The SCANNED (device-signed) PCZT is what gets submitted — not the unsigned original.
        #expect(callOrder.value == ["submitSignedNoteSplit(\(signed))"])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected scan+keystoneSign popped, .noteSplit remaining on top")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.splitting)
        #expect(noteSplitState.txId == "keystone-split-tx-id")
        #expect(noteSplitState.signedNoteSplitPczt == signed)
        #expect(noteSplitState.isFailurePresented == false)
    }

    @MainActor @Test func foundPCZTForNoteSplitContextWithFailureResultPresentsFailureSheetAndKeepsSignedPczt() async {
        let signed: Pczt = Data([0xBB])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .noteSplit, pending: [Data([0x0B])])
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0B]))))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitSignedNoteSplit = { _ in .networkError(retryable: true) }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit remaining on top")
            return
        }
        // The failure sheet's Retry re-broadcasts this SAME signed PCZT — it must survive here.
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.splitting)
        #expect(noteSplitState.isFailurePresented == true)
        #expect(noteSplitState.signedNoteSplitPczt == signed)
    }

    // MARK: - MOB-1468/1469: Keystone signing — final foundPCZT resumes planCommit (manual variant)

    @MainActor @Test func foundPCZTForPlanCommitContextPushesSendingForManualVariant() async {
        let signed: Pczt = Data([0xCC])
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .planCommit, pending: [Data([0x0C])])
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .manual)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0C]))))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top for the manual variant")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.networkPrivacyOptions == NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil))
    }

    // MARK: - MOB-1468/1469: Keystone signing — final foundPCZT resumes immediateReview

    @MainActor @Test func foundPCZTForImmediateReviewContextStoresPopsAndPushesSending() async {
        let storeCalls = LockIsolated<[[Pczt]]>([])
        let signed: Pczt = Data([0xDD])
        var state = MigrationCoordFlow.State()
        state.networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .immediateReview, pending: [Data([0x0D])])
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0D]))))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { stored in storeCalls.withValue { $0.append(stored) } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [[signed]])
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

    // MARK: - MOB-1468/1469: Keystone signing — mid-queue abandonment (no-partial-storage)

    @MainActor @Test func midQueueRejectDiscardsAllCollectedSignaturesAndPopsToPlan() async {
        let storeCalls = LockIsolated<Int>(0)
        var queue = MigrationCoordFlow.KeystoneSigningQueue(context: .planCommit, pending: [Data([0x01]), Data([0x02])])
        queue.signed = [Data([0xA1])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = queue
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x02]), sessionIndex: 2, sessionTotal: 2)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        // Session 1's collected signature dies with the queue — the store is all-or-nothing, so a
        // partial set must never survive a rejection.
        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .transferPlan remaining on top, unsigned")
            return
        }
    }

    @MainActor @Test func midQueueScanCancelAbandonsWholeSessionWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(
            context: .planCommit,
            pending: [Data([0x01]), Data([0x02])]
        )
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x01]), sessionIndex: 1, sessionTotal: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.cancelTapped))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    @MainActor @Test func scanCancelWithoutActiveQueueDoesNothing() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .scan(.cancelTapped))))

        #expect(store.state.path.count == 2)
    }

    // MARK: - MOB-1468/1469: Keystone signing — rejected pops back with state intact, queue cleared

    @MainActor @Test func keystoneSignRejectedPopsBackToNoteSplitWithExplainerStateIntactAndClearsQueue() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .noteSplit, pending: [Data([0x0A])])
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0A]))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .noteSplit remaining on top")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.explainer)
        #expect(noteSplitState.signedNoteSplitPczt == nil)
    }

    @MainActor @Test func keystoneSignRejectedNeverCallsSubmitOrStore() async {
        let submitCalls = LockIsolated<Int>(0)
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningQueue(context: .noteSplit, pending: [Data([0x0A])])
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .explainer)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczt: Data([0x0A]))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitSignedNoteSplit = { _ in
                submitCalls.withValue { $0 += 1 }
                return .success(txId: "should-not-be-called")
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(submitCalls.value == 0)
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

    // MARK: - Scheduled flow (§6.2): note-split skip

    @MainActor @Test func entryChoseScheduledWithNoteSplitNeededPushesNoteSplit() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.privateScheduled))))

        guard case .noteSplit = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit pushed (note split needed)")
            return
        }
    }

    @MainActor @Test func entryChoseScheduledWithoutNoteSplitNeededGoesStraightToPermissionSteps() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { false }
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.privateScheduled))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (all permission steps skipped)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
        #expect(store.state.networkPrivacyOptions.useTor == true)
    }

    // MARK: - Scheduled flow (§6.2): permission-step skip combinations

    @MainActor @Test func noteSplitContinuedWithAllPermissionStepsNeededPushesBackgroundDelivery() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .confirmed)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .denied }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .noteSplit(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case .backgroundDelivery = try? #require(store.state.path.last) else {
            Issue.record("Expected .backgroundDelivery pushed (background refresh not available)")
            return
        }
    }

    @MainActor @Test func noteSplitFlowRootCloseFinishesFlowInsteadOfContinuingPermissionSteps() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.noteSplit(MigrationNoteSplit.State(phase: .splitting, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        // Same `.continued` delegate value as a normal continue, but `closeTapped` on a flow-root
        // splitting screen — must finish the flow, not proceed to permission-step routing.
        await store.send(.path(.element(id: 0, action: .noteSplit(.delegate(.continued)))))
        await store.receive(\.flowFinished)
    }

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

    @MainActor @Test func notificationsContinuedWithTorFlagOffPushesNetworkPrivacyScheduledVariant() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .pending, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .pending, hoursFromNow: 0)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationTransfers = { rows }
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .networkPrivacy(networkPrivacyState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .networkPrivacy pushed (Tor flag off)")
            return
        }
        #expect(networkPrivacyState.variant == MigrationNetworkPrivacy.State.Variant.scheduled(transferCount: 2))
    }

    @MainActor @Test func allPermissionStepsSkippedGoesStraightToTransferPlanWithForcedTor() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .denied }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (all permission steps skipped)")
            return
        }
        #expect(store.state.networkPrivacyOptions.useTor == true)
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

    // MARK: - Reschedule: SDK + scheduler spies called in order, rescheduled plan pushed

    @MainActor @Test func statusRescheduleSetsIsReschedulingCallsSDKAndSchedulerThenPushesPlan() async {
        let callOrder = LockIsolated<[String]>([])
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.rescheduleStalledMigrationTransfer = {
                callOrder.withValue { $0.append("reschedule") }
            }
            $0.sdkSynchronizer.migrationTransfers = { refreshedRows }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.reschedule)))))
        await store.receive(\.pushHydratedPathState)

        #expect(callOrder.value == ["reschedule", "scheduleFirstWindow"])
        guard case let .status(statusState) = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .status still at the bottom of the path with isRescheduling set")
            return
        }
        #expect(statusState.isRescheduling == true)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan (rescheduled) pushed")
            return
        }
        #expect(planState.requiresSigning == false)
        #expect(planState.rows == IdentifiedArrayOf(uniqueElements: refreshedRows))
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
}
