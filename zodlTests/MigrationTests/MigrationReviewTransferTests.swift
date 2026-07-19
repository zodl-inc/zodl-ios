//
//  MigrationReviewTransferTests.swift
//  zodlTests
//
//  Covers the MigrationReviewTransfer reducer
//  (Features/Migration/MigrationReviewTransfer/MigrationReviewTransferStore.swift) for MOB-1463/1466:
//  the default `mode`, and (MOB-1466) two divergent `onAppear`/`confirmTapped` paths keyed off
//  `mode` — immediate proposes a single-transfer schedule via `proposeImmediateMigration()` for
//  Amount/Fee and signs+stores it on confirm before delegating; manual step has its data injected by
//  the coordinator (no propose) and confirm delegates directly (the transfer was already signed at
//  plan commit). Also covers the `isFlowRoot`-gated back control for the manual-step variant: a new
//  `Delegate.closed` case (reusing `.confirmed` for a back-tap would be a correctness bug — that
//  case means "user confirmed the transfer", not "user backed out"). Also covers MOB-1468's
//  Keystone fork: a Keystone-vendor account in immediate mode proposes the schedule's PCZT via
//  `proposeMigrationPCZTs(schedule)` and delegates `.keystoneSignRequested` instead of signing+
//  storing locally (`.zcash` regression unaffected); the manual-step path never forks, even for a
//  Keystone account (those transfers were already signed at plan commit). `.serialized`: several
//  cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationReviewTransferTests {
    /// MOB-1496: `migrationManager.migrationNetworkOptions(_:)` has no macro default (unlike the SDK
    /// synchronizer's `.noOp`), so any test reaching the note-split branch (`isNoteSplitNeeded ==
    /// true`) must mock it explicitly or trip `unimplemented`.
    private static let defaultNetworkPrivacyOptions = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )

    /// MOB-1496: mirrors `MigrationTransferPlanTests`' setup hook — every test gets a selected
    /// software account by default; Keystone-specific tests override it locally.
    init() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 0) }
    }

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

    /// MOB-1496: the software-signing path derives a real USK from the wallet's stored seed — see
    /// `MigrationTransferPlanTests`' twin helper for the rationale.
    private func withDependenciesUSKDerivable(_ values: inout DependencyValues) {
        values.derivationTool = .liveValue
        values.mnemonic = .mock
        values.walletStorage = .noOp
        values.zcashSDKEnvironment = .testnet
    }

    @MainActor @Test func defaultStateIsImmediateModeWithZeroAmounts() async {
        let state = MigrationReviewTransfer.State()

        #expect(state.mode == MigrationReviewTransfer.State.Mode.immediate)
        #expect(state.amount == Zatoshi.zero)
        #expect(state.fee == Zatoshi.zero)
        #expect(state.isFlowRoot == false)
        // Not asserting `selectedWalletAccount == nil`: MOB-1496's `init()` above seeds a default
        // selected account for every test in this suite — see `MigrationTransferPlanTests`' twin
        // assertion for the rationale.
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in schedule }
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
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        // MOB-1496 (W2): the write-point for the persisted-schedule storage — fires once the
        // schedule is actually signed+stored, alongside the existing `reconcile()` trigger.
        let recordCommittedScheduleCalls = LockIsolated<[(AccountUUID?, MigrationSchedule)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, schedule, _ in signedSchedule.setValue(schedule) }
            $0.migrationManager.recordCommittedSchedule = { accountUUID, schedule in
                recordCommittedScheduleCalls.withValue { $0.append((accountUUID, schedule)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
        #expect(recordCommittedScheduleCalls.value.count == 1)
        #expect(recordCommittedScheduleCalls.value.first?.0 == state.selectedWalletAccount?.id)
        #expect(recordCommittedScheduleCalls.value.first?.1 == schedule)
        #expect(reconcileCalls.value == 1)
    }

    @MainActor @Test func confirmTappedInManualStepModeDelegatesConfirmedDirectlyWithoutSigning() async {
        let signCalls = LockIsolated<Int>(0)
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        ) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 0)
    }

    // MARK: - MOB-1468: Keystone confirmTapped fork

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountProposesPCZTAndDelegatesKeystoneSignRequestedWithoutSigning() async {
        let proposeCalls = LockIsolated<[MigrationSchedule]>([])
        let signCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let pczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 1) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, proposed in
                proposeCalls.withValue { $0.append(proposed) }
                return pczts
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(pczts)))

        #expect(proposeCalls.value == [schedule])
        #expect(signCalls.value == 0)
    }

    @MainActor @Test func confirmTappedInImmediateModeWithZcashAccountUsesSoftwarePathUnchanged() async {
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 2) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): the sign+store success path now also calls these two — explicit
            // no-op overrides since swift-dependencies requires `migrationManager` to be
            // customized at least once before any of its members can run in a test context.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(proposeCalls.value == 0)
    }

    @MainActor @Test func confirmTappedInManualStepModeWithKeystoneAccountNeverForksAndDelegatesConfirmedDirectly() async {
        let proposeCalls = LockIsolated<Int>(0)
        let signCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 3) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(proposeCalls.value == 0)
        #expect(signCalls.value == 0)
    }

    // MARK: - MOB-1478 (W4): silent note split runs before sign+store (immediate mode only)

    @MainActor @Test func confirmTappedInImmediateModeWithNoteSplitNeededSplitsBeforeSigningThenDelegatesConfirmed() async {
        let callOrder = LockIsolated<[String]>([])
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                callOrder.withValue { $0.append("prepare") }
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero)
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("submit") }
                return MigrationTransferResult.success(txId: "split-tx-id")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(callOrder.value == ["prepare", "submit", "signAndStore"])
    }

    @MainActor @Test func confirmTappedInImmediateModeWithNoteSplitFailurePresentsFailureSheetAndNeverSigns() async {
        let signCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.invalidNote }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
        }

        #expect(signCalls.value == 0)
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.isFailurePresented = true
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func retryTappedInImmediateModeReattemptsWholeConfirmSequence() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.isFailurePresented = true
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): see `confirmTappedInImmediateModeWithZcashAccountUsesSoftwarePathUnchanged`'s comment.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))
    }

    // MOB-1478 (W4): the Keystone fork's batch now carries the note-split PCZT first, when needed —
    // proved via proposal ORDER (split proposed before the schedule's own PCZT). MOB-1496: the
    // note-split entry now rides the batch under a `"note-split"` sentinel id — see
    // `MigrationTransferPlanTests`' twin test / `requestKeystoneSignature`'s doc.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountAndNoteSplitNeededProposesSplitPcztFirst() async {
        let proposeOrder = LockIsolated<[String]>([])
        let splitPczt = Data([0x02])
        let schedulePczt: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        let expectedBatch = [MigrationUnsignedTransferPczt(id: "note-split", pczt: splitPczt)] + schedulePczt
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.proposeNoteSplitPCZT = { _ in
                proposeOrder.withValue { $0.append("split") }
                return splitPczt
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeOrder.withValue { $0.append("schedule") }
                return schedulePczt
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(expectedBatch)))

        #expect(proposeOrder.value == ["split", "schedule"])
    }

    // MARK: - MOB-1496 (W3 review fix A): stop an in-flight sync before the silent note-split broadcast

    /// `sdkSynchronizer.isSyncing() == true` -> `stop()` fires BEFORE `submitNoteSplit`, in that
    /// order (asserted via a shared call-order log) — this screen's silent note-split broadcast
    /// (MOB-1478 W4, immediate mode) was missed by W3's original stop-before-broadcast sweep;
    /// mirrors `MigrationSendingStore`/`MigrationNoteSplitStore`'s existing treatment.
    @MainActor @Test func confirmTappedInImmediateModeWithNoteSplitNeededWhileSyncingStopsSyncBeforeSubmittingNoteSplit() async {
        let callOrder = LockIsolated<[String]>([])
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                callOrder.withValue { $0.append("prepare") }
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero)
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("submit") }
                return MigrationTransferResult.success(txId: "split-tx-id")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        // `prepare` runs first (a read-only propose, not a broadcast — needed before we even know
        // there's something to broadcast); `stop` then fires immediately before `submit`, the
        // actual broadcast call, matching `MigrationNoteSplitStore`'s own stop-before-broadcast
        // placement.
        #expect(callOrder.value == ["prepare", "stop", "submit", "signAndStore"])
    }

    /// Idempotent: `sdkSynchronizer.isSyncing() == false` -> `stop()` is never called.
    @MainActor @Test func confirmTappedInImmediateModeWithNoteSplitNeededWhileIdleDoesNotCallStopBeforeSubmittingNoteSplit() async {
        let stopCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { stopCalls.withValue { $0 += 1 } },
                isSyncing: { false }
            )
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "split-tx-id") }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(stopCalls.value == 0)
    }
}
