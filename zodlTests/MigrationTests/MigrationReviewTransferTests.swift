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
//  MOB-1458: `confirmTapped`/`retryTapped` now gate their entire commit body behind a device-
//  authentication (Face ID / Touch ID / passcode) prompt (`localAuthentication.authenticate()`).
//  Every pre-existing `confirmTapped`/`retryTapped` test below was updated to authenticate
//  successfully (`.mockAuthenticationSucceeded`) and receive the new `.confirmAuthenticated`
//  action before the assertions it already had — preserving each test's original intent. New
//  coverage below proves the outcomes the old tests couldn't: a refused/cancelled prompt
//  (`.authenticationCancelled`) builds nothing and re-enables Confirm; the single-flight guard
//  covers the authentication prompt itself, not just the PCZT build after it; a commit-failure
//  Retry authenticates again like a fresh `confirmTapped`; and the propose-failure Retry
//  short-circuit is the one path that stays unauthenticated, since it never signs or broadcasts.
//
//  MOB-1458 (round 2 — regression fix): a code review caught that the first version above still
//  decided what a tap commits to (`State.ConfirmIntent`, new) AFTER the authentication prompt
//  returned — re-reading `immediateProposal`/`selectedWalletAccount` from state inside
//  `confirmAuthenticated`, which now carries that decision as its payload instead. Most tests below
//  needed no behavioral changes for this: within one action's synchronous processing,
//  `isConfirming`/`failureReason` net out the same either way. The ones that don't:
//  `confirmTappedInImmediateModeBeforeProposalResolvesDoesNothing` and the Confirm half of
//  `onAppearInImmediateModeWhenProposeThrowsPresentsFailureSheetLeavesProposalNilAndConfirmDoesNothing`
//  now prove a full no-op with NO authentication prompt at all (previously they authenticated
//  first, then no-op'd on the far side); the two Retry-after-a-commit-failure tests now assert
//  `failureReason` clears in `confirmAuthenticated` rather than at the tap itself (F5: a declined
//  prompt must no longer erase the failure message — new coverage below proves it).
//  `retryTappedAfterProposeFailureNeverAuthenticates` is deleted as a strictly weaker duplicate of
//  `retryTappedInImmediateModeAfterProposeFailureReProposesAndClearsFailureStateOnSuccess`. New:
//  `mockAuthenticationBlocking`-driven regression pins for the exact reported bug (a tap with no
//  proposal is a complete no-op; a proposal that lands mid-prompt never swaps into the commit),
//  direct `confirmIntent` coverage for every mode/account combination, and the F5 decline test.
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
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))
    }

    @MainActor @Test func confirmTappedInManualStepModeDelegatesConfirmedDirectlyWithoutSigning() async {
        let store = TestStore(
            initialState: MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        ) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))
    }

    /// MOB-1513: `confirmTapped` before `onAppear`'s propose has ever resolved (or after it failed)
    /// must stay put rather than delegating with nothing to broadcast — the guard is keyed off
    /// `immediateProposal == nil`, replacing the deleted "zero-transfer schedule" guard (there is no
    /// "empty" `ImmediateMigrationProposal` — it either exists or it doesn't). MOB-1458 (round 2):
    /// that guard is `confirmIntent`, evaluated BEFORE authentication now — so this is a genuine
    /// no-op that never touches `localAuthentication` at all (previously it authenticated first and
    /// only discovered afterward that there was nothing to confirm).
    @MainActor @Test func confirmTappedInImmediateModeBeforeProposalResolvesDoesNothing() async {
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        }
        // `localAuthentication` is intentionally left unimplemented: with no proposal,
        // `confirmIntent` is `nil` and the tap must return before ever reaching the authentication
        // prompt — a call to `authenticate()` here would fail this test.

        await store.send(.confirmTapped)
    }

    // MARK: - MOB-1468 / MOB-1513: Keystone confirmTapped fork proposes an ordinary PCZT

    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountProposesPCZTRedactsAndDelegatesImmediateSignRequested() async {
        let createPCZTCalls = LockIsolated<[(AccountUUID, Proposal)]>([])
        let redactCalls = LockIsolated<[Data]>([])
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let pcztBytes = Data([0xAA, 0xBB])
        let redactedBytes = Data([0xAA, 0xBB, 0x0F])
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
            $0.sdkSynchronizer.redactPCZTForSigner = { pczt in
                redactCalls.withValue { $0.append(pczt) }
                return redactedBytes
            }
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        await store.receive(
            .delegate(
                .keystoneImmediateSignRequested(unsigned: pcztBytes, redacted: redactedBytes)
            )
        ) {
            $0.isConfirming = false
        }

        #expect(createPCZTCalls.value.count == 1)
        #expect(createPCZTCalls.value.first?.0 == state.selectedWalletAccount?.id)
        #expect(createPCZTCalls.value.first?.1 == proposal.proposal)
        // MOB-1513 (R8): the redaction runs over the just-built ORIGINAL — the wire copy the device
        // scans; the unsigned original still rides the delegate for the post-scan proofs+combine.
        #expect(redactCalls.value == [pcztBytes])
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
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
        }
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
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
        }
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
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }

    /// MOB-1513 (R8): the redaction the single-PCZT reroute adds is a second throw site on the same
    /// leg — it must surface exactly like a `createPCZTFromProposal` throw (commit-failure sheet,
    /// nothing delegated), never silently swallowed.
    @MainActor @Test func confirmTappedInImmediateModeWithKeystoneAccountWhenRedactPCZTForSignerThrowsPresentsFailureSheetWithoutDelegating() async {
        struct RedactFailure: Error { }
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 15) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in Data([0xAA]) }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in throw RedactFailure() }
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
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
            // MOB-1458 (round 2): `localAuthentication` is intentionally left unimplemented — with
            // no proposal, `confirmIntent` is `nil` and the tap below must return before ever
            // reaching the authentication prompt. A call to `authenticate()` here would fail this
            // test.
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        #expect(store.state.immediateProposal == nil)

        // MOB-1458 (round 2): Confirm must not proceed — no proposal means `confirmIntent` is
        // `nil`, so the tap returns before setting `isConfirming` or opening the authentication
        // prompt. MOB-1458 (code review): the tap dismisses the (already showing) failure
        // affordance first, same as any other confirm/retry tap — that step is unconditional,
        // ahead of the intent check — but the nil-intent branch immediately restores it, since
        // nothing ran to address the failure it was showing. Net effect is a COMPLETE no-op: no
        // trailing mutation closure below, so `TestStore` asserts state is byte-for-byte
        // unchanged, `failureReason` included (F5: cleared only on a successful commit). Before
        // the code-review fix this assertion read `$0.isFailurePresented = false` — encoding the
        // bug (the sheet staying dismissed with `failureReason` still set and nothing to show it).
        await store.send(.confirmTapped)

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureReason == MigrationReviewTransfer.State.FailureReason.propose)
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
            // MOB-1458: `localAuthentication` is intentionally left unimplemented — this also pins
            // that a propose-failure Retry never authenticates (a call to `authenticate()` here
            // would fail this test).
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(\.transferProposed) {
            $0.isConfirming = false
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
        let redactedBytes = Data([0xCC, 0x0F])
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
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redactedBytes }
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
            // MOB-1458 (round 2 / F5): `failureReason` is no longer cleared here — only on a
            // successful commit, in `.confirmAuthenticated` below — so a decline would still have
            // the message to restore.
        }
        await store.receive(\.confirmAuthenticated) {
            $0.failureReason = nil
        }
        await store.receive(
            .delegate(
                .keystoneImmediateSignRequested(unsigned: pcztBytes, redacted: redactedBytes)
            )
        ) {
            $0.isConfirming = false
        }

        #expect(proposeCalls.value == 0)
        #expect(createPCZTCalls.value == 1)
    }

    // MARK: - MOB-1513 (B4): confirm loading + single-flight (Keystone propose leg)

    /// Same treatment as `MigrationTransferPlan`'s confirm (B4): the Keystone fork's PCZT build is
    /// async, so Confirm shows a loader (`isConfirming`) and a second tap while it's in flight is a
    /// complete no-op; the flag clears once the batch is handed to the coordinator so a later
    /// pop-back (rejected signature) re-enables Confirm. MOB-1458: the software/manual-step confirms
    /// now set the flag too, for the device-authentication window that precedes them — they are no
    /// longer synchronous from the user's perspective, even though neither has a local commit step
    /// of its own once authentication succeeds.
    @MainActor @Test func confirmTappedKeystoneSetsIsConfirmingAndIgnoresSecondTapWhilePcztBuildInFlight() async {
        let createPCZTCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let pcztBytes = Data([0xAB])
        let redactedBytes = Data([0xAB, 0x0F])
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = proposal
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 21) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                for await _ in releaseStream { break }
                return pcztBytes
            }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redactedBytes }
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        // Second tap while the PCZT build is in flight: a complete no-op.
        await store.send(.confirmTapped)

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(
            .delegate(
                .keystoneImmediateSignRequested(unsigned: pcztBytes, redacted: redactedBytes)
            )
        ) {
            $0.isConfirming = false
        }

        #expect(createPCZTCalls.value == 1)
    }

    /// A failed PCZT build must clear the loading flag alongside presenting the failure sheet, so
    /// Retry is tappable again.
    @MainActor @Test func confirmTappedKeystonePcztBuildFailureClearsIsConfirming() async {
        struct PcztFailure: Error { }
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = proposal
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 22) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in throw PcztFailure() }
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        }
    }

    // MARK: - MOB-1458: device-authentication gate (Face ID / Touch ID / passcode)

    /// MOB-1458: a refused/cancelled device-authentication prompt gates the ENTIRE commit body —
    /// no delegate fires, no PCZT is built, and `isConfirming` returns to `false` so Confirm is
    /// tappable again. Uses a Keystone account so "no PCZT is built" is a meaningful assertion
    /// (the software lane never builds one either way).
    @MainActor @Test func confirmTappedWhenAuthenticationFailsBuildsNoPcztAndEmitsNoDelegate() async {
        let createPCZTCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 30) }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return Data()
            }
            $0.localAuthentication = .mockAuthenticationFailed
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.authenticationCancelled) {
            $0.isConfirming = false
        }

        #expect(createPCZTCalls.value == 0)
    }

    /// MOB-1458: single-flight covers the AUTHENTICATION leg itself, not just the PCZT build that
    /// can follow it — a second tap while the Face ID / Touch ID / passcode prompt is still up
    /// must be a complete no-op, same as any other in-flight confirm leg.
    @MainActor @Test func confirmTappedIgnoresSecondTapWhileAuthenticationInFlight() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.localAuthentication = .mockAuthenticationBlocking(authenticateCalls, releaseStream: releaseStream)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        // Second tap while the authentication prompt is still up: a complete no-op.
        await store.send(.confirmTapped)

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))

        #expect(authenticateCalls.value == 1)
    }

    /// MOB-1458: a commit-failure Retry (`failureReason == .commit`) re-attempts the FULL gated
    /// commit, including a fresh device-authentication prompt — unlike the propose-failure Retry
    /// short-circuit below, which never authenticates. Counts `authenticate()` calls directly
    /// (rather than only relying on `.confirmAuthenticated` arriving) to make the "authenticates
    /// again" claim explicit.
    @MainActor @Test func retryTappedAfterCommitFailureAuthenticatesAgain() async {
        let authenticateCalls = LockIsolated<Int>(0)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.isFailurePresented = true
        state.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.localAuthentication = .mockAuthenticationCounting(authenticateCalls)
        }

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
            // MOB-1458 (round 2 / F5): `failureReason` survives the tap itself — cleared only on
            // success, below.
        }
        await store.receive(\.confirmAuthenticated) {
            $0.isConfirming = false
            $0.failureReason = nil
        }
        await store.receive(.delegate(.confirmed))

        #expect(authenticateCalls.value == 1)
    }

    /// MOB-1458 (F5): declining the re-authentication prompt on a commit-failure Retry must not
    /// erase the failure message — the sheet is its only surface, and `.retryTapped`/
    /// `.authenticationCancelled` no longer touch `failureReason` except to restore
    /// `isFailurePresented` from it.
    @MainActor @Test func retryTappedAfterCommitFailureThenDecliningAuthenticationRestoresFailureSheet() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.isFailurePresented = true
        state.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.localAuthentication = .mockAuthenticationFailed
        }

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
        }
        await store.receive(\.authenticationCancelled) {
            $0.isConfirming = false
            $0.isFailurePresented = true
        }

        #expect(store.state.failureReason == MigrationReviewTransfer.State.FailureReason.commit)
    }

    // MARK: - MOB-1458 (round 2): confirmIntent — decided synchronously, never re-read post-prompt

    @MainActor @Test func confirmIntentInManualStepModeIsManualStepRegardlessOfProposalOrAccount() async {
        var state = MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5))
        state.$selectedWalletAccount.withLock { $0 = nil }

        #expect(state.confirmIntent == MigrationReviewTransfer.State.ConfirmIntent.manualStep)
    }

    @MainActor @Test func confirmIntentInImmediateModeWithSoftwareAccountIsImmediateSoftware() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 50) }

        #expect(state.confirmIntent == MigrationReviewTransfer.State.ConfirmIntent.immediateSoftware)
    }

    @MainActor @Test func confirmIntentInImmediateModeWithKeystoneAccountIsImmediateKeystoneCarryingProposalAndAccount() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let account = walletAccount(keystone: true, idByte: 51)
        state.immediateProposal = proposal
        state.$selectedWalletAccount.withLock { $0 = account }

        #expect(
            state.confirmIntent == MigrationReviewTransfer.State.ConfirmIntent.immediateKeystone(proposal: proposal, account: account)
        )
    }

    /// The `onAppear` cache guard's `nil` state (propose still in flight, or never attempted) must
    /// also read as "nothing to commit" here — `confirmIntent` is the ONE place both `onAppear` and
    /// `confirmTapped` agree a proposal is or isn't ready.
    @MainActor @Test func confirmIntentInImmediateModeWithNoProposalIsNil() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 52) }

        #expect(state.confirmIntent == nil)
    }

    @MainActor @Test func confirmIntentInImmediateModeWithNoSelectedAccountIsNil() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.$selectedWalletAccount.withLock { $0 = nil }

        #expect(state.confirmIntent == nil)
    }

    // MARK: - MOB-1458 (round 2): regression pins — the exact bug the code review caught

    /// THE regression pin. Before this fix, a tap with no proposal yet still authenticated
    /// (`confirmAuthenticated`'s guards ran AFTER the prompt) — only to discover, on the far side of
    /// the prompt, that there was nothing to confirm. Now `confirmIntent` is computed BEFORE the
    /// prompt opens, so a tap with nothing to commit never reaches `authenticate()` at all. Uses
    /// `mockAuthenticationBlocking` (rather than leaving the dependency unimplemented) so the
    /// zero-calls claim is an explicit, counted assertion rather than an incidental test failure.
    @MainActor @Test func confirmTappedWithNoProposalIsACompleteNoOpAndNeverAuthenticates() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let (releaseStream, _) = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationBlocking(authenticateCalls, releaseStream: releaseStream)
        }

        // A COMPLETE no-op: no trailing mutation closure means TestStore asserts state is
        // byte-for-byte unchanged, and no `.receive` below means no action may be emitted either.
        await store.send(.confirmTapped)

        #expect(store.state.isConfirming == false)
        #expect(authenticateCalls.value == 0)
    }

    /// The companion regression pin: the "phantom proposal" shape of the same bug. `onAppear`'s
    /// bounded propose-retry loop keeps running underneath an open authentication prompt — nothing
    /// cancels it on `confirmTapped` — so a DIFFERENT proposal than the one on screen at tap time
    /// can land while the prompt is still up. Before this fix, `confirmAuthenticated` re-read
    /// `immediateProposal` from state and would silently commit the late arrival instead — a spend
    /// the user never reviewed. Now the proposal is captured in `ConfirmIntent` at tap time and
    /// carried through unchanged, regardless of what lands in state afterward.
    ///
    /// Asserted via an EXACT `.confirmAuthenticated` action match (not by inspecting what reaches
    /// `createPCZTFromProposal`): `Proposal.testOnlyFakeProposal(totalFee:)`'s `totalFee` doesn't
    /// actually reach the underlying `FfiProposal` it wraps (a no-op assignment to a local that's
    /// then discarded), so two fixtures' `.proposal` values compare equal regardless of `totalFee`
    /// — only comparing the whole `ImmediateMigrationProposal` (`amount`/`fee` included) actually
    /// distinguishes `tapTimeProposal` from `lateArrivalProposal` below.
    @MainActor @Test func confirmTappedCommitsTheProposalCapturedAtTapTimeNotOneThatArrivesMidPrompt() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let createPCZTCalls = LockIsolated<Int>(0)
        let tapTimeProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let lateArrivalProposal = immediateProposal(amount: Zatoshi(999_999_999), fee: Zatoshi(20_000))
        let account = walletAccount(keystone: true, idByte: 53)
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = tapTimeProposal
        state.$selectedWalletAccount.withLock { $0 = account }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return Data([0xEE])
            }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in Data([0xEE, 0x0F]) }
            $0.localAuthentication = .mockAuthenticationBlocking(authenticateCalls, releaseStream: releaseStream)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }

        // The late arrival lands WHILE the authentication prompt is still up — simulating what
        // `onAppear`'s retry loop can do underneath an open prompt.
        await store.send(.transferProposed(lateArrivalProposal)) {
            $0.isConfirming = false
            $0.amount = lateArrivalProposal.amount
            $0.fee = lateArrivalProposal.fee
            $0.immediateProposal = lateArrivalProposal
        }

        releaseContinuation.yield()
        releaseContinuation.finish()

        // THE assertion: the delivered action carries the intent captured AT TAP TIME
        // (`tapTimeProposal`) — not whatever `state.immediateProposal` was swapped to above.
        await store.receive(
            .confirmAuthenticated(
                MigrationReviewTransfer.State.ConfirmIntent.immediateKeystone(proposal: tapTimeProposal, account: account)
            )
        ) {
            $0.isConfirming = true
        }
        await store.receive(
            .delegate(
                .keystoneImmediateSignRequested(unsigned: Data([0xEE]), redacted: Data([0xEE, 0x0F]))
            )
        ) {
            $0.isConfirming = false
        }

        #expect(createPCZTCalls.value == 1)
        #expect(authenticateCalls.value == 1)
    }

    // MARK: - MOB-1458 (code review): two more early exits that dismissed the failure sheet and
    // never restored it — missed by the round-2 fix above, which only closed the
    // authentication-cancel/success gap.

    /// THE Fix 1 regression pin. A commit-failure sheet is up (`failureReason == .commit`) and the
    /// account backing `confirmIntent` goes `nil` — in practice `selectedWalletAccount` clearing
    /// under an open flow — before Retry is tapped. Before this fix, the nil-`confirmIntent` no-op
    /// left `isFailurePresented` at the `false` the top of the case had just set, dismissing the
    /// sheet with `failureReason` still set and nothing left on screen to show it.
    /// `localAuthentication` is intentionally left unimplemented: with `confirmIntent` nil, the
    /// tap must return before ever reaching the authentication prompt — a call to `authenticate()`
    /// here would fail this test. The happy-path counterpart (a non-nil intent still dismisses the
    /// sheet and proceeds) is already covered by `retryTappedAfterCommitFailureAuthenticatesAgain`
    /// above — not duplicated here.
    @MainActor @Test func retryTappedWithNilConfirmIntentRestoresTheCommitFailureSheetItDismissed() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.immediateProposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        state.isFailurePresented = true
        state.failureReason = MigrationReviewTransfer.State.FailureReason.commit
        // The reachable trigger this pins: the account backing `confirmIntent` disappears out from
        // under an open commit-failure sheet.
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        }

        // A COMPLETE no-op: `isFailurePresented` dips to `false` at the top of the case and is
        // restored before the reducer returns, so the net state is unchanged — no trailing
        // mutation closure needed.
        await store.send(.retryTapped)

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureReason == MigrationReviewTransfer.State.FailureReason.commit)
        #expect(store.state.isConfirming == false)
    }

    /// THE Fix 2 regression pin. A propose-failure sheet is up (`failureReason == .propose`) and no
    /// account is selected when Retry is tapped. Before this fix, `failureReason` cleared BEFORE
    /// the account guard ran, so a nil account dismissed the "couldn't load your plan" sheet,
    /// wiped its reason, and launched no re-propose — leaving the user on a screen with no surface
    /// for the error. `localAuthentication` is intentionally left unimplemented: the propose-retry
    /// short-circuit never authenticates on any path, so a call to `authenticate()` here would
    /// fail this test regardless of which bug it caught. The happy-path counterpart (a propose-
    /// Retry with a valid account still clears `failureReason` and launches the propose) is already
    /// covered by `retryTappedInImmediateModeAfterProposeFailureReProposesAndClearsFailureStateOnSuccess`
    /// above — not duplicated here.
    @MainActor @Test func retryTappedAfterProposeFailureWithNoSelectedAccountRestoresFailureSheetWithoutReProposing() async {
        var state = MigrationReviewTransfer.State(mode: .immediate)
        state.isFailurePresented = true
        state.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) {
            MigrationReviewTransfer()
        }

        // A COMPLETE no-op, same shape as the Fix 1 pin above.
        await store.send(.retryTapped)

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureReason == MigrationReviewTransfer.State.FailureReason.propose)
        #expect(store.state.isConfirming == false)
    }

    // MARK: - MOB-1513 (E2-FIX): bounded quiet retry at entry when the wallet isn't ready yet

    /// E2 window: right after a restore the send-max builder can't select any spendable Orchard
    /// notes yet, so `proposeImmediateMigration` throws `ZcashError.rustProposeSendMaxTransfer` (the
    /// typed "no migratable funds yet" surface). Instead of surfacing the failure sheet immediately
    /// (today's behavior), the entry propose stays quietly in its loading state and re-proposes on
    /// the clock, only surfacing the EXISTING propose-failure sheet once the bounded window expires.
    @MainActor @Test func onAppearImmediateWhenNoSpendableNotesRetriesQuietlyThenSurfacesOnExpiry() async {
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                throw ZcashError.rustProposeSendMaxTransfer("Error while sending funds: insufficient funds")
            }
        }

        await store.send(.onAppear)
        // Quiet: the failure sheet must NOT appear on the first not-ready outcome (today it would).
        #expect(store.state.isFailurePresented == false)

        await clock.advance(by: .seconds(3))
        #expect(store.state.isFailurePresented == false)

        // Past the bounded window: the existing propose-failure sheet finally surfaces.
        await clock.advance(by: .seconds(120))
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        // Multiple attempts happened — not a single immediate surface.
        #expect(proposeCalls.value >= 2)
    }

    /// A later attempt within the window succeeds → the proposal is applied and the flow proceeds
    /// exactly as a first-attempt success would, with no failure sheet ever shown.
    @MainActor @Test func onAppearImmediateWhenNotReadyThenBecomesAvailableProposesOnLaterAttempt() async {
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let proposal = immediateProposal(amount: Zatoshi(1_245_800_000), fee: Zatoshi(15_000))
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                let call = proposeCalls.withValue {
                    $0 += 1
                    return $0
                }
                if call < 3 {
                    throw ZcashError.rustProposeSendMaxTransfer("not ready yet")
                }
                return proposal
            }
        }

        await store.send(.onAppear)
        #expect(store.state.isFailurePresented == false)

        await clock.advance(by: .seconds(3))
        await clock.advance(by: .seconds(3))
        await store.receive(\.transferProposed) {
            $0.amount = Zatoshi(1_245_800_000)
            $0.fee = Zatoshi(15_000)
            $0.immediateProposal = proposal
        }

        #expect(store.state.isFailurePresented == false)
        #expect(proposeCalls.value == 3)
    }

    /// Conservative classification: a propose failure that is NOT the typed not-ready surface (any
    /// other error) is a genuine failure — it surfaces immediately through the existing error path,
    /// with zero retries.
    @MainActor @Test func onAppearImmediateWhenProposeThrowsNonWindowErrorSurfacesImmediatelyWithoutRetrying() async {
        struct HardFailure: Error { }
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationReviewTransfer.State(mode: .immediate)) {
            MigrationReviewTransfer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                throw HardFailure()
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationReviewTransfer.State.FailureReason.propose
        }

        #expect(proposeCalls.value == 1)
    }
}
