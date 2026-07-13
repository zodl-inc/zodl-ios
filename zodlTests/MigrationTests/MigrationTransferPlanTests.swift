//
//  MigrationTransferPlanTests.swift
//  zodlTests
//
//  Covers the MigrationTransferPlan reducer
//  (Features/Migration/MigrationTransferPlan/MigrationTransferPlanStore.swift) for MOB-1463/1466:
//  the default `variant`, the `confirmTapped` delegate contract, and (MOB-1466) `onAppear` — a
//  fresh entry proposes transfers via `proposeMigrationTransfers()` and populates rows/duration,
//  while an injected schedule (recovery/reschedule variants) is left untouched (no re-propose) —
//  plus `confirmTapped` signing and storing the schedule via `signAndStoreMigrationSchedule`. Also
//  covers MOB-1468's Keystone fork: a Keystone-vendor account with `requiresSigning == true`
//  (fresh/recreated variants) proposes the schedule's PCZTs and delegates `.keystoneSignRequested`
//  instead of signing+storing locally (`.zcash` regression unaffected); the rescheduled
//  (`requiresSigning == false`) variant never forks, even for a Keystone account. `.serialized`:
//  several cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationTransferPlanTests {
    private func walletAccount(keystone: Bool, idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @MainActor @Test func defaultStateIsScheduledVariantWithNoRows() async {
        let state = MigrationTransferPlan.State()

        #expect(state.variant == MigrationTransferPlan.State.Variant.scheduled)
        #expect(state.rows.isEmpty)
        #expect(state.totalDurationHours == 0)
        #expect(state.injectedSchedule == nil)
        #expect(state.selectedWalletAccount == nil)
    }

    @MainActor @Test func recreatedVariantIsPreservedInState() async {
        let state = MigrationTransferPlan.State(variant: .recreated)

        #expect(state.variant == .recreated)
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationTransferPlan.State()) {
            MigrationTransferPlan()
        }

        await store.send(.delegate(.confirmed))
    }

    // MARK: - onAppear: fresh propose vs. injected schedule

    @MainActor @Test func onAppearWithNoInjectedScheduleProposesTransfersAndPopulatesRows() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                TransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { schedule }
        }

        await store.send(.onAppear)
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }
    }

    @MainActor @Test func onAppearWithInjectedScheduleDoesNotReProposeAndPopulatesRowsDirectly() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(200_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150)
            ],
            estimatedDurationHours: 12
        )
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = {
                proposeCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }

        await store.send(.onAppear) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(200_000_000), status: .active, hoursFromNow: 0)
            ]
            $0.totalDurationHours = 12
            $0.schedule = schedule
        }

        #expect(proposeCalls.value == 0)
    }

    @MainActor @Test func onAppearWithCoordinatorHydratedRowsDoesNotRePropose() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let state = MigrationTransferPlan.State(
            variant: .scheduled,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: 12,
            requiresSigning: false
        )
        let called = LockIsolated<Bool>(false)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = {
                called.setValue(true)
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }

        await store.send(.onAppear)

        #expect(called.value == false)
    }

    // MARK: - confirmTapped: sign + store, then delegate

    @MainActor @Test func confirmTappedSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
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

    @MainActor @Test func confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .manual)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))
    }

    // MARK: - MOB-1468: Keystone confirmTapped fork

    @MainActor @Test func confirmTappedWithKeystoneAccountAndRequiresSigningProposesPCZTsAndDelegatesKeystoneSignRequestedWithoutSigning() async {
        let proposeCalls = LockIsolated<[MigrationSchedule]>([])
        let signCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let pczts: [Pczt] = [Data([0xAA]), Data([0xBB])]
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 1) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { proposed in
                proposeCalls.withValue { $0.append(proposed) }
                return pczts
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(pczts)))

        #expect(proposeCalls.value == [schedule])
        #expect(signCalls.value == 0)
    }

    @MainActor @Test func confirmTappedWithKeystoneRecreatedVariantProposesPCZTsAndDelegatesKeystoneSignRequested() async {
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        let pczts: [Pczt] = [Data([0xCC])]
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 2) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _ in
                proposeCalls.withValue { $0 += 1 }
                return pczts
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(pczts)))

        #expect(proposeCalls.value == 1)
    }

    @MainActor @Test func confirmTappedWithZcashAccountUsesSoftwarePathUnchanged() async {
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 3) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(proposeCalls.value == 0)
    }

    @MainActor @Test func confirmTappedWithKeystoneAccountAndRescheduledVariantNeverForksAndFinishesLikeSoftwarePath() async {
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: false)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 4) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(proposeCalls.value == 0)
    }

    // MARK: - MOB-1478 (W4): silent note split runs before sign+store

    @MainActor @Test func confirmTappedWithNoteSplitNeededSplitsBeforeSigningThenEmitsDelegateConfirmed() async {
        let callOrder = LockIsolated<[String]>([])
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { true }
            $0.sdkSynchronizer.prepareNoteSplit = {
                callOrder.withValue { $0.append("prepare") }
                return NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
            }
            $0.sdkSynchronizer.submitNoteSplit = { _ in
                callOrder.withValue { $0.append("submit") }
                return .success(txId: "split-tx-id")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(callOrder.value == ["prepare", "submit", "signAndStore"])
    }

    @MainActor @Test func confirmTappedWithNoteSplitNotNeededSkipsSplitAndSignsDirectly() async {
        let prepareCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { false }
            $0.sdkSynchronizer.prepareNoteSplit = {
                prepareCalls.withValue { $0 += 1 }
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero)
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(prepareCalls.value == 0)
    }

    @MainActor @Test func confirmTappedWithNoteSplitFailurePresentsFailureSheetAndNeverSigns() async {
        let signCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { true }
            $0.sdkSynchronizer.prepareNoteSplit = { NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _ in .networkError(retryable: true) }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
        }

        #expect(signCalls.value == 0)
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        var state = MigrationTransferPlan.State()
        state.isFailurePresented = true
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func retryTappedDismissesFailureSheetAndReattemptsWholeConfirmSequence() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        state.isFailurePresented = true
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _ in }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))
    }

    // MOB-1478 (W4): the Keystone fork's batch now carries the note-split PCZT first, when needed —
    // proved via proposal ORDER (split proposed before the schedule's own PCZTs).
    @MainActor @Test func confirmTappedWithKeystoneAccountAndNoteSplitNeededProposesSplitPcztBeforeSchedulePCZTs() async {
        let proposeOrder = LockIsolated<[String]>([])
        let splitPczt: Pczt = Data([0x01])
        let schedulePczts: [Pczt] = [Data([0xAA]), Data([0xBB])]
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { true }
            $0.sdkSynchronizer.proposeNoteSplitPCZT = {
                proposeOrder.withValue { $0.append("split") }
                return splitPczt
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _ in
                proposeOrder.withValue { $0.append("schedule") }
                return schedulePczts
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested([splitPczt] + schedulePczts)))

        #expect(proposeOrder.value == ["split", "schedule"])
    }
}
