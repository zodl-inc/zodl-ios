//
//  MigrationReviewTransferTests.swift
//  zodlTests
//
//  Covers the MigrationReviewTransfer reducer
//  (Features/Migration/MigrationReviewTransfer/MigrationReviewTransferStore.swift) for MOB-1463/1466:
//  the default `mode`, and (MOB-1466) two divergent `onAppear`/`confirmTapped` paths keyed off
//  `mode` — immediate proposes its own `ImmediateMigrationProposal` via `proposeImmediateMigration()`
//  for Amount/Fee; manual step has its data injected by the coordinator (no propose) and confirm
//  delegates directly (the transfer was already signed at plan commit). Also covers the
//  `isFlowRoot`-gated back control for the manual-step variant: a new `Delegate.closed` case (reusing
//  `.confirmed` for a back-tap would be a correctness bug — that case means "user confirmed the
//  transfer", not "user backed out"). Also covers MOB-1468's Keystone fork: a Keystone-vendor account
//  in immediate mode proposes the proposal's PCZT via `createPCZTFromProposal` and delegates
//  `.keystoneSignRequested` instead of signing locally; the manual-step path never forks, even for a
//  Keystone account (those transfers were already signed at plan commit). `.serialized`: several
//  cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//
//  MOB-1513 (Lane A2 — send-max immediate migration): rewritten wholesale for the real SDK's send-max
//  surface. `proposeImmediateMigration` now returns `ImmediateMigrationProposal` (not
//  `MigrationSchedule`), and immediate mode's SOFTWARE confirm has NO local commit step left at all —
//  the actual create+sign+submit moved to `MigrationSendingStore` (covered there). This file's
//  `confirmTapped` coverage for the software lane now only proves the delegate fires with nothing
//  else touched; the Keystone fork proposes via `createPCZTFromProposal` (an ordinary, engine-external
//  PCZT builder) instead of the deleted schedule-based `proposeMigrationPCZTs`. The old
//  "zero-transfer schedule never signs" tests have no equivalent under the new surface (a proposal
//  either exists or it doesn't — there is no "empty" variant) and are replaced by a
//  proposal-not-yet-fetched guard test. The old "note-split PCZT folds into an immediate Keystone
//  batch" tests are gone too — a single ordinary-send PCZT has no note-split concept at all.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationReviewTransferTests {
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

    /// MOB-1513: a fixture `ImmediateMigrationProposal` — `.testOnlyFakeProposal` stands in for the
    /// real `FfiProposal`-backed `Proposal` (there is no public way to construct one directly in
    /// tests), matching the same fixture idiom `SDKSynchronizerTest.swift`'s own placeholders use.
    private func immediateProposal(amount: Zatoshi, fee: Zatoshi) -> ImmediateMigrationProposal {
        ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: UInt64(fee.amount)), amount: amount, fee: fee)
    }

    @MainActor @Test func defaultStateIsImmediateModeWithZeroAmounts() async {
        let state = MigrationReviewTransfer.State()

        #expect(state.mode == MigrationReviewTransfer.State.Mode.immediate)
        #expect(state.amount == Zatoshi.zero)
        #expect(state.fee == Zatoshi.zero)
        #expect(state.immediateProposal == nil)
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

    // MARK: - Immediate mode: onAppear proposes for Amount/Fee (MOB-1513: cache-guarded)

    @MainActor @Test func onAppearInImmediateModeProposesSendMaxProposalForAmountFee() async {
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposed) {
            $0.amount = Zatoshi(1_245_800_000)
            $0.fee = Zatoshi(15_000)
            $0.immediateProposal = proposal
        }
    }

    /// MOB-1513: the cache guard mirroring `MigrationTransferPlanStore.onAppear`'s injected-schedule/
    /// hydrated-rows pattern — a re-appearance (e.g. after backgrounding) with an already-populated
    /// `immediateProposal` must never re-propose.
    @MainActor @Test func onAppearInImmediateModeWhenAlreadyPopulatedNeverReProposes() async {
        let proposeCalls = LockIsolated<Int>(0)
        let existingProposal = immediateProposal(amount: Zatoshi(500_000_000), fee: Zatoshi(10_000))
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = existingProposal
        state.amount = existingProposal.amount
        state.fee = existingProposal.fee
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                return existingProposal
            }
        }

        await store.send(.onAppear)

        #expect(proposeCalls.value == 0)
        #expect(store.state.immediateProposal == existingProposal)
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
                return self.immediateProposal(amount: Zatoshi.zero, fee: Zatoshi.zero)
            }
        }

        await store.send(.onAppear)

        #expect(proposeCalls.value == 0)
        #expect(store.state.amount == Zatoshi(243_100_000))
        #expect(store.state.immediateProposal == nil)
    }

    // MARK: - Immediate mode, software account: confirm has nothing left to commit locally

    /// MOB-1513: the actual create+sign+submit moved to `MigrationSendingStore` (covered there) — the
    /// Review screen's software confirm is now a bare delegate, so this proves NOTHING on
    /// `sdkSynchronizer` is touched at all.
    @MainActor @Test func confirmTappedInImmediateModeWithSoftwareAccountDelegatesConfirmedWithoutTouchingSDK() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))
    }

    @MainActor @Test func confirmTappedInManualStepModeDelegatesConfirmedDirectlyWithoutSigning() async {
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        ) {
            MigrationReviewTransfer()
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))
    }

    /// MOB-1513: `confirmTapped` before `onAppear`'s propose has ever resolved (or after it failed)
    /// must stay put rather than delegating with nothing to broadcast — the guard is keyed off
    /// `immediateProposal == nil`, replacing the deleted "zero-transfer schedule" guard (there is no
    /// "empty" `ImmediateMigrationProposal` — it either exists or it doesn't).
    @MainActor @Test func confirmTappedInImmediateModeBeforeProposalResolvesDoesNothing() async {
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        }

        await store.send(.confirmTapped)
    }

    // MARK: - MOB-1468 / MOB-1513: Keystone confirmTapped fork proposes an ordinary PCZT

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountProposesPCZTAndDelegatesKeystoneSignRequested() async {
        let createPCZTCalls = LockIsolated<[(AccountUUID, Proposal)]>([])
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let pcztBytes = Data([0xAA, 0xBB])
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = proposal
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 1) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { accountUUID, proposedProposal in
                createPCZTCalls.withValue { $0.append((accountUUID, proposedProposal)) }
                return pcztBytes
            }
        }

        await store.send(.confirmTapped)
        await store.receive(
            .delegate(
                .keystoneSignRequested([MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: pcztBytes)])
            )
        )

        #expect(createPCZTCalls.value.count == 1)
        #expect(createPCZTCalls.value.first?.0 == state.selectedWalletAccount?.id)
        #expect(createPCZTCalls.value.first?.1 == proposal.proposal)
    }

    @MainActor @Test func confirmTappedInImmediateModeWithZcashAccountUsesSoftwarePathUnchanged() async {
        let createPCZTCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 2) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return Data()
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(createPCZTCalls.value == 0)
    }

    @MainActor @Test func confirmTappedInManualStepModeWithKeystoneAccountNeverForksAndDelegatesConfirmedDirectly() async {
        let createPCZTCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 3) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return Data()
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(createPCZTCalls.value == 0)
    }

    /// MOB-1513: the new throw site the ordinary PCZT builder introduces — must surface as the same
    /// commit failure the propose throw site already does, never silently swallowed.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountWhenCreatePCZTFromProposalThrowsPresentsFailureSheetWithoutDelegating() async {
        struct CreatePCZTFailure: Error { }
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 13) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in throw CreatePCZTFailure() }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }

    // MARK: - MOB-1496 (R8-T1, S3) / MOB-1513: honest propose failures — no silent fallback

    @MainActor @Test func onAppearInImmediateModeWhenProposeThrowsPresentsFailureSheetLeavesProposalNilAndConfirmDoesNothing() async {
        struct ProposeFailure: Error { }
        let state = MigrationReviewTransfer.State(mode: .immediate)
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in throw ProposeFailure() }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        #expect(store.state.immediateProposal == nil)

        // Confirm must not proceed: no proposal to broadcast. Tapping it also dismisses the
        // (already showing) failure affordance, same as any other confirm/retry tap.
        await store.send(.confirmTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
    }

    @MainActor @Test func retryTappedInImmediateModeAfterProposeFailureReProposesAndClearsFailureStateOnSuccess() async {
        struct ProposeFailure: Error { }
        let proposeCalls = LockIsolated<Int>(0)
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
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
                return proposal
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
            $0.fee = Zatoshi(15_000)
            $0.immediateProposal = proposal
        }

        #expect(proposeCalls.value == 2)
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

    /// MOB-1513: a `.commit`-reason retry (only reachable via the Keystone fork now — software has
    /// no commit step left to fail at Review-confirm time) re-attempts with the SAME already-fetched
    /// proposal — no re-propose, matching the contract's "no plan-cache staleness" guarantee for the
    /// engine-external `ImmediateMigrationProposal`.
    @MainActor @Test func retryTappedInImmediateModeWithKeystoneAccountAfterCommitFailureReattemptsWithSameProposalWithoutReProposing() async {
        let proposeCalls = LockIsolated<Int>(0)
        let createPCZTCalls = LockIsolated<Int>(0)
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let pcztBytes = Data([0xCC])
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = proposal
        state.isFailurePresented = true
        state.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 14) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                return proposal
            }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return pcztBytes
            }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(
            .delegate(
                .keystoneSignRequested([MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: pcztBytes)])
            )
        )

        #expect(proposeCalls.value == 0)
        #expect(createPCZTCalls.value == 1)
    }
}
