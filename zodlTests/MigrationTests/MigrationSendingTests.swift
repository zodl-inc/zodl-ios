//
//  MigrationSendingTests.swift
//  zodlTests
//
//  Covers the MigrationSending reducer
//  (Features/Migration/MigrationSending/MigrationSendingStore.swift) for MOB-1463/1466: the default
//  phase/state, the `closeTapped` / `viewTransactionTapped` delegate contracts, the failure sheet
//  dismissal (cancel/retry), and `onAppear` executing `executeNextPendingMigrationTransfer`,
//  recording a broadcast + scheduling the next background window after success, presenting the
//  failure sheet on failure/`nil`, and retry re-running the failed step. MOB-1496: both lanes now
//  hit the real per-account SDK surface — `executeNextPendingMigrationTransfer` needs a concrete
//  `AccountUUID`. MOB-1496 (W5, ZIP-0318): a single `onAppear` now executes AT MOST ONE transfer,
//  even when the screen is configured with `totalCount` > 1 (the S10 "Send now" lane's old
//  multi-overdue shape) — see `onAppearWithMultipleOverdueExecutesExactlyOneTransfer`. `.serialized`:
//  several cases drive the process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//
//  MOB-1496 (W-B): the "Migrate anyway" dust lane (MOB-1487/MOB-1494's `isDustLane`, a USK composite
//  that re-proposed a residual-inclusive schedule via `migrateMigrationDust`) is retired — "Migrate
//  anyway" now rides the SAME `immediateProposal` lane the entry-screen immediate migration already
//  exercises below (`onAppearWithImmediateProposal...`), so its dust-specific tests are removed
//  rather than ported.
//
//  MOB-1497 (T8, Q3'26 canvas): `isManualStepLane` defaults to false and is settable via init, same
//  as `entersViaSendNow` — but unlike that one, it drives no SDK branching at all, only
//  `sentSubtitle`'s "sent"-vs-"migrated" wording (asserted directly against both branches, since a
//  view-only assertion isn't possible here without UI-testing infrastructure this repo doesn't have).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationSendingTests {
    private struct TestFailure: Error { }

    /// MOB-1496: every SDK call this store makes needs a concrete `AccountUUID` — this `init()` acts
    /// as a per-test setup hook (Swift Testing instantiates a fresh struct per `@Test`), seeding a
    /// selected software account by default; Keystone-specific tests override it locally. See
    /// `MigrationTransferPlanTests`' twin helper for the fuller rationale.
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

    /// MOB-1496/MOB-1513: the immediate lane's software path derives a real USK from the wallet's
    /// stored seed — see `MigrationTransferPlanTests`' twin helper for the rationale.
    private func withDependenciesUSKDerivable(_ values: inout DependencyValues) {
        values.derivationTool = .liveValue
        values.mnemonic = .mock
        values.walletStorage = .noOp
        values.zcashSDKEnvironment = .testnet
    }

    @MainActor @Test func defaultStateIsSendingPhaseWithNoFailureSheet() async {
        let state = MigrationSending.State()

        #expect(state.phase == MigrationSending.State.Phase.sending)
        #expect(state.isFailurePresented == false)
        #expect(state.txId == "")
        #expect(state.totalCount == 1)
        #expect(state.sentCount == 0)
        // R7-T3 (MOB-1497)
        #expect(state.failureKind == nil)
        #expect(state.alert == nil)
        // MOB-1497 (T8)
        #expect(state.isManualStepLane == false)
    }

    // MARK: - MOB-1497 (T8, Q3'26 canvas): manual per-transfer lane -> "sent" success wording

    @MainActor @Test func isManualStepLaneDefaultsFalseButCanBeSetTrueViaInit() async {
        let defaultState = MigrationSending.State()
        let manualStepState = MigrationSending.State(isManualStepLane: true)

        #expect(defaultState.isManualStepLane == false)
        #expect(manualStepState.isManualStepLane == true)
        // Unrelated defaults are untouched by the new trailing init parameter.
        #expect(manualStepState.phase == MigrationSending.State.Phase.sending)
        #expect(manualStepState.totalCount == 1)
    }

    /// The manual-delivery per-transfer lane (TransferPlan's `.manual` variant sending its first
    /// transfer, or a later `MigrationReviewTransfer.State.Mode.manualStep` confirm) reads as one
    /// transfer among several the user is walking through by hand, so its success screen says the
    /// ZEC was "sent" rather than "migrated".
    @MainActor @Test func sentSubtitleIsTransferWordingForManualStepLane() async {
        let state = MigrationSending.State(isManualStepLane: true)

        #expect(state.sentSubtitle == String(localizable: .migrationSendingSentSubtitleTransfer))
    }

    /// Every other lane — the default (immediate full sweep / plan-first review, including "Migrate
    /// anyway" since MOB-1496 W-B), and the Status screen's "Send now" resume of an
    /// already-scheduled transfer — still reads as part of one larger migration run, so it keeps
    /// the pre-existing "migrated" wording. Flipping `isManualStepLane` is the only thing that
    /// changes the mapping — this would fail if that selection were ever reversed.
    @MainActor @Test func sentSubtitleIsMigratedWordingForEveryOtherLane() async {
        #expect(MigrationSending.State().sentSubtitle == String(localizable: .migrationSendingSentSubtitleMigrated))
        #expect(
            MigrationSending.State(entersViaSendNow: true).sentSubtitle
                == String(localizable: .migrationSendingSentSubtitleMigrated)
        )
    }

    // MARK: - MOB-1513 (Lane A2): immediateProposal defaults + init

    @MainActor @Test func immediateProposalDefaultsNilButCanBeSetViaInit() async {
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 0), amount: Zatoshi.zero, fee: Zatoshi.zero)
        let defaultState = MigrationSending.State()
        let immediateState = MigrationSending.State(immediateProposal: proposal)

        #expect(defaultState.immediateProposal == nil)
        #expect(immediateState.immediateProposal == proposal)
        // Unrelated defaults are untouched by the new trailing init parameter.
        #expect(immediateState.phase == MigrationSending.State.Phase.sending)
        #expect(immediateState.totalCount == 1)
    }

    @MainActor @Test func closeTappedEmitsDelegateClosed() async {
        let store = TestStore(initialState: MigrationSending.State(phase: .success)) {
            MigrationSending()
        }

        await store.send(.closeTapped)
        await store.receive(.delegate(.closed))
    }

    @MainActor @Test func viewTransactionTappedEmitsDelegateViewTransaction() async {
        let store = TestStore(initialState: MigrationSending.State(phase: .success, txId: "e87f1234567890abcdef6f28b")) {
            MigrationSending()
        }

        await store.send(.viewTransactionTapped)
        await store.receive(.delegate(.viewTransaction))
    }

    @MainActor @Test func cancelTappedDismissesFailureSheet() async {
        let store = TestStore(initialState: MigrationSending.State(isFailurePresented: true)) {
            MigrationSending()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
        }
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationSending.State()) {
            MigrationSending()
        }

        await store.send(.delegate(.closed))
    }

    // MARK: - onAppear: no selected account -> nil result, same as any other failure

    @MainActor @Test func onAppearWithNoSelectedAccountReportsNilResultWithoutCallingSDK() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        let executedCount = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(executedCount.value == 0)
    }

    // MARK: - MOB-1513 (R10): onAppear already in `.success` phase -> nothing left to execute

    /// The Keystone immediate lane's broadcast already happened in `MigrationCoordFlowCoordinator`
    /// BEFORE this screen is ever pushed — `.keystoneImmediateSubmitted` pushes straight into
    /// `.success` (see that handler's doc). Pre-fix, `onAppear` re-ran the executor anyway: with no
    /// account-scoped transfer left in the engine for `executeNextPendingMigrationTransfer` to
    /// serve, that resolved to a non-success result, which flipped `isFailurePresented = true` and
    /// popped the failure sheet OVER the success screen — the QA-reported bogus error. `onAppear`
    /// must be a no-op once the phase is already `.success`: no dependency touched, no action
    /// received, no state mutated. RED against the pre-fix reducer, which only guarded on
    /// `isFailurePresented`/`entersViaSendNow`, never `phase`.
    @MainActor @Test func onAppearInSuccessPhaseExecutesNothing() async {
        var state = MigrationSending.State(phase: .success, txId: "deadbeef")
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 0) }
        let store = TestStore(initialState: state) {
            MigrationSending()
        }

        await store.send(.onAppear)
    }

    // MARK: - onAppear: single transfer (immediate/manual/plan-first)

    @MainActor @Test func onAppearWithSingleTransferSucceedsAndReachesSentPhase() async {
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        // MOB-1496 (W2): the write-point for the persisted-schedule storage — fires on a
        // successful broadcast, beside the existing `reconcile()` call.
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-0") }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(scheduleNextWindowCalls.value == 1)
        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: "tx-0"))
        #expect(reconcileCalls.value == 1)
    }

    // MARK: - onAppear: send-now cap (ZIP-0318 MUST, MOB-1496 W5) — exactly ONE transfer

    /// ZIP-0318: a background session — and the S10 "Send now" lane it shares this executor with —
    /// may broadcast at most ONE overdue transfer per session/tap. Even when the screen is
    /// configured the old "multiple overdue" way (`totalCount` > 1, still how the coordinator counts
    /// overdue rows for its send-now push), `onAppear` executes exactly ONE
    /// `executeNextPendingMigrationTransfer` call and reaches `.allTransfersSent` immediately after —
    /// it must NEVER chain into a second broadcast. Replaces the retired
    /// `onAppearWithMultipleTransfersExecutesStrictlyInSequence` (which asserted the OPPOSITE: 3
    /// sequential calls) — the per-broadcast bookkeeping (`recordTransferBroadcast`, `reconcile`,
    /// `scheduleNextWindow`) still fires exactly once, identical to an ordinary single send.
    @MainActor @Test func onAppearWithMultipleOverdueExecutesExactlyOneTransfer() async {
        let executedCount = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 3)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-1")
            }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-1"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executedCount.value == 1)
        #expect(scheduleNextWindowCalls.value == 1)
        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: "tx-1"))
        #expect(reconcileCalls.value == 1)
    }

    /// MOB-1496 (W4): the scheduled-lane options come from `migrationManager.migrationNetworkOptions
    /// (accountUUID)`, read AT EXECUTE TIME inside the effect — never a value threaded through
    /// state (which would go stale across a re-entry or a long BG-window gap). A mocked sentinel
    /// must reach `executeNextPendingMigrationTransfer` unchanged.
    @MainActor @Test func onAppearReadsOptionsFromMigrationNetworkOptionsAtExecuteTime() async {
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let capturedAccountUUIDs = LockIsolated<[AccountUUID?]>([])
        let sentinel = MigrationNetworkPrivacyOptions(
            useTor: true,
            submissionEndpoint: LightWalletEndpoint(address: "example.com", port: 9067)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, passedOptions in
                capturedOptions.setValue(passedOptions)
                return MigrationTransferResult.success(txId: "tx-0")
            }
            $0.migrationManager.migrationNetworkOptions = { accountUUID in
                capturedAccountUUIDs.withValue { $0.append(accountUUID) }
                return sentinel
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(capturedOptions.value == sentinel)
        #expect(capturedAccountUUIDs.value == [walletAccount(keystone: false, idByte: 0).id])
    }

    // MARK: - MOB-1513 (Lane A2): immediate lane — genuine create+sign+submit happens HERE

    /// The immediate lane's `onAppear` performs the ACTUAL create+sign+submit
    /// (`MigrationCommitPipeline.commitImmediateSoftware` -> `createAndSubmitProposedTransactions`)
    /// instead of `executeNextPendingMigrationTransfer` — there is no engine-stored transaction for
    /// that call to serve. On success: create THEN record (order-asserted), the hex-string txid
    /// becomes `state.txId`, the shared `.transferResult` success handler's bookkeeping
    /// (`recordTransferBroadcast`/`reconcile`/`scheduleNextWindow`) fires exactly as for every other
    /// lane, and — UNLIKE the engine lanes — `refreshMigrationSyncGate` IS called even on success:
    /// `createAndSubmitProposedTransactions` never touches the SDK's own migration-sync privacy gate,
    /// so nothing else would ever prompt `RootInitialization`'s resume-once-clear machinery to
    /// re-check the stop this screen made before broadcasting.
    @MainActor @Test func onAppearWithImmediateProposalCreatesAndSubmitsRecordsInOrderAndReachesSentPhase() async {
        let callOrder = LockIsolated<[String]>([])
        let recordedTxIds = LockIsolated<[(AccountUUID, Data)]>([])
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let scheduleNextWindowCalls = LockIsolated<Int>(0)
        // MOB-1513: the correctness fix this test locks in — see this file's header doc.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let account = walletAccount(keystone: false, idByte: 0)
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, immediateProposal: proposal)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { proposedProposal, _ in
                callOrder.withValue { $0.append("create") }
                #expect(proposedProposal == proposal.proposal)
                return .success(txIds: ["aabbccdd"])
            }
            $0.sdkSynchronizer.recordImmediateMigration = { accountUUID, txid in
                callOrder.withValue { $0.append("record") }
                recordedTxIds.withValue { $0.append((accountUUID, txid)) }
            }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationBGScheduler.scheduleNextWindow = { scheduleNextWindowCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "aabbccdd"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(callOrder.value == ["create", "record"])
        #expect(recordedTxIds.value.count == 1)
        #expect(recordedTxIds.value.first?.0 == account.id)
        // "aabbccdd" hex-decoded forward is [0xAA,0xBB,0xCC,0xDD]; `recordImmediateMigration` wants
        // the RAW/internal byte order, which is that decoded sequence reversed.
        #expect(recordedTxIds.value.first?.1 == Data([0xDD, 0xCC, 0xBB, 0xAA]))
        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: "aabbccdd"))
        #expect(reconcileCalls.value == 1)
        #expect(scheduleNextWindowCalls.value == 1)
        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    /// Failure ⇒ no record call: a non-`.success` submit outcome must never call
    /// `recordImmediateMigration` — recording a sweep that never broadcast would corrupt the
    /// platform migration state machine's bookkeeping.
    @MainActor @Test func onAppearWithImmediateProposalOnSubmitFailureNeverRecordsAndPresentsFailureSheet() async {
        let recordCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, immediateProposal: proposal)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in .failure(txIds: [], code: -9, description: "rejected") }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in recordCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.plainRetry
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(recordCalls.value == 0)
        #expect(store.state.sentCount == 0)
        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    /// Lane discrimination twin of `onAppearWithoutDustLaneExecutesScheduledTransferNotMigrateMigrationDust`:
    /// an immediate-proposal state must never fall through to the engine's own delivery member —
    /// there is nothing stored in the engine for it to serve.
    @MainActor @Test func onAppearWithImmediateProposalNeverCallsExecuteNextPendingMigrationTransfer() async {
        let executeNextCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, immediateProposal: proposal)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeNextCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-be-called")
            }
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in .success(txIds: ["ff00"]) }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "ff00"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executeNextCalls.value == 0)
    }

    /// R9-T4-style hoist (mirrors `onAppearWithDustLaneDeriveUSKFailureReportsNilResultWithoutRoutingOrNudgingOrBroadcasting`):
    /// a Keystone account can never reach this branch in practice (the coordinator only threads
    /// `immediateProposal` for a software confirm), but the same defensive guard applies — no USK
    /// derivation attempted, no broadcast, no routing/nudging.
    @MainActor @Test func onAppearWithImmediateProposalAndKeystoneAccountNeverDerivesUSKOrCallsCreateAndSubmit() async {
        let createCalls = LockIsolated<Int>(0)
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        var state = MigrationSending.State(totalCount: 1, immediateProposal: proposal)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
                createCalls.withValue { $0 += 1 }
                return .success(txIds: ["should-not-be-called"])
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(createCalls.value == 0)
        #expect(routeBroadcastFailureCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }

    /// Same stop-before-broadcast treatment as every other lane (order-asserted, mirrors
    /// `onAppearWhileSyncingStopsSyncBeforeExecutingScheduledTransfer`).
    @MainActor @Test func onAppearWithImmediateProposalWhileSyncingStopsSyncBeforeSubmitting() async {
        let callOrder = LockIsolated<[String]>([])
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, immediateProposal: proposal)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.createAndSubmitProposedTransactions = { _, _ in
                callOrder.withValue { $0.append("create") }
                return .success(txIds: ["aa"])
            }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "aa"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(callOrder.value == ["stop", "create"])
    }

    // MARK: - Keystone account, scheduled lane (never derives a USK, unlike the immediate lane)

    /// A Keystone account executes the SAME `executeNextPendingMigrationTransfer` path as a
    /// software account — it needs no signing (it broadcasts an already-signed pending transfer,
    /// already committed via the coordinator's Keystone PCZT batch flow), so it stays account-only
    /// for both vendors — confirms it executes with the snapshot network options, records the
    /// broadcast, and never touches the USK-deriving member.
    @MainActor @Test func onAppearWithKeystoneAccountExecutesScheduledTransferWithSnapshotOptionsAndNeverDerivesUSK() async {
        let deriveCalls = LockIsolated<Int>(0)
        let executeCalls = LockIsolated<[MigrationNetworkPrivacyOptions]>([])
        let recordTransferBroadcastCalls = LockIsolated<Int>(0)
        let options = MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: LightWalletEndpoint(address: "dust.example", port: 1))
        var state = MigrationSending.State(totalCount: 1)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 8) }
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, usedOptions in
                executeCalls.withValue { $0.append(usedOptions) }
                return MigrationTransferResult.success(txId: "dust-tx")
            }
            $0.derivationTool.deriveSpendingKey = { _, _, _ in
                deriveCalls.withValue { $0 += 1 }
                throw TestFailure()
            }
            $0.migrationManager.migrationNetworkOptions = { _ in options }
            $0.migrationManager.recordTransferBroadcast = { _, _ in recordTransferBroadcastCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.txId = "dust-tx"
            $0.sentCount = 1
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executeCalls.value == [options])
        #expect(deriveCalls.value == 0)
        #expect(recordTransferBroadcastCalls.value == 1)
    }

    // MARK: - Failure / nil result: presents failure sheet, stops the sequence

    /// R7-T3 (MOB-1497): `.networkError(retryable: true)` classifies as `.endpointUnreachable` — now
    /// routed via `routeBroadcastFailure` (mocked `.plainRetry`, the least-eventful route) BEFORE the
    /// pre-existing `.transferResult` handling, which is otherwise byte-for-byte unchanged.
    @MainActor @Test func onAppearWithFailureResultPresentsFailureSheetAndStopsSequence() async {
        let executedCount = LockIsolated<Int>(0)
        // MOB-1496 (R8-T4, #3): a `.networkError` result stopped sync for a broadcast that never
        // reached a successful outcome — the SDK's own gate transitions only on SUCCESS, so this
        // path must nudge Root's app-side gate feed directly (see
        // `migrationManager.refreshMigrationSyncGate`'s doc).
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 3)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.networkError(retryable: true)
            }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.plainRetry
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(executedCount.value == 1)
        #expect(store.state.sentCount == 0)
        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    @MainActor @Test func onAppearWithNilResultPresentsFailureSheet() async {
        // MOB-1496 (R8-T4, #3): see the twin comment on
        // `onAppearWithFailureResultPresentsFailureSheetAndStopsSequence` above — a `nil` result is
        // the SAME "stopped sync, never broadcast successfully" shape.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    /// A generic thrown error (not `ZcashError.migrationRecordFailedAfterBroadcast`) after the stop
    /// hits the catch-all — also needs the nudge (MOB-1496 R8-T4 #3).
    @MainActor @Test func onAppearWithThrownGenericErrorAfterStopPresentsFailureSheetAndNudgesGate() async {
        struct SomeOtherFailure: Error { }
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw SomeOtherFailure() }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.plainRetry
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    // MARK: - MOB-1496: broadcast-landed-but-record-failed is treated as success, not failure

    @MainActor @Test func onAppearWhenRecordFailsAfterBroadcastStillReachesSentPhase() async {
        // MOB-1496 (W2): the broadcast DID land — `recordTransferBroadcast` still fires, with the
        // placeholder empty txId the store falls back to (persisted as `nil`, not `""`, by
        // `MigrationScheduleStorage` — covered directly in `MigrationScheduleStorageTests`).
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
        // MOB-1496 (R8-T4, #3): the broadcast DID land here (only recording failed) — this is
        // treated exactly like a `.success` result, so it must NOT nudge the gate feed (the SDK's
        // own gate transition already covers the resume).
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                throw ZcashError.migrationRecordFailedAfterBroadcast(TestFailure())
            }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            $0.migrationBGScheduler.scheduleNextWindow = { }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = ""
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: ""))
        #expect(refreshMigrationSyncGateCalls.value == 0)
    }

    // MARK: - retryTapped: re-runs only the failed step

    @MainActor @Test func retryTappedDismissesFailureSheetAndReRunsFailedStep() async {
        let executedCount = LockIsolated<Int>(0)
        let state = MigrationSending.State(isFailurePresented: true, totalCount: 2, sentCount: 1)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executedCount.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "retried-tx")
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 2
            $0.txId = "retried-tx"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executedCount.value == 1)
    }

    // MARK: - MOB-1496 (W3): stop an in-flight sync before a foreground migration broadcast

    /// `sdkSynchronizer.isSyncing() == true` -> `stop()` fires BEFORE the broadcast call, in that
    /// order (asserted via a shared call-order log). MOB-1496 (W3 review fix B): the shared
    /// `stopSyncBeforeMigrationBroadcast()` helper also flips `migrationStoppedSyncForBroadcast`
    /// whenever it actually stops — Root's resume-after-gate-clears mechanism keys off it.
    @MainActor @Test func onAppearWhileSyncingStopsSyncBeforeExecutingScheduledTransfer() async {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }

        let callOrder = LockIsolated<[String]>([])
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: { true }
            )
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "tx-0")
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(callOrder.value == ["stop", "execute"])
        #expect(migrationStoppedSyncForBroadcast == true)
    }

    /// Idempotent: `sdkSynchronizer.isSyncing() == false` -> `stop()` is never called, and the
    /// shared broadcast-stop flag is never set either.
    @MainActor @Test func onAppearWhileIdleDoesNotCallStopBeforeExecutingScheduledTransfer() async {
        @Shared(.inMemory(.migrationStoppedSyncForBroadcast)) var migrationStoppedSyncForBroadcast: Bool = false
        $migrationStoppedSyncForBroadcast.withLock { $0 = false }

        let stopCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { stopCalls.withValue { $0 += 1 } },
                isSyncing: { false }
            )
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-0") }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-0"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(stopCalls.value == 0)
        #expect(migrationStoppedSyncForBroadcast == false)
    }

    // MARK: - R8-T6 (V8 fix): Send-now lane — silence-window gate-check/wait

    @MainActor @Test func entersViaSendNowDefaultsFalseButCanBeSetTrueViaInit() async {
        let defaultState = MigrationSending.State()
        let sendNowState = MigrationSending.State(entersViaSendNow: true)

        #expect(defaultState.entersViaSendNow == false)
        #expect(sendNowState.entersViaSendNow == true)
        // Unrelated defaults are untouched by the new trailing init parameter.
        #expect(sendNowState.phase == MigrationSending.State.Phase.sending)
    }

    /// Order spy (mirrors `onAppearWhileSyncingStopsSyncBeforeExecutingScheduledTransfer`'s
    /// idiom): `stopSyncBeforeMigrationBroadcast()` fires BEFORE `sendGate` is ever read. `isSyncing`
    /// is call-counted (true once) so `executeNextTransfer`'s OWN later stop call (once the gate
    /// resolves `.allowed`) is a harmless idempotent no-op rather than a second "stop" log entry.
    @MainActor @Test func onAppearWithSendNowLaneStopsSyncBeforeReadingSendGate() async {
        let callOrder = LockIsolated<[String]>([])
        let isSyncingCallCount = LockIsolated<Int>(0)
        let state = MigrationSending.State(totalCount: 1, entersViaSendNow: true)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                stop: { callOrder.withValue { $0.append("stop") } },
                isSyncing: {
                    isSyncingCallCount.withValue { count -> Bool in
                        count += 1
                        return count == 1
                    }
                }
            )
            $0.migrationManager.sendGate = {
                callOrder.withValue { $0.append("sendGate") }
                return .allowed
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-order-spy") }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.sendNowGateResolved)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-order-spy"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(callOrder.value == ["stop", "sendGate"])
    }

    /// `.allowed` -> broadcasts exactly as today, no WAITING phase ever shows.
    @MainActor @Test func onAppearWithSendNowLaneAndAllowedGateBroadcastsImmediatelyWithoutWaiting() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-send-now") }
            $0.migrationManager.sendGate = { .allowed }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.sendNowGateResolved)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-send-now"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }
    }

    /// `.waitUntil(future)` -> enters `.waiting` with the gate's own target, and does NOT broadcast.
    @MainActor @Test func onAppearWithSendNowLaneAndWaitUntilGateEntersWaitingWithoutBroadcasting() async {
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        $migrationSendWaitActive.withLock { $0 = false }

        let clock = TestClock()
        let executeCalls = LockIsolated<Int>(0)
        let target = Date().addingTimeInterval(543)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-broadcast")
            }
            $0.migrationManager.sendGate = { .waitUntil(target) }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }

        await store.send(.onAppear)
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .waiting(target: target)
        }

        #expect(executeCalls.value == 0)
        #expect(migrationSendWaitActive == true)

        // Drains the pending wait effect cleanly (a real, in-context user action).
        await store.send(.waitCancelTapped)
        await store.receive(.delegate(.closed))
    }

    /// Clock advance past the target -> exactly one broadcast. `sendGate` is call-counted: the
    /// FIRST read (right after the tap) is the normal V8 shape (`.waitUntil`); the SECOND read (at
    /// fire time, once the target has genuinely elapsed) is `.allowed` — a real gate keyed to the
    /// SAME target would read the same way.
    @MainActor @Test func onAppearWithSendNowLaneWaitUntilTargetElapsedBroadcastsExactlyOnce() async {
        let clock = TestClock()
        let executeCalls = LockIsolated<Int>(0)
        let sendGateCallCount = LockIsolated<Int>(0)
        let targetOffset: TimeInterval = 600
        let target = Date().addingTimeInterval(targetOffset)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "tx-after-wait")
            }
            $0.migrationManager.sendGate = {
                sendGateCallCount.withValue { count -> MigrationSendGate in
                    count += 1
                    return count == 1 ? .waitUntil(target) : .allowed
                }
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.onAppear)
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .waiting(target: target)
        }

        #expect(executeCalls.value == 0)

        await clock.advance(by: .seconds(targetOffset))
        await store.receive(\.waitFired)
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .sending
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-after-wait"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(executeCalls.value == 1)
    }

    /// `.syncRequired` immediately after our own stop (a raced settle) -> a single bounded retry,
    /// then the `.waitUntil` path with the fresh value.
    @MainActor @Test func onAppearWithSendNowLaneSyncRequiredSettlesToWaitUntilAfterSingleRetry() async {
        let clock = TestClock()
        let sendGateCallCount = LockIsolated<Int>(0)
        let target = Date().addingTimeInterval(120)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.sendGate = {
                sendGateCallCount.withValue { count -> MigrationSendGate in
                    count += 1
                    return count == 1 ? .syncRequired : .waitUntil(target)
                }
            }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }

        await store.send(.onAppear)
        // Settles the single retry delay (a fixed small duration internal to the store) — advancing
        // generously avoids coupling this test to the exact constant.
        await clock.advance(by: .seconds(1))
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .waiting(target: target)
        }

        #expect(sendGateCallCount.value == 2)

        await store.send(.waitCancelTapped)
        await store.receive(.delegate(.closed))
    }

    /// A `.syncRequired` that's STILL there after the single settle retry (residual block) never
    /// broadcasts — it falls back to a full buffer-duration wait from now, rather than spinning or
    /// treating it as clear.
    @MainActor @Test func onAppearWithSendNowLaneSyncRequiredPersistingAfterRetryFallsBackToBufferDurationWait() async {
        let clock = TestClock()
        let bufferDuration: TimeInterval = 600
        let beforeCall = Date()
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationPrivacySyncBufferDuration = { bufferDuration }
            $0.migrationManager.sendGate = { .syncRequired }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await clock.advance(by: .seconds(1))
        await store.receive(\.sendNowGateResolved)

        guard case .waiting(let target) = store.state.phase else {
            Issue.record("Expected .waiting phase with a buffer-duration fallback target")
            return
        }
        #expect(abs(target.timeIntervalSince(beforeCall) - bufferDuration) < 5)

        await store.send(.waitCancelTapped)
        await store.receive(.delegate(.closed))
    }

    /// Fire-time re-check finding the gate STILL blocked (not `.allowed`) -> re-enters `.waiting`
    /// against the FRESH target, never broadcasting.
    @MainActor @Test func waitFiredWithGateStillBlockedReEntersWaitAgainstFreshTarget() async {
        let clock = TestClock()
        let executeCalls = LockIsolated<Int>(0)
        let sendGateCallCount = LockIsolated<Int>(0)
        let firstTarget = Date().addingTimeInterval(300)
        let secondTarget = Date().addingTimeInterval(900)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1, entersViaSendNow: true)) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-broadcast")
            }
            $0.migrationManager.sendGate = {
                sendGateCallCount.withValue { count -> MigrationSendGate in
                    count += 1
                    return count == 1 ? .waitUntil(firstTarget) : .waitUntil(secondTarget)
                }
            }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }

        await store.send(.onAppear)
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .waiting(target: firstTarget)
        }

        await clock.advance(by: .seconds(300))
        await store.receive(\.waitFired)
        await store.receive(\.sendNowGateResolved) {
            $0.phase = .waiting(target: secondTarget)
        }

        #expect(executeCalls.value == 0)

        await store.send(.waitCancelTapped)
        await store.receive(.delegate(.closed))
    }

    /// Cancel mid-wait: nothing ever broadcasts, the gate feed is nudged to resume sync, the hold
    /// flag clears, and it closes exactly like the success screen's Close (`.delegate(.closed)`).
    @MainActor @Test func waitCancelTappedDuringWaitNeverBroadcastsNudgesGateClearsHoldAndClosesDelegate() async {
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        $migrationSendWaitActive.withLock { $0 = true }

        let clock = TestClock()
        let executeCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        var state = MigrationSending.State(totalCount: 1, entersViaSendNow: true)
        state.phase = .waiting(target: Date().addingTimeInterval(400))
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-broadcast")
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.waitCancelTapped)
        await store.receive(.delegate(.closed))

        #expect(executeCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 1)
        #expect(migrationSendWaitActive == false)
    }

    // MARK: - R8-T6 fix-wave (Minor-1, folded): `.allowed` + nil account must still nudge

    /// M1-a: `.sendNowGateResolved(.allowed)` resolving with a nil selected account (the send-now
    /// lane already stopped sync in `resolveSendGate()`, unlike every other lane's structurally-
    /// safe nil-account guard, which never stops sync before its own nil check) must not leave
    /// sync stopped with no resume nudge — every other send-now exit (broadcast/waitUntil/
    /// syncRequired/cancel) either broadcasts or nudges. Mirrors `.waitCancelTapped`'s exact
    /// clear-then-nudge treatment, minus the navigation `.delegate(.closed)` send (this still
    /// surfaces the ordinary failure sheet instead of closing the screen).
    @MainActor @Test func sendNowGateResolvedAllowedWithNilAccountNudgesGateClearsHoldAndPresentsFailureWithoutBroadcasting() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }
        @Shared(.inMemory(.migrationSendWaitActive)) var migrationSendWaitActive: Bool = false
        $migrationSendWaitActive.withLock { $0 = true }

        let executeCalls = LockIsolated<Int>(0)
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        var state = MigrationSending.State(totalCount: 1, entersViaSendNow: true)
        state.phase = .waiting(target: Date().addingTimeInterval(120))
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "should-not-broadcast")
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
        }

        await store.send(.sendNowGateResolved(.allowed)) {
            $0.phase = .sending
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(executeCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 1)
        #expect(migrationSendWaitActive == false)
    }

    // MARK: - R8-T6: non-send-now lanes unchanged (never consult sendGate, no WAITING phase)

    /// The default (non-send-now) lane — immediate/manual/plan-first review, Keystone, "Migrate
    /// anyway" — stays exactly as it was: never consults `sendGate()`, never shows `.waiting`.
    @MainActor @Test func onAppearWithoutSendNowLaneNeverConsultsSendGateOrEntersWaiting() async {
        let sendGateCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-manual") }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
            $0.migrationManager.sendGate = {
                sendGateCalls.withValue { $0 += 1 }
                return .waitUntil(Date().addingTimeInterval(600))
            }
        }

        await store.send(.onAppear)
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-manual"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(sendGateCalls.value == 0)
    }

    // MARK: - R7-T3 (MOB-1497): R14 first-run Tor choice

    @MainActor @Test func onAppearWithTorUnavailableFirstRunPresentsTorFirstRunChoice() async {
        let capturedFailureClass = LockIsolated<MigrationBroadcastFailureClass?>(nil)
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.routeBroadcastFailure = { _, failureClass in
                capturedFailureClass.setValue(failureClass)
                return MigrationBroadcastFailureRoute.torFirstRunChoice
            }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(capturedFailureClass.value == MigrationBroadcastFailureClass.torUnavailable)
    }

    @MainActor @Test func retryTappedAfterTorFirstRunChoiceKeepsTorAndReExecutesWithoutMutating() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        var state = MigrationSending.State(isFailurePresented: true, totalCount: 1)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-retry") }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-retry"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(overrideTorCalls.value == 0)
    }

    @MainActor @Test func proceedWithoutTorTappedPresentsOffWarningAlertWithGradualMessageOnScheduledPath() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.migrationManager.migrationMode = { _ in MigrationMode.privateScheduled }
        }

        await store.send(.proceedWithoutTorTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        }
    }

    @MainActor @Test func proceedWithoutTorTappedPresentsOffWarningAlertWithFullMessageOnImmediatePath() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.migrationManager.migrationMode = { _ in MigrationMode.immediate }
        }

        await store.send(.proceedWithoutTorTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: true, proceedAction: .offWarningProceedTapped)
        }
    }

    /// Mirrors the real dispatch shape a tap on the "Proceed without Tor" `ButtonState` produces —
    /// see `MigrationTorSheetTests.offWarningProceedTappedClearsAlertAndEmitsDelegateGotItLeavingToggleOff`'s
    /// identical rationale.
    @MainActor @Test func offWarningAlertProceedTappedTurnsTorOffThenRetries() async {
        let overrideTorCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var state = MigrationSending.State(isFailurePresented: true, totalCount: 1)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-offwarn") }
            $0.migrationManager.overrideTorForRun = { accountUUID, useTor in
                overrideTorCalls.withValue { $0.append((accountUUID, useTor)) }
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.alert(.presented(.offWarningProceedTapped)))
        await store.receive(.offWarningProceedTapped) {
            $0.alert = nil
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-offwarn"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(overrideTorCalls.value.count == 1)
        #expect(overrideTorCalls.value.first?.1 == false)
    }

    /// "Keep Tor on" — the alert's cancel-role button carries no explicit action (see
    /// `AlertState.migrationTorOffWarning`'s `ButtonState(role: .cancel, ...)`), so a real tap relies
    /// on the alert's own native dismissal, which resolves to the same bare `.alert(.dismiss)`
    /// simulated directly here. Returns to the R14 sheet unchanged: nothing else mutates.
    @MainActor @Test func alertDismissKeepsTorOnAndReturnsToTheFailureSheetWithZeroMutations() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationSending()
        }

        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureKind == MigrationBroadcastFailureRoute.torFirstRunChoice)
    }

    /// Cancel keeps its existing semantics from the R14 sheet too — no mutation, migration stays
    /// pending.
    @MainActor @Test func cancelTappedFromTorFirstRunChoiceDismissesWithZeroMutations() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        let store = TestStore(initialState: state) {
            MigrationSending()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
    }

    // MARK: - R7-T3 (MOB-1497): R15 mid-run Tor hold

    @MainActor @Test func onAppearWithTorUnavailableMidRunPresentsTorHold() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in throw ZcashError.migrationTorUnavailable }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.torHold }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.torHold
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    /// R15: Retry keeps Tor — same mechanics as R14's retry (no `overrideTorForRun` call).
    @MainActor @Test func retryTappedAfterTorHoldKeepsTorAndReExecutesWithoutMutating() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        var state = MigrationSending.State(isFailurePresented: true, totalCount: 1)
        state.failureKind = MigrationBroadcastFailureRoute.torHold
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "tx-hold-retry") }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-hold-retry"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(overrideTorCalls.value == 0)
    }

    /// R7-review fix (Minor-3): `.proceedWithoutTorTapped` was reachable regardless of `failureKind`
    /// — the R11 warning alert it presents leads to a clearnet retry (`overrideTorForRun(false)`),
    /// exactly the mid-run opt-out R15 forbids. The view never renders the button outside
    /// `.torFirstRunChoice` (defense in depth only, per the report's own admission that this was
    /// wrong to rely on) — this pins the reducer itself: gated to `.torFirstRunChoice`, a no-op
    /// everywhere else. RED against the pre-fix reducer, which presented the alert unconditionally.
    @MainActor @Test func proceedWithoutTorTappedInTorHoldStateIsANoOp() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.torHold
        let store = TestStore(initialState: state) {
            MigrationSending()
        }

        await store.send(.proceedWithoutTorTapped)
    }

    // MARK: - R7-T3 (MOB-1497): R16 within-provider rotation — no new UI

    @MainActor @Test func onAppearWithEndpointUnreachableRotatedSetsFailureKindButKeepsGenericFailureSheet() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.retryRotated }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.retryRotated
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    /// The rotation itself already happened silently inside `routeBroadcastFailure` — retry simply
    /// re-executes, and the execute-time `migrationNetworkOptions` read (mocked here as a sentinel)
    /// picks up whatever the manager now returns.
    @MainActor @Test func retryTappedAfterRotationReExecutesWithTheRotatedOptions() async {
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let rotatedSentinel = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(address: "rotated.example.com", port: 9067)
        )
        var state = MigrationSending.State(isFailurePresented: true, totalCount: 1)
        state.failureKind = MigrationBroadcastFailureRoute.retryRotated
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, options in
                capturedOptions.setValue(options)
                return MigrationTransferResult.success(txId: "tx-rotated")
            }
            $0.migrationManager.migrationNetworkOptions = { _ in rotatedSentinel }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-rotated"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(capturedOptions.value == rotatedSentinel)
    }

    // MARK: - R7-T3 (MOB-1497): R17 provider-exhausted sync-server consent

    @MainActor @Test func onAppearWithProviderExhaustedTorOnPresentsConsentVariant() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true) }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func onAppearWithProviderExhaustedTorOffPresentsConsentVariant() async {
        let store = TestStore(initialState: MigrationSending.State(totalCount: 1)) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false) }
        }

        await store.send(.onAppear)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }
    }

    @MainActor @Test func useSyncServerTappedOverridesThenRetriesInOrder() async {
        let callOrder = LockIsolated<[String]>([])
        var state = MigrationSending.State(isFailurePresented: true, totalCount: 1)
        state.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        let store = TestStore(initialState: state) {
            MigrationSending()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                callOrder.withValue { $0.append("execute") }
                return MigrationTransferResult.success(txId: "tx-syncserver")
            }
            $0.migrationManager.overrideBroadcastEndpointToSyncServer = { _ in
                callOrder.withValue { $0.append("override") }
            }
            $0.migrationManager.migrationNetworkOptions = { _ in
                MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationBGScheduler.scheduleNextWindow = { }
        }

        await store.send(.useSyncServerTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.sentCount = 1
            $0.txId = "tx-syncserver"
        }
        await store.receive(\.allTransfersSent) {
            $0.phase = .success
        }

        #expect(callOrder.value == ["override", "execute"])
    }

    /// "Keep waiting" reuses `cancelTapped`'s exact semantics — dismiss, nothing mutated; the next
    /// failure re-offers the same consent surface.
    @MainActor @Test func cancelTappedFromProviderExhaustedIsKeepWaitingWithZeroMutations() async {
        var state = MigrationSending.State(isFailurePresented: true)
        state.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        let store = TestStore(initialState: state) {
            MigrationSending()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
    }
}
