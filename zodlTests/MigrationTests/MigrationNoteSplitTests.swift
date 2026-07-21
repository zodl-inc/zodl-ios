//
//  MigrationNoteSplitTests.swift
//  zodlTests
//
//  Covers the MigrationNoteSplit reducer
//  (Features/Migration/MigrationNoteSplit/MigrationNoteSplitStore.swift) for MOB-1461/1466 —
//  MOB-1478 (W4) reshaped this to re-entry-only (no more `.explainer` phase): the default
//  `.splitting` phase/state, the txid pasteboard copy, the failure sheet dismissal (cancel/retry),
//  the `continueTapped`/`closeTapped` delegate contract (both close the flow via the coordinator's
//  `isFlowRoot` check — re-entry is always the flow root now, across both phases), `onAppear`
//  subscribing to `migrationManager.stateEvents()` (with a defensive jump straight to `.confirmed`
//  if the split already finished before this screen mounted), and retry re-submission. Also covers
//  MOB-1468's Keystone note-split retry fork: `retryTapped` re-broadcasts a coordinator-set
//  `signedNoteSplitPczt` rather than re-submitting the proposal. MOB-1496 (C-1 fix, final review R6):
//  this fork is now store-aware — `storeSignedNoteSplits` runs only when `splitStored` is still
//  `false`, then `broadcastStoredNoteSplit` always runs; `splitStored` is what the deleted
//  `submitSignedNoteSplit` composite lacked any memory of, which is what made its own retry loop
//  forever after a successful store.
//  MOB-1496: the software-signing/resubmission paths now hit the real per-account SDK surface
//  (`AccountUUID` + a derived `UnifiedSpendingKey` + `migrationManager.migrationNetworkOptions(_:)`).
//  `.serialized`: several cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`,
//  and the copy action writes the shared toast.
//  MOB-1496 (final engine, plural preps): `signedNoteSplitPczt` is `[MigrationSignedTransferPczt]?`
//  now (was a single `Data?`) — the final engine builds N preparation transactions, not one split
//  transaction. Fixtures below use a 1-element array (`[MigrationSignedTransferPczt(id: "p0", ...)]`)
//  throughout, since this screen is only ever pushed with a non-empty prep batch in practice.
//

