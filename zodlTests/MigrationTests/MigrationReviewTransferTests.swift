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
        let proposeNoteSplitPCZTsCalls = LockIsolated<Int>(0)
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
            // MOB-1496 (final engine, plural preps; coverage 2): `proposeKeystoneBatch` folds this
            // call unconditionally now, immediate mode included — an empty prep result must still
            // yield a schedule-only batch (no throw, no injected note-split entry), proving the fold
            // is a true no-op when the engine needs no preps.
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in
                proposeNoteSplitPCZTsCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, proposed in
                proposeCalls.withValue { $0.append(proposed) }
                return pczts
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(pczts)))

        #expect(proposeNoteSplitPCZTsCalls.value == 1)
        #expect(proposeCalls.value == [schedule])
        #expect(signCalls.value == 0)
        // MOB-1496 (R8-T1, S1): the immediate Keystone lane never consults `isNoteSplitNeeded` (that
        // member belongs to the SOFTWARE commit path only) — no stub needed/left behind for it.
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

    // MARK: - MOB-1496 (R8-T1, S1): immediate mode is split-free by engine design (SOFTWARE lane only)
    //
    // The MOB-1478 (W4) "silent note split runs before sign+store" behavior these tests used to
    // cover is GONE from immediate mode's SOFTWARE commit (`commitSoftware`) — the engine's
    // immediate path sweeps the whole balance in one transaction by design and never expects a
    // split; consulting `isNoteSplitNeeded` here and then signing the already-proposed immediate
    // schedule without re-proposing would silently stage a self-conflicting pair (see
    // `MigrationCommitPipeline.commitSoftware`'s doc). The stop-before-broadcast coverage these
    // tests also carried is gone too — nothing in the immediate commit broadcasts anything anymore
    // (`signAndStoreMigrationSchedule` only signs and persists locally), so there is nothing left to
    // stop sync for at this call site. MOB-1496 (final engine): this finding does NOT extend to the
    // Keystone PCZT-proposal fork any more — see the section below.

    /// Even when the engine reports a split is still needed, immediate mode must never consult
    /// `isNoteSplitNeeded`/split — it signs+stores the already-proposed immediate sweep directly.
    @MainActor @Test func confirmTappedInImmediateModeNeverConsultsNoteSplitAndSignsDirectly() async {
        let isNoteSplitNeededCalls = LockIsolated<Int>(0)
        let submitNoteSplitCalls = LockIsolated<Int>(0)
        let signAndStoreCalls = LockIsolated<Int>(0)
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
            // Stubbed to say "yes, split needed" and to succeed if called — proving the immediate
            // lane doesn't even ask, not just that it happens to skip a `false` answer.
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in
                isNoteSplitNeededCalls.withValue { $0 += 1 }
                return true
            }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [Zatoshi(1_245_800_000)], fee: Zatoshi(100_000)) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitNoteSplitCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-run")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                signAndStoreCalls.withValue { $0 += 1 }
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(isNoteSplitNeededCalls.value == 0)
        #expect(submitNoteSplitCalls.value == 0)
        #expect(signAndStoreCalls.value == 1)
    }

    // MARK: - MOB-1496 (final engine, plural preps; coverage 2): immediate mode's Keystone fold

    /// Keystone twin — REPLACES the pre-final-engine `...NeverProposesNoteSplitPCZTEvenWhenSplitIs
    /// Needed` test, whose premise ("immediate mode's Keystone batch never carries a note-split
    /// entry") is now the very thing that's obsolete: the final engine's immediate flag only rewrites
    /// transfer heights, so `MigrationCommitPipeline.proposeKeystoneBatch` folds ANY preparation
    /// (note-split) PCZTs the engine proposes into the batch unconditionally, immediate mode
    /// included. This never consults `isNoteSplitNeeded` (that member is unrelated to the Keystone
    /// PCZT-propose path, in any mode) — it consults the new `proposeNoteSplitPCZTs` instead, and when
    /// that returns a real prep, it rides the batch prefixed ahead of the schedule's own PCZT.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountFoldsNoteSplitPrepIntoBatchWhenEngineProposesOne() async {
        let proposeNoteSplitPCZTsCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let schedulePczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        let expectedBatch = [
            MigrationUnsignedTransferPczt(id: MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p0", pczt: Data([0x02]))
        ] + schedulePczts
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in
                proposeNoteSplitPCZTsCalls.withValue { $0 += 1 }
                return [MigrationUnsignedTransferPczt(id: "p0", pczt: Data([0x02]))]
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in schedulePczts }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(expectedBatch)))

        #expect(proposeNoteSplitPCZTsCalls.value == 1)
    }

    /// Empty-preps twin: an immediate-mode Keystone batch whose engine reports NO preps needed folds
    /// down to exactly the schedule's own PCZTs — the unconditional fold is a true no-op, not a
    /// silent failure, when there is nothing to fold in.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountAndNoNoteSplitPrepsProposesScheduleOnlyBatch() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let schedulePczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 10) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in [] }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in schedulePczts }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(schedulePczts)))
    }

    /// The new throw site the unconditional fold introduces: a failed prep propose must surface as
    /// the same commit failure the schedule-propose throw site already does, never silently swallowed.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountWhenProposeNoteSplitPCZTsThrowsPresentsFailureSheetWithoutDelegating() async {
        struct ProposeFailure: Error { }
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 13) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in throw ProposeFailure() }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }

    // MARK: - MOB-1496 (R8-T1, S3): honest propose failures — no silent empty-schedule fallback

    @MainActor @Test func onAppearInImmediateModeWhenProposeThrowsPresentsFailureSheetLeavesScheduleNilAndConfirmSignsNothing() async {
        struct ProposeFailure: Error { }
        let signAndStoreCalls = LockIsolated<Int>(0)
        let state = MigrationReviewTransfer.State(mode: .immediate)
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in throw ProposeFailure() }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signAndStoreCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        #expect(store.state.schedule == nil)

        // Confirm must not proceed: no signAndStore reachable with a nil schedule. Tapping it also
        // dismisses the (already showing) failure affordance, same as any other confirm/retry tap.
        await store.send(.confirmTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }

        #expect(signAndStoreCalls.value == 0)
    }

    @MainActor @Test func retryTappedInImmediateModeAfterProposeFailureReProposesAndClearsFailureStateOnSuccess() async {
        struct ProposeFailure: Error { }
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let state = MigrationReviewTransfer.State(mode: .immediate)
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                let call = proposeCalls.withValue {
                    $0 += 1
                    return $0
                }
                if call == 1 {
                    throw ProposeFailure()
                }
                return schedule
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(\.transferProposed) {
            $0.amount = Zatoshi(1_245_800_000)
            $0.fee = Zatoshi(100_000)
            $0.schedule = schedule
        }

        #expect(proposeCalls.value == 2)
    }

    @MainActor @Test func confirmTappedInImmediateModeWithZeroTransferScheduleNeverSigns() async {
        let signAndStoreCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signAndStoreCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)

        #expect(signAndStoreCalls.value == 0)
    }

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountAndZeroTransferScheduleNeverDelegates() async {
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 10) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeCalls.withValue { $0 += 1 }
                return []
            }
        }

        await store.send(.confirmTapped)

        #expect(proposeCalls.value == 0)
    }

    // MARK: - A commit failure still presents the failure sheet
    //
    // S1 removed the split as a possible failure trigger in immediate mode;
    // `signAndStoreMigrationSchedule` failing is now the representative software-commit failure.

    @MainActor @Test func confirmTappedInImmediateModeWhenSignAndStoreThrowsPresentsFailureSheetAndNeverDelegatesConfirmed() async {
        struct SignFailure: Error { }
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
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in throw SignFailure() }
            // `MigrationCommitPipeline.commitSoftware` reads `migrationManager` as a plain
            // parameter even on this throwing path (never actually calls any of its members here,
            // but merely referencing the dependency still "accesses" it) — swift-dependencies gotcha,
            // see `MigrationManagerInterface.swift`'s `recordCommittedSchedule` doc: the client has
            // no `testValue`, so ANY uncustomized access fails whole-client; one override unlocks it.
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
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
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.isFailurePresented = true
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
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

    // MARK: - MOB-1496 (R8-T1, #4): Keystone propose failures surface instead of dead-ending
    //
    // Immediate mode's Keystone fork never consults `isNoteSplitNeeded` (unrelated to the PCZT
    // propose path). MOB-1496 (final engine): it DOES now consult `proposeNoteSplitPCZTs` — see the
    // dedicated throw-site test in the "immediate mode's Keystone fold" section above — so
    // `proposeMigrationPCZTs` below is the SECOND throw site in this fork, not the only one.

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountWhenProposeMigrationPCZTsThrowsPresentsFailureSheetWithoutDelegating() async {
        struct ProposeFailure: Error { }
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 11) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in throw ProposeFailure() }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountWhenPCZTBatchComesBackEmptyPresentsFailureSheetWithoutDelegating() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 12) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in [] }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }
}
