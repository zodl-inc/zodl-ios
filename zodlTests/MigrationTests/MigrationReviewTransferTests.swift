//
//  MigrationReviewTransferTests.swift
//  zodlTests
//
//  Covers the MigrationReviewTransfer reducer
//  (Features/Migration/MigrationReviewTransfer/MigrationReviewTransferStore.swift) for MOB-1463/1466:
//  the default `mode`, and (MOB-1466) two divergent `onAppear`/`confirmTapped` paths keyed off
//  `mode` — immediate proposes a single-transfer schedule via `proposeMigrationTransfers()` for
//  Amount/Fee and signs+stores it on confirm before delegating; manual step has its data injected by
//  the coordinator (no propose) and confirm delegates directly (the transfer was already signed at
//  plan commit). Also covers the `isFlowRoot`-gated back control for the manual-step variant: a new
//  `Delegate.closed` case (reusing `.confirmed` for a back-tap would be a correctness bug — that
//  case means "user confirmed the transfer", not "user backed out"). No shared/global state ->
//  no `.serialized`.
//

import Testing
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationReviewTransferTests {
    @MainActor @Test func defaultStateIsImmediateModeWithZeroAmounts() async {
        let state = MigrationReviewTransfer.State()

        #expect(state.mode == MigrationReviewTransfer.State.Mode.immediate)
        #expect(state.amount == Zatoshi.zero)
        #expect(state.fee == Zatoshi.zero)
        #expect(state.isFlowRoot == false)
    }

    @MainActor @Test func closeTappedWhenFlowRootEmitsDelegateClosed() async {
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5), isFlowRoot: true)
        ) {
            MigrationReviewTransfer()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.closed))
    }

    @MainActor @Test func delegateClosedActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationReviewTransfer.State()) {
            MigrationReviewTransfer()
        }

        await store.send(.delegate(.closed))
    }

    @MainActor @Test func manualStepModeIsPreservedInState() async {
        let state = MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))

        #expect(state.mode == .manualStep(number: 3, total: 5))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationReviewTransfer.State()) {
            MigrationReviewTransfer()
        }

        await store.send(.delegate(.confirmed))
    }

    // MARK: - Immediate mode: onAppear proposes, confirm signs+stores then delegates

    @MainActor @Test func onAppearInImmediateModeProposesSingleTransferScheduleForAmountFee() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { schedule }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposed) {
            $0.amount = Zatoshi(1_245_800_000)
            $0.fee = Zatoshi(100_000)
            $0.schedule = schedule
        }
    }

    @MainActor @Test func onAppearInManualStepModeDoesNotProposeAndLeavesInjectedDataAlone() async {
        let proposeCalls = LockIsolated<Int>(0)
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(
                mode: .manualStep(number: 3, total: 5),
                amount: Zatoshi(243_100_000),
                fee: Zatoshi(100_000)
            )
        ) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = {
                proposeCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }

        await store.send(.onAppear)

        #expect(proposeCalls.value == 0)
        #expect(store.state.amount == Zatoshi(243_100_000))
    }

    @MainActor @Test func confirmTappedInImmediateModeSignsAndStoresScheduleThenDelegatesConfirmed() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { signedSchedule.setValue($0) }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
    }

    @MainActor @Test func confirmTappedInManualStepModeDelegatesConfirmedDirectlyWithoutSigning() async {
        let signCalls = LockIsolated<Int>(0)
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        ) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 0)
    }
}
