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
    /// MOB-1496: `migrationManager.networkPrivacyOptions()` has no macro default (unlike the SDK
    /// synchronizer's `.noOp`), so any test reaching the note-split branch (`isNoteSplitNeeded ==
    /// true`) must mock it explicitly or trip `unimplemented`.
    private static let defaultNetworkPrivacyOptions = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )

    /// MOB-1496: the real per-account SDK surface needs a concrete `AccountUUID` (and, for the
    /// software-signing path, a resolvable USK) for nearly every migration call this store makes.
    /// Swift Testing instantiates a fresh `struct` per `@Test`, so this `init()` acts as a per-test
    /// setup hook — every test below gets a selected software account by default; the
    /// Keystone-specific tests override it via their own `state.$selectedWalletAccount.withLock`
    /// call (which runs after this `init()`, so last-write-wins).
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

    /// MOB-1496: the software-signing path derives a real USK from the wallet's stored seed
    /// (`MigrationSpendingKeyDerivation.deriveUSK`) — `UnifiedSpendingKey` has no public
    /// initializer anywhere in the SDK, so tests can't fabricate one directly. Matches the
    /// established repo-wide pattern (`RootMigrationBackgroundTests`, send-flow tests): real
    /// `derivationTool`/`mnemonic` derive a real (test) key from `StoredWallet.placeholder`'s seed.
    private func withDependenciesUSKDerivable(_ values: inout DependencyValues) {
        values.derivationTool = .liveValue
        values.mnemonic = .mock
        values.walletStorage = .noOp
        values.zcashSDKEnvironment = .testnet
    }

    @MainActor @Test func defaultStateIsScheduledVariantWithNoRows() async {
        let state = MigrationTransferPlan.State()

        #expect(state.variant == MigrationTransferPlan.State.Variant.scheduled)
        #expect(state.rows.isEmpty)
        #expect(state.totalDurationHours == 0)
        #expect(state.injectedSchedule == nil)
        // Not asserting `selectedWalletAccount == nil` here: MOB-1496's `init()` above seeds a
        // default selected account for every test in this suite (the real per-account SDK surface
        // needs one for nearly every call this store makes) — `@Shared(.inMemory(...))` reflects
        // the CURRENT global value, not a fresh nil, regardless of where `State()` is constructed.
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, includeResidual in
                #expect(includeResidual == false)
                return schedule
            }
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(200_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150)
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
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, _ in
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
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, _ in
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        // MOB-1496 (W2): the write-point for the persisted-schedule storage — fires once the
        // schedule is actually signed+stored, alongside the existing `reconcile()` trigger.
        let recordCommittedScheduleCalls = LockIsolated<[(AccountUUID?, MigrationSchedule)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
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

    @MainActor @Test func confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .manual)
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            // MOB-1496 (W2): the sign+store success path now also calls these two — explicit
            // no-op overrides (rather than relying on their own defaults) since swift-dependencies
            // requires `migrationManager` to be customized at least once before any of its
            // members can run in a test context.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let pczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 1) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
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

    @MainActor @Test func confirmTappedWithKeystoneRecreatedVariantProposesPCZTsAndDelegatesKeystoneSignRequested() async {
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        let pczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xCC]))]
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 2) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
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
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): see `confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed`'s comment.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
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
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
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
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                callOrder.withValue { $0.append("prepare") }
                return NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("submit") }
                return MigrationTransferResult.success(txId: "split-tx-id")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
            $0.migrationManager.networkPrivacyOptions = { Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
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
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                prepareCalls.withValue { $0 += 1 }
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero)
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): see `confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed`'s comment.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
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
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkPrivacyOptions = { Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
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
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): see `confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed`'s comment.
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
    // proved via proposal ORDER (split proposed before the schedule's own PCZTs). MOB-1496: the
    // note-split entry now rides the batch under a `"note-split"` sentinel id (typed-payload
    // mismatch between `proposeNoteSplitPCZT -> Data` and `proposeMigrationPCZTs ->
    // [MigrationUnsignedTransferPczt]` — see `requestKeystoneSignature`'s doc).
    @MainActor @Test func confirmTappedWithKeystoneAccountAndNoteSplitNeededProposesSplitPcztBeforeSchedulePCZTs() async {
        let proposeOrder = LockIsolated<[String]>([])
        let splitPczt = Data([0x01])
        let schedulePczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let expectedBatch = [MigrationUnsignedTransferPczt(id: "note-split", pczt: splitPczt)] + schedulePczts
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.proposeNoteSplitPCZT = { _ in
                proposeOrder.withValue { $0.append("split") }
                return splitPczt
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeOrder.withValue { $0.append("schedule") }
                return schedulePczts
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(expectedBatch)))

        #expect(proposeOrder.value == ["split", "schedule"])
    }

    // MARK: - MOB-1496 (W3 review fix A): stop an in-flight sync before the silent note-split broadcast

    /// `sdkSynchronizer.isSyncing() == true` -> `stop()` fires BEFORE `submitNoteSplit`, in that
    /// order (asserted via a shared call-order log) — this screen's silent note-split broadcast
    /// (MOB-1478 W4) was missed by W3's original stop-before-broadcast sweep; mirrors
    /// `MigrationSendingStore`/`MigrationNoteSplitStore`'s existing treatment.
    @MainActor @Test func confirmTappedWithNoteSplitNeededWhileSyncingStopsSyncBeforeSubmittingNoteSplit() async {
        let callOrder = LockIsolated<[String]>([])
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                callOrder.withValue { $0.append("prepare") }
                return NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("submit") }
                return MigrationTransferResult.success(txId: "split-tx-id")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
            $0.migrationManager.networkPrivacyOptions = { Self.defaultNetworkPrivacyOptions }
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
    @MainActor @Test func confirmTappedWithNoteSplitNeededWhileIdleDoesNotCallStopBeforeSubmittingNoteSplit() async {
        let stopCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { stopCalls.withValue { $0 += 1 } },
                isSyncing: { false }
            )
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000)) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "split-tx-id") }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.networkPrivacyOptions = { Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(stopCalls.value == 0)
    }
}