import Testing
import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationNoteSplitTests {
    /// MOB-1496: `migrationManager.migrationNetworkOptions(_:)` has no macro default (unlike the SDK
    /// synchronizer's `.noOp`), so any test reaching `submitNoteSplit`/`resubmitSignedNoteSplit`
    /// must mock it explicitly or trip `unimplemented`.
    private static let defaultNetworkPrivacyOptions = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )

    /// MOB-1496: mirrors `MigrationTransferPlanTests`' setup hook — every test gets a selected
    /// software account by default; the default-state test overrides its own assertion instead
    /// (see its comment).
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

    @MainActor @Test func defaultStateIsSplittingWithNoFailureSheet() async {
        let state = MigrationNoteSplit.State()

        #expect(state.phase == MigrationNoteSplit.State.Phase.splitting)
        #expect(state.amount == Zatoshi.zero)
        #expect(state.fee == Zatoshi.zero)
        #expect(state.txId == "")
        #expect(state.isFailurePresented == false)
        #expect(state.isFlowRoot == false)
        #expect(state.signedNoteSplitPczt == nil)
        #expect(state.splitStored == false)
        // Not asserting `selectedWalletAccount == nil`: MOB-1496's `init()` above seeds a default
        // selected account for every test in this suite — see `MigrationTransferPlanTests`' twin
        // assertion for the rationale.
    }

    @MainActor @Test func closeTappedWhenFlowRootEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting, isFlowRoot: true)) {
            MigrationNoteSplit()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func copyTxIdTappedCopiesTxIdToPasteboard() async {
        let copied = LockIsolated<RedactableString?>(nil)
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, txId: "e87f1234567890abcdef6f28b")
        ) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.pasteboard.setString = { copied.setValue($0) }
        }
        store.exhaustivity = .off

        await store.send(.copyTxIdTapped)

        #expect(copied.value == "e87f1234567890abcdef6f28b".redacted)
        #expect(store.state.toast == .top(String(localizable: .generalCopiedToTheClipboard)))
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        ) {
            MigrationNoteSplit()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func continueTappedEmitsDelegateContinued() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .confirmed)) {
            MigrationNoteSplit()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.continued))
    }

    // MARK: - MOB-1478 (W4): confirmed-at-root emits the same delegate closeTapped does

    @MainActor @Test func continueTappedWhenConfirmedAndFlowRootEmitsDelegateContinued() async {
        // Re-entry always lands `.confirmed` at flow root eventually (the commit already happened
        // before the split started) — the coordinator interprets this SAME `.continued` delegate as
        // "close the flow" whenever `isFlowRoot`, exactly like `closeTapped`'s splitting-phase shape
        // (coordinator-level wiring covered in `MigrationCoordFlowTests`).
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .confirmed, isFlowRoot: true)) {
            MigrationNoteSplit()
        }

        await store.send(.continueTapped)
        await store.receive(.delegate(.continued))
    }

    @MainActor @Test func splitConfirmedSetsConfirmedPhase() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitConfirmed) {
            $0.phase = .confirmed
        }
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        }

        await store.send(.delegate(.continued))
    }

    // MARK: - onAppear: resume/observe only (MOB-1478 W4 — no more fresh-prepare branch)

    @MainActor @Test func onAppearWhilePendingConfirmationStaysInSplittingPhaseAndSubscribesToStream() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { _ in .splitPendingConfirmation }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
        }

        // No prepare/submit call is made any more — the split already started elsewhere (under the
        // TransferPlan/ReviewTransfer commit CTA); this screen only observes it. Phase stays at its
        // default `.splitting` — no diff to describe.
        await store.send(.onAppear)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func onAppearWhenAlreadyReadyToProposeJumpsToConfirmedPhase() async {
        // Defensive: the split may have already reached `.readyToPropose` between the banner's
        // `reentryRoute()` snapshot and this screen mounting — onAppear jumps straight to
        // `.confirmed` rather than waiting on a stream event that already fired.
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { _ in .readyToPropose }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
        }

        // `.onAppear` itself mutates no state — the jump-to-confirmed check runs inside its `.run`
        // effect and arrives asynchronously as a separate `.splitConfirmed` action.
        await store.send(.onAppear)
        await store.receive(\.splitConfirmed) {
            $0.phase = .confirmed
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func migrationStateStreamReadyToProposeAfterSplittingEmitsSplitConfirmed() async {
        let stateStream = PassthroughSubject<MigrationState, Never>()
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { _ in .splitPendingConfirmation }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
        }

        await store.send(.onAppear)

        stateStream.send(.readyToPropose)
        await store.receive(\.splitConfirmed) {
            $0.phase = .confirmed
        }

        stateStream.send(completion: .finished)
        await store.finish()
    }

    @MainActor @Test func onAppearWithNoSelectedAccountSkipsOneShotCheckButStillSubscribes() async {
        // No account -> the one-shot `getMigrationState` guard short-circuits, but the stream
        // subscription is unconditional (the manager resolves a nil accountUUID internally).
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        let stateStream = PassthroughSubject<MigrationState, Never>()
        let getMigrationStateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationNoteSplit.State()) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { _ in
                getMigrationStateCalls.withValue { $0 += 1 }
                return .readyToPropose
            }
            $0.migrationManager.stateEvents = { _ in stateStream.eraseToAnyPublisher() }
        }

        await store.send(.onAppear)

        #expect(getMigrationStateCalls.value == 0)

        stateStream.send(completion: .finished)
        await store.finish()
    }

    /// MOB-1496 (C-1b fix, fix-wave 2): a Keystone mid-commit push (`signedNoteSplitPczt != nil`)
    /// must NEVER confirm itself off the generic engine-state observation — only the coordinator's
    /// own deferred-store success may (`storeDeferredKeystoneSchedule` dispatching `.splitConfirmed`
    /// once `storeSignedMigrationTransactions` actually succeeds). Proven with the exact race window
    /// this closes: `getMigrationState` ALREADY reporting `.readyToPropose` at mount time (as it
    /// would if a prior deferred-store attempt failed and the split independently mined before a
    /// retry) must still not jump to `.confirmed` — the one-shot check and the stream subscription
    /// are both skipped entirely.
    @MainActor @Test func onAppearWithSignedNoteSplitPcztSkipsLegacyObservationEvenWhenAlreadyReadyToPropose() async {
        let getMigrationStateCalls = LockIsolated<Int>(0)
        let store = TestStore(
            initialState: MigrationNoteSplit.State(
                phase: .splitting,
                signedNoteSplitPczt: [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))],
                splitStored: true
            )
        ) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.getMigrationState = { _ in
                getMigrationStateCalls.withValue { $0 += 1 }
                return .readyToPropose
            }
        }

        await store.send(.onAppear)

        #expect(getMigrationStateCalls.value == 0)
        #expect(store.state.phase == MigrationNoteSplit.State.Phase.splitting)
    }

    // MARK: - splitResult: success/failure -> failure sheet

    @MainActor @Test func splitResultSuccessStoresTxIdAndStaysInSplittingPhase() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.success(txId: "e87f1234567890abcdef6f28b"))) {
            $0.txId = "e87f1234567890abcdef6f28b"
        }

        #expect(store.state.phase == .splitting)
        #expect(store.state.isFailurePresented == false)
    }

    @MainActor @Test func splitResultNetworkErrorPresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.networkError(retryable: true))) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func splitResultInvalidNotePresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.invalidNote)) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func splitResultExpiredPresentsFailureSheet() async {
        let store = TestStore(initialState: MigrationNoteSplit.State(phase: .splitting)) {
            MigrationNoteSplit()
        }

        await store.send(.splitResult(.expired)) {
            $0.isFailurePresented = true
        }
    }

    // MARK: - retryTapped: dismiss + re-submit (software path — needs account + USK)

    @MainActor @Test func retryTappedDismissesFailureSheetAndResubmitsStoredProposal() async {
        let submitCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "retried-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            // R7-T3 (MOB-1497): a landed broadcast now also feeds the had-broadcast/episode
            // chokepoint (`recordTransferBroadcast`) — no test value exists, so every test reaching
            // a success/landed outcome must mock it explicitly.
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(submitCalls.value == 1)
    }

    /// MOB-1496 (W4 review Minor): the sentinel-endpoint assertion variant — the test above only
    /// counts calls after a mock-swap, which wouldn't catch the wrong options reaching the
    /// broadcast. A mocked, distinctive endpoint must reach `submitNoteSplit` unchanged, matching
    /// `MigrationSendingTests.onAppearReadsOptionsFromMigrationNetworkOptionsAtExecuteTime`'s
    /// pattern.
    @MainActor @Test func retryTappedPassesTheMockedNetworkOptionsToSubmitNoteSplit() async {
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let sentinel = MigrationNetworkPrivacyOptions(
            useTor: true,
            submissionEndpoint: LightWalletEndpoint(address: "note-split-sentinel.example.com", port: 9067)
        )
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, passedOptions in
                capturedOptions.setValue(passedOptions)
                return MigrationTransferResult.success(txId: "retried-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in sentinel }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(capturedOptions.value == sentinel)
    }

    @MainActor @Test func retryTappedWithNoProposalAndNoSignedPcztReportsNetworkErrorWithoutCallingSDK() async {
        // Defensive branch: neither a stored proposal nor a signed PCZT to retry with — the store
        // reports a retryable network error rather than crashing on a force-unwrap.
        let submitCalls = LockIsolated<Int>(0)
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        ) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }

        #expect(submitCalls.value == 0)
    }

    /// MOB-1496 (R8-T4, #3): the software submit lane's own failure exit — a `.networkError` result
    /// stopped sync for a broadcast that never reached a successful outcome, so it must nudge
    /// Root's app-side gate feed directly (the SDK's own gate only transitions on SUCCESS).
    @MainActor @Test func retryTappedWithFailureResultNudgesMigrationSyncGate() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.plainRetry
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }

        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    // MARK: - MOB-1468: Keystone note-split Retry forks on signedNoteSplitPczt

    /// The batch-commit-pushed variant (MOB-1496 C-1 fix, final review R6): the coordinator's store
    /// effect already called `storeSignedNoteSplits` before pushing this screen with
    /// `splitStored: true`, so `retryTapped` here — the FIRST attempt, dispatched by the coordinator
    /// itself — only ever broadcasts, never stores. This is the only live caller today.
    @MainActor @Test func retryTappedWithSignedNoteSplitPcztAndAlreadyStoredBroadcastsWithoutStoringOrResubmittingProposal() async {
        let storeSignedCalls = LockIsolated<Int>(0)
        let broadcastCalls = LockIsolated<Int>(0)
        let submitProposalCalls = LockIsolated<Int>(0)
        let signedPreps: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        var state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: signedPreps,
            splitStored: true
        )
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in storeSignedCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                broadcastCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitProposalCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }
        // MOB-1496 (C-1b fix, fix-wave 2): a landed broadcast asks the coordinator (which owns the
        // signed schedule entries) to run its deferred store — see `MigrationCoordFlowCoordinator
        // .storeDeferredKeystoneSchedule`'s doc.
        await store.receive(\.splitBroadcastSucceeded) {
            $0.awaitingScheduleStore = true
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(broadcastCalls.value == 1)
        #expect(storeSignedCalls.value == 0)
        #expect(submitProposalCalls.value == 0)
    }

    /// The dormant "S2-phase" fallback (`splitStored` starts `false`): `retryTapped` stores ONCE via
    /// `storeSignedNoteSplits`, flips `splitStored` via `.noteSplitStored`, THEN broadcasts — proving
    /// the fork is self-sufficient even when handed an un-stored PCZT, not just when the coordinator
    /// has already stored it (the only live caller today — see the test above).
    @MainActor @Test func retryTappedWithSignedNoteSplitPcztNotYetStoredStoresThenBroadcastsInOrder() async {
        let callOrder = LockIsolated<[String]>([])
        let storedBatches = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let signedPreps: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        let state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: signedPreps,
            splitStored: false
        )
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storedBatches.withValue { $0.append(signed) }
                callOrder.withValue { $0.append("store") }
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                callOrder.withValue { $0.append("broadcast") }
                return MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.noteSplitStored) {
            $0.splitStored = true
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }
        await store.receive(\.splitBroadcastSucceeded) {
            $0.awaitingScheduleStore = true
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(callOrder.value == ["store", "broadcast"])
        #expect(storedBatches.value == [signedPreps])
    }

    /// Retry idempotence, the S2-phase-then-retry path (MOB-1496 C-1 fix, final review R6): the FIRST
    /// `retryTapped` stores (flipping `splitStored`) then broadcasts — and even when THAT broadcast
    /// fails, a SECOND `retryTapped` (the user tapping Retry on the resulting failure sheet) issues
    /// ZERO additional store calls, broadcast-only. This is the exact defect the deleted
    /// `submitSignedNoteSplit` composite had: its retry re-ran the store, which by then threw (staged
    /// split already consumed) — the failure sheet looped forever. Together with the "already stored"
    /// test above, this covers both ways a retry can arrive at `splitStored == true`.
    @MainActor @Test func retryTappedTwiceAfterABroadcastFailureNeverStoresTwice() async {
        let storeCalls = LockIsolated<Int>(0)
        let broadcastCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T4, #3): the FIRST attempt's broadcast failure stopped sync without ever
        // reaching a successful outcome — must nudge. The second attempt succeeds, so it must NOT
        // nudge again.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let signedPreps: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        let state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: signedPreps,
            splitStored: false
        )
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in storeCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                let callNumber = broadcastCalls.withValue { count -> Int in
                    count += 1
                    return count
                }
                return callNumber == 1
                    ? MigrationTransferResult.networkError(retryable: true)
                    : MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            // R7-T3 (MOB-1497): the first attempt's `.networkError(retryable: true)` now classifies
            // and routes — `.plainRetry` keeps this test's own "existing generic sheet" shape.
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
        }

        // First attempt: stores (flipping splitStored) then broadcasts — the broadcast fails.
        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.noteSplitStored) {
            $0.splitStored = true
        }
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.plainRetry
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }

        #expect(storeCalls.value == 1)
        #expect(broadcastCalls.value == 1)
        #expect(refreshMigrationSyncGateCalls.value == 1)

        // Second attempt (user tapped Retry again): splitStored is now true — broadcast only.
        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }
        await store.receive(\.splitBroadcastSucceeded) {
            $0.awaitingScheduleStore = true
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(storeCalls.value == 1)
        #expect(broadcastCalls.value == 2)
        // The second attempt succeeded — the nudge count must stay at 1 (from the first, failed
        // attempt only).
        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    @MainActor @Test func retryTappedWithNoSignedNoteSplitPcztUsesExistingSoftwareRetry() async {
        let storeSignedCalls = LockIsolated<Int>(0)
        let broadcastStoredCalls = LockIsolated<Int>(0)
        let submitProposalCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in storeSignedCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                broadcastStoredCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitProposalCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "retried-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(storeSignedCalls.value == 0)
        #expect(broadcastStoredCalls.value == 0)
        #expect(submitProposalCalls.value == 1)
    }

    @MainActor @Test func splitConfirmedClearsSignedNoteSplitPczt() async {
        // MOB-1496 (C-1b fix, fix-wave 2): seeded `awaitingScheduleStore: true` too — `.splitConfirmed`
        // is the coordinator's success report for its deferred schedule store, so it must clear this
        // alongside `signedNoteSplitPczt`/`splitStored`.
        let store = TestStore(
            initialState: MigrationNoteSplit.State(
                phase: .splitting,
                signedNoteSplitPczt: [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xEE]))],
                splitStored: true,
                awaitingScheduleStore: true
            )
        ) {
            MigrationNoteSplit()
        }

        await store.send(.splitConfirmed) {
            $0.phase = .confirmed
            $0.signedNoteSplitPczt = nil
            $0.splitStored = false
            $0.awaitingScheduleStore = false
        }
    }

    // MARK: - MOB-1496: broadcast-landed-but-record-failed is treated as success, not failure

    @MainActor @Test func retryTappedWhenRecordFailsAfterBroadcastStillReportsSuccessAndReconciles() async {
        let reconcileCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T4, #3): the broadcast DID land here (only recording failed) — treated
        // exactly like `.success`, so this must NOT nudge the gate feed.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                throw ZcashError.migrationRecordFailedAfterBroadcast(NSError(domain: "test", code: 1))
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        // No further state diff to describe: `txId` was already `""` (the success-like path's
        // placeholder value matches the untouched default) and `isFailurePresented` was already
        // flipped to `false` by `.retryTapped` above.
        await store.receive(\.splitResult)

        #expect(store.state.isFailurePresented == false)
        #expect(reconcileCalls.value == 1)
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }

    // MARK: - MOB-1496 (W3): stop an in-flight sync before a foreground migration broadcast

    /// `sdkSynchronizer.isSyncing() == true` -> `stop()` fires BEFORE the broadcast call, in that
    /// order (asserted via a shared call-order log). Software submit lane (`submitNoteSplit`).
    /// MOB-1496 (W3 review fix B): the shared `stopSyncBeforeMigrationBroadcast()` helper also
    /// flips `migrationStoppedSyncForBroadcast` whenever it actually stops.
    @MainActor @Test func retryTappedWhileSyncingStopsSyncBeforeSubmittingNoteSplit() async {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }

        let callOrder = LockIsolated<[String]>([])
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "retried-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(callOrder.value == ["stop", "execute"])
        #expect(migrationStoppedSyncForBroadcast == true)
    }

    /// Idempotent: `sdkSynchronizer.isSyncing() == false` -> `stop()` is never called, and the
    /// shared broadcast-stop flag is never set either. Software submit lane.
    @MainActor @Test func retryTappedWhileIdleDoesNotCallStopBeforeSubmittingNoteSplit() async {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }

        let stopCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { stopCalls.withValue { $0 += 1 } },
                isSyncing: { false }
            )
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "retried-tx-id") }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(stopCalls.value == 0)
        #expect(migrationStoppedSyncForBroadcast == false)
    }

    /// The Keystone resubmit lane (an already-signed PCZT) gets the same stop-before-broadcast
    /// treatment as the software submit lane above.
    @MainActor @Test func retryTappedWithSignedPcztWhileSyncingStopsSyncBeforeResubmitting() async {
        let callOrder = LockIsolated<[String]>([])
        let signedPreps: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        var state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: signedPreps,
            splitStored: true
        )
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }
        await store.receive(\.splitBroadcastSucceeded) {
            $0.awaitingScheduleStore = true
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(callOrder.value == ["stop", "execute"])
    }

    // MARK: - MOB-1496 (C-1b fix, fix-wave 2): deferred schedule store handshake with the coordinator

    /// The Keystone fork's `migrationRecordFailedAfterBroadcast` catch (the broadcast DID land; only
    /// recording failed) is ALSO a landed broadcast — it must still ask the coordinator to run its
    /// deferred store, exactly like an ordinary success. Mirrors
    /// `retryTappedWhenRecordFailsAfterBroadcastStillReportsSuccessAndReconciles` above, which covers
    /// the unaffected SOFTWARE fork (`submitNoteSplit`, still reconciles directly — no coordinator
    /// involved there).
    @MainActor @Test func retryTappedWithSignedPcztWhenRecordFailsAfterBroadcastStillAsksCoordinatorToStore() async {
        // MOB-1496 (R8-T4, #3): the broadcast DID land here (only recording failed) — treated
        // exactly like `.success`, so this must NOT nudge the gate feed.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let signedPreps: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        let state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: signedPreps,
            splitStored: true
        )
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                throw ZcashError.migrationRecordFailedAfterBroadcast(NSError(domain: "test", code: 1))
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        // txId was already "" (the untouched default matches the success-like placeholder value) —
        // no further diff to describe for this receive.
        await store.receive(\.splitResult)
        await store.receive(\.splitBroadcastSucceeded) {
            $0.awaitingScheduleStore = true
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(store.state.isFailurePresented == false)
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }

    /// While `awaitingScheduleStore` is `true` (a previous deferred-store attempt failed), a further
    /// `retryTapped` must ask the coordinator AGAIN — never re-broadcast the already-safe split
    /// (`broadcastStoredNoteSplit`) and never re-store it (`storeSignedNoteSplits`) or re-submit the
    /// software proposal (`submitNoteSplit`). Counter-asserts all three SDK members stay uncalled.
    @MainActor @Test func retryTappedWhileAwaitingScheduleStoreAsksCoordinatorAgainWithoutBroadcastingOrStoring() async {
        let storeSignedCalls = LockIsolated<Int>(0)
        let broadcastCalls = LockIsolated<Int>(0)
        let submitProposalCalls = LockIsolated<Int>(0)
        var state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: true,
            signedNoteSplitPczt: [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))],
            splitStored: true,
            awaitingScheduleStore: true
        )
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in storeSignedCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                broadcastCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitProposalCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(.delegate(.storeScheduleRequested))

        #expect(storeSignedCalls.value == 0)
        #expect(broadcastCalls.value == 0)
        #expect(submitProposalCalls.value == 0)
    }

    /// The coordinator's deferred store failing re-presents the EXISTING failure sheet;
    /// `awaitingScheduleStore` stays `true` so the very next retry asks the coordinator again (see the
    /// test above) rather than falling back to a re-broadcast or re-store.
    @MainActor @Test func scheduleStoreFailedPresentsFailureSheetAndKeepsAwaitingScheduleStore() async {
        let store = TestStore(
            initialState: MigrationNoteSplit.State(
                phase: .splitting,
                signedNoteSplitPczt: [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))],
                splitStored: true,
                awaitingScheduleStore: true
            )
        ) {
            MigrationNoteSplit()
        }

        await store.send(.scheduleStoreFailed) {
            $0.isFailurePresented = true
        }

        #expect(store.state.awaitingScheduleStore == true)
    }

    // MARK: - R7-T3 (MOB-1497): R14 first-run Tor choice (software fork)

    private func stateWithProposal(isFailurePresented: Bool = true) -> MigrationNoteSplit.State {
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: isFailurePresented)
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        return state
    }

    @MainActor @Test func retryTappedWithTorUnavailableFirstRunPresentsTorFirstRunChoice() async {
        let capturedFailureClass = LockIsolated<MigrationBroadcastFailureClass?>(nil)
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in throw ZcashError.migrationTorUnavailable }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, failureClass in
                capturedFailureClass.setValue(failureClass)
                return MigrationBroadcastFailureRoute.torFirstRunChoice
            }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }

        #expect(capturedFailureClass.value == MigrationBroadcastFailureClass.torUnavailable)
    }

    @MainActor @Test func retryTappedAfterTorFirstRunChoiceKeepsTorAndReSubmitsWithoutMutating() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "tx-retry") }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "tx-retry"
        }

        #expect(overrideTorCalls.value == 0)
    }

    @MainActor @Test func proceedWithoutTorTappedPresentsOffWarningAlertWithGradualMessageOnScheduledPath() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.migrationManager.migrationMode = { MigrationMode.privateScheduled }
        }

        await store.send(.proceedWithoutTorTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        }
    }

    @MainActor @Test func proceedWithoutTorTappedPresentsOffWarningAlertWithFullMessageOnImmediatePath() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.migrationManager.migrationMode = { MigrationMode.immediate }
        }

        await store.send(.proceedWithoutTorTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: true, proceedAction: .offWarningProceedTapped)
        }
    }

    @MainActor @Test func offWarningAlertProceedTappedTurnsTorOffThenRetries() async {
        let overrideTorCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "tx-offwarn") }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.overrideTorForRun = { accountUUID, useTor in
                overrideTorCalls.withValue { $0.append((accountUUID, useTor)) }
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.alert(.presented(.offWarningProceedTapped)))
        await store.receive(.offWarningProceedTapped) {
            $0.alert = nil
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "tx-offwarn"
        }

        #expect(overrideTorCalls.value.count == 1)
        #expect(overrideTorCalls.value.first?.1 == false)
    }

    @MainActor @Test func alertDismissKeepsTorOnAndReturnsToTheFailureSheetWithZeroMutations() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        }

        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureKind == MigrationBroadcastFailureRoute.torFirstRunChoice)
    }

    @MainActor @Test func cancelTappedFromTorFirstRunChoiceDismissesWithZeroMutations() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
    }

    // MARK: - R7-T3 (MOB-1497): R15 mid-run Tor hold

    @MainActor @Test func retryTappedWithTorUnavailableMidRunPresentsTorHold() async {
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in throw ZcashError.migrationTorUnavailable }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.torHold }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.torHold
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func retryTappedAfterTorHoldKeepsTorAndReSubmitsWithoutMutating() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torHold
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.success(txId: "tx-hold-retry") }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "tx-hold-retry"
        }

        #expect(overrideTorCalls.value == 0)
    }

    /// R7-review fix (Minor-3): see `MigrationSending`'s identical
    /// `proceedWithoutTorTappedInTorHoldStateIsANoOp` for the full rationale — gated to
    /// `.torFirstRunChoice`, a no-op everywhere else. RED against the pre-fix reducer, which
    /// presented the alert unconditionally.
    @MainActor @Test func proceedWithoutTorTappedInTorHoldStateIsANoOp() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.torHold
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        }

        await store.send(.proceedWithoutTorTapped)
    }

    // MARK: - R7-T3 (MOB-1497): R16 within-provider rotation — no new UI

    @MainActor @Test func retryTappedWithEndpointUnreachableRotatedSetsFailureKindButKeepsGenericFailureSheet() async {
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.retryRotated }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.retryRotated
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func retryTappedAfterRotationReSubmitsWithTheRotatedOptions() async {
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let rotatedSentinel = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(address: "rotated.example.com", port: 9067)
        )
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.retryRotated
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, passedOptions in
                capturedOptions.setValue(passedOptions)
                return MigrationTransferResult.success(txId: "tx-rotated")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in rotatedSentinel }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "tx-rotated"
        }

        #expect(capturedOptions.value == rotatedSentinel)
    }

    // MARK: - R7-T3 (MOB-1497): R17 provider-exhausted sync-server consent

    @MainActor @Test func retryTappedWithProviderExhaustedTorOnPresentsConsentVariant() async {
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true) }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func retryTappedWithProviderExhaustedTorOffPresentsConsentVariant() async {
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false) }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        }
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func useSyncServerTappedOverridesThenRetriesInOrder() async {
        let callOrder = LockIsolated<[String]>([])
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "tx-syncserver")
            }
            $0.migrationManager.overrideBroadcastEndpointToSyncServer = { _ in
                callOrder.withValue { $0.append("override") }
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.useSyncServerTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.splitResult) {
            $0.txId = "tx-syncserver"
        }

        #expect(callOrder.value == ["override", "execute"])
    }

    @MainActor @Test func cancelTappedFromProviderExhaustedIsKeepWaitingWithZeroMutations() async {
        var state = stateWithProposal()
        state.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
    }

    // MARK: - R9-T4 (MOB-1497 review remediation, finding 5): pre-broadcast local failures never
    // enter the broadcast-failure routing ladder

    /// `submitNoteSplit`'s USK derivation is pre-broadcast LOCAL work — see
    /// `MigrationSendingTests.onAppearWithDustLaneDeriveUSKFailureReportsNilResultWithoutRoutingOrNudgingOrBroadcasting`'s
    /// identical rationale (classifiable-looking generic error, counted `routeBroadcastFailure`
    /// stub). RED against the parent commit: today `deriveUSK`'s throw here lands inside the SAME
    /// `do`/`catch` as the broadcast, so it WOULD route.
    @MainActor @Test func retryTappedWithDeriveUSKFailureReportsNetworkErrorWithoutRoutingOrNudgingOrCallingSubmitNoteSplit() async {
        let submitCalls = LockIsolated<Int>(0)
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: stateWithProposal(isFailurePresented: false)) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
            $0.derivationTool.deriveSpendingKey = { _, _, _ in throw NSError(domain: "test", code: 3) }
        }

        await store.send(.retryTapped)
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }

        #expect(submitCalls.value == 0)
        #expect(routeBroadcastFailureCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }

    /// `resubmitSignedNoteSplit`'s `storeSignedNoteSplits` call (made only when `splitStored == false`)
    /// is pre-broadcast LOCAL persistence — same rationale as the derive-USK sites above. RED against
    /// the parent commit: today this throw lands inside the SAME `do`/`catch` as
    /// `broadcastStoredNoteSplit`, so it WOULD route.
    @MainActor @Test func retryTappedWithSignedPcztWhenStoreSignedNoteSplitFailsReportsNetworkErrorWithoutRoutingOrNudgingOrBroadcasting() async {
        let storeSignedCalls = LockIsolated<Int>(0)
        let broadcastCalls = LockIsolated<Int>(0)
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let signedPreps = [MigrationSignedTransferPczt(id: "p0", pczt: Data([0xCC, 0xDD]))]
        let state = MigrationNoteSplit.State(
            phase: .splitting,
            isFailurePresented: false,
            signedNoteSplitPczt: signedPreps,
            splitStored: false
        )
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in
                storeSignedCalls.withValue { $0 += 1 }
                throw NSError(domain: "test", code: 4)
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                broadcastCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.retryTapped)
        await store.receive(\.splitResult) {
            $0.isFailurePresented = true
        }

        #expect(storeSignedCalls.value == 1)
        #expect(broadcastCalls.value == 0)
        #expect(routeBroadcastFailureCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }
}
