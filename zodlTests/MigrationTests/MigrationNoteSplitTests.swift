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
//  `signedNoteSplitPczt` via `submitSignedNoteSplit` rather than re-submitting the proposal.
//  MOB-1496: the software-signing/resubmission paths now hit the real per-account SDK surface
//  (`AccountUUID` + a derived `UnifiedSpendingKey` + `migrationManager.migrationNetworkOptions(_:)`).
//  `.serialized`: several cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`,
//  and the copy action writes the shared toast.
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

    // MARK: - MOB-1468: Keystone note-split Retry forks on signedNoteSplitPczt

    @MainActor @Test func retryTappedWithSignedNoteSplitPcztRebroadcastsSamePcztInsteadOfResubmittingProposal() async {
        let submitSignedCalls = LockIsolated<[Data]>([])
        let submitProposalCalls = LockIsolated<Int>(0)
        let signedPczt = Data([0xCC, 0xDD])
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true, signedNoteSplitPczt: signedPczt)
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitSignedNoteSplit = { _, pczt, _ in
                submitSignedCalls.withValue { $0.append(pczt) }
                return MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitProposalCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }

        #expect(submitSignedCalls.value == [signedPczt])
        #expect(submitProposalCalls.value == 0)
    }

    @MainActor @Test func retryTappedWithNoSignedNoteSplitPcztUsesExistingSoftwareRetry() async {
        let submitSignedCalls = LockIsolated<Int>(0)
        let submitProposalCalls = LockIsolated<Int>(0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true)
        state.proposal = proposal
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.submitSignedNoteSplit = { _, _, _ in
                submitSignedCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitProposalCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "retried-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "retried-tx-id"
        }

        #expect(submitSignedCalls.value == 0)
        #expect(submitProposalCalls.value == 1)
    }

    @MainActor @Test func splitConfirmedClearsSignedNoteSplitPczt() async {
        let store = TestStore(
            initialState: MigrationNoteSplit.State(phase: .splitting, signedNoteSplitPczt: Data([0xEE]))
        ) {
            MigrationNoteSplit()
        }

        await store.send(.splitConfirmed) {
            $0.phase = .confirmed
            $0.signedNoteSplitPczt = nil
        }
    }

    // MARK: - MOB-1496: broadcast-landed-but-record-failed is treated as success, not failure

    @MainActor @Test func retryTappedWhenRecordFailsAfterBroadcastStillReportsSuccessAndReconciles() async {
        let reconcileCalls = LockIsolated<Int>(0)
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
        let signedPczt = Data([0xCC, 0xDD])
        var state = MigrationNoteSplit.State(phase: .splitting, isFailurePresented: true, signedNoteSplitPczt: signedPczt)
        state.proposal = NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000))
        let store = TestStore(initialState: state) {
            MigrationNoteSplit()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.submitSignedNoteSplit = { _, _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "resubmitted-tx-id")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.splitResult) {
            $0.txId = "resubmitted-tx-id"
        }

        #expect(callOrder.value == ["stop", "execute"])
    }
}
