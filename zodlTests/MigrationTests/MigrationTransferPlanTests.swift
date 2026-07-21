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
    /// MOB-1496: `migrationManager.migrationNetworkOptions(_:)` has no macro default (unlike the SDK
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
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule,
        // so this test's actual concern (manual variant signs+stores+delegates) needs a real one.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
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
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule
        // (no Keystone delegate either), so this test's actual concern (recreated variant proposes
        // PCZTs and delegates) needs a real one.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
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
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
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
        // R9-T2 (finding 4): the landed split's own had-broadcast recording — must fire BEFORE
        // `signAndStoreMigrationSchedule`, or a later mid-run Tor outage would still route the R14
        // first-run offer R15 forbids mid-run, and the R15 hold indicator would stay dark.
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
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
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                callOrder.withValue { $0.append("recordTransferBroadcast") }
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(callOrder.value == ["prepare", "submit", "recordTransferBroadcast", "signAndStore"])
        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: "split-tx-id"))
    }

    @MainActor @Test func confirmTappedWithNoteSplitNotNeededSkipsSplitAndSignsDirectly() async {
        let prepareCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
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
        // MOB-1496 (R8-T4, #3): the split broadcast stopped sync without ever reaching a successful
        // outcome — the T1 shared commit helper (`MigrationCommitPipeline.commitSoftware`) must
        // nudge Root's app-side gate feed directly (the SDK's own gate only transitions on SUCCESS).
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        // R9-T2 (finding 3): `.networkError(retryable: true)` is now classifiable (`.endpointUnreachable`)
        // — the pipeline classifies+routes it via commit 1's entry point before surfacing the failure.
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        // R9-T2 (finding 4): a genuine split FAILURE never landed — `recordTransferBroadcast` must
        // stay uncalled (it's additive to the success/landed continuations only).
        let recordTransferBroadcastCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule
        // BEFORE the commit effect even runs; this test's actual concern (a genuine split failure)
        // needs a real schedule to reach that effect at all.
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
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            // R9-T2 (finding 3): R16's rotation is silent — `.retryRotated` keeps the generic sheet
            // copy, matching this test's original (pre-routing) "generic failure sheet" intent.
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.retryRotated
            }
            $0.migrationManager.recordTransferBroadcast = { _, _ in recordTransferBroadcastCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        // R9-T2 (finding 3): a classifiable split failure now routes FIRST — mirrors
        // `MigrationSendingStore`/`MigrationNoteSplitStore`'s "route first" ordering.
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.retryRotated
        }
        // MOB-1496 (R8-T1): `.noteSplitFailed` now also tags `failureReason` so Retry knows to
        // re-attempt the commit (not re-propose).
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }

        #expect(signCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 1)
        #expect(routeBroadcastFailureCalls.value == 1)
        #expect(recordTransferBroadcastCalls.value == 0)
    }

    /// R9-T2 (finding 3): the THROWN-error twin of the result-path test above —
    /// `ZcashError.migrationTorUnavailable` classifies as `.torUnavailable` and routes to R14's
    /// first-run choice; the gate is nudged exactly once, same as any other non-landed split failure.
    @MainActor @Test func confirmTappedWithThrownNoteSplitErrorRoutesAndNudgesGateBeforePresentingFailureSheet() async {
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        let capturedFailureClass = LockIsolated<MigrationBroadcastFailureClass?>(nil)
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
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in throw ZcashError.migrationTorUnavailable }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, failureClass in
                capturedFailureClass.setValue(failureClass)
                return MigrationBroadcastFailureRoute.torFirstRunChoice
            }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.torFirstRunChoice
        }
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }

        #expect(capturedFailureClass.value == MigrationBroadcastFailureClass.torUnavailable)
        #expect(refreshMigrationSyncGateCalls.value == 1)
    }

    /// R9-T2 (finding 3): a non-classifiable split RESULT (`.invalidNote`/`.expired`/non-retryable
    /// `.networkError`) never reaches the `routeBroadcastFailure` closure member at all (commit 1's
    /// entry point contract) — `failureKind` stays `nil`, so the shared failure-sheet component keeps
    /// today's generic copy unchanged. (A thrown error can't hit this path beyond the already-pinned
    /// `migrationRecordFailedAfterBroadcast` carve-out below — every OTHER thrown error classifies as
    /// `.endpointUnreachable`, never `nil`; see `MigrationBroadcastFailureClass.classify(error:)`.)
    @MainActor @Test func confirmTappedWithUnroutableSplitResultPresentsGenericFailureSheetWithoutRouting() async {
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
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
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.invalidNote }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }

        #expect(routeBroadcastFailureCalls.value == 0)
        #expect(store.state.failureKind == nil)
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
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
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

    // MOB-1478 (W4): the Keystone fork's batch now carries any preparation (note-split) PCZTs first —
    // proved via proposal ORDER (preps proposed before the schedule's own PCZTs). MOB-1496 (final
    // engine, plural preps): `proposeKeystoneBatch` folds `proposeNoteSplitPCZTs` unconditionally now
    // (no more `isNoteSplitNeeded` gate on the Keystone side) — each returned prep rides the batch
    // under a `keystoneNoteSplitSentinelPrefix` + its own engine id (typed-payload disambiguation —
    // see `requestKeystoneSignature`'s doc).
    @MainActor @Test func confirmTappedWithKeystoneAccountAndNoteSplitNeededProposesSplitPcztBeforeSchedulePCZTs() async {
        let proposeOrder = LockIsolated<[String]>([])
        let splitPczt = Data([0x01])
        let schedulePczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let expectedBatch = [
            MigrationUnsignedTransferPczt(id: MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p0", pczt: splitPczt)
        ] + schedulePczts
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule
        // (no Keystone delegate either); this test's actual concern (split PCZT proposed first) is
        // otherwise unaffected by the schedule's own content, which the propose mocks ignore.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in
                proposeOrder.withValue { $0.append("split") }
                return [MigrationUnsignedTransferPczt(id: "p0", pczt: splitPczt)]
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeOrder.withValue { $0.append("schedule") }
                return schedulePczts
            }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.keystoneSignRequested(expectedBatch)))

        #expect(proposeOrder.value == ["split", "schedule"])
        // W6 review Minor (sentinel drift guard, W7): the literal three independent sites use
        // (here, this producer, and `MigrationReviewTransferStore`'s twin) must not silently drift
        // apart — pin this producer's real, emitted id against the coordinator's own constant.
        #expect(expectedBatch.first?.id == MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p0")
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
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
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
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(stopCalls.value == 0)
    }

    // MARK: - MOB-1496 (R8-T1, S3): honest propose failures — no silent empty-schedule fallback

    @MainActor @Test func onAppearWhenProposeThrowsPresentsFailureSheetLeavesScheduleNilAndConfirmSignsNothing() async {
        struct ProposeFailure: Error { }
        let signAndStoreCalls = LockIsolated<Int>(0)
        let state = MigrationTransferPlan.State(variant: .scheduled)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, _ in throw ProposeFailure() }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signAndStoreCalls.withValue { $0 += 1 } }
        }

        await store.send(.onAppear)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.propose
        }

        #expect(store.state.schedule == nil)
        #expect(store.state.rows.isEmpty)

        // Confirm must not proceed: no signAndStore reachable with a nil schedule. Tapping it also
        // dismisses the (already showing) failure affordance, same as any other confirm/retry tap.
        await store.send(.confirmTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }

        #expect(signAndStoreCalls.value == 0)
    }

    @MainActor @Test func retryTappedAfterProposeFailureReProposesAndClearsFailureStateOnSuccess() async {
        struct ProposeFailure: Error { }
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let state = MigrationTransferPlan.State(variant: .scheduled)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, _ in
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
            $0.failureReason = MigrationTransferPlan.State.FailureReason.propose
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }

        #expect(proposeCalls.value == 2)
    }

    @MainActor @Test func confirmTappedWithZeroTransferScheduleNeverSigns() async {
        let signAndStoreCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signAndStoreCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)

        #expect(signAndStoreCalls.value == 0)
    }

    @MainActor @Test func confirmTappedWithKeystoneAccountAndZeroTransferScheduleNeverDelegates() async {
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 19) }
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

        #expect(proposeCalls.value == 0)
    }

    // MARK: - MOB-1496 (R8-T1, #1): a landed-but-unrecorded note split is not retried with a fresh
    // conflicting split — see this task's report for the full engine trace behind this decision.

    @MainActor @Test func confirmTappedWhenSubmitNoteSplitRecordFailsAfterBroadcastProceedsToSignAndStoreSchedule() async {
        struct RecordFailure: Error { }
        let submitNoteSplitCalls = LockIsolated<Int>(0)
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T4, #3): the broadcast DID land here (only recording failed) — treated
        // exactly like `.success`, so this must NOT nudge the gate feed.
        let refreshMigrationSyncGateCalls = LockIsolated<Int>(0)
        // R9-T2 (finding 3): PRESERVE THIS CARVE-OUT EXACTLY — a landed broadcast is never a failure
        // to route, so `routeBroadcastFailure` must stay uncalled on this path.
        let routeBroadcastFailureCalls = LockIsolated<Int>(0)
        // R9-T2 (finding 4): this IS a landed split (only the engine's own recording failed) —
        // mirrors `MigrationNoteSplitStore`'s identical `recordTransferBroadcast` call for this same
        // carve-out, with the synthetic `.success(txId: "")` result (the error carries no payload to
        // recover the real txId from).
        let recordTransferBroadcastCalls = LockIsolated<[(AccountUUID?, MigrationTransferResult)]>([])
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
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000)) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in
                submitNoteSplitCalls.withValue { $0 += 1 }
                throw ZcashError.migrationRecordFailedAfterBroadcast(RecordFailure())
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, schedule, _ in signedSchedule.setValue(schedule) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationManager.refreshMigrationSyncGate = { refreshMigrationSyncGateCalls.withValue { $0 += 1 } }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeBroadcastFailureCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            $0.migrationManager.recordTransferBroadcast = { accountUUID, result in
                recordTransferBroadcastCalls.withValue { $0.append((accountUUID, result)) }
            }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        // Exactly one submit attempt — the landed-but-unrecorded outcome is NEVER retried with a
        // fresh (conflicting) split, and the schedule IS stored (continuation (a) — see report).
        #expect(submitNoteSplitCalls.value == 1)
        #expect(signedSchedule.value == schedule)
        #expect(recordCommittedScheduleCalls.value == 1)
        #expect(reconcileCalls.value == 1)
        #expect(routeBroadcastFailureCalls.value == 0)
        #expect(refreshMigrationSyncGateCalls.value == 0)
        #expect(recordTransferBroadcastCalls.value.count == 1)
        #expect(recordTransferBroadcastCalls.value.first?.1 == MigrationTransferResult.success(txId: ""))
    }

    // MARK: - MOB-1496 (R8-T1, #4): Keystone propose failures surface instead of dead-ending
    //
    // MOB-1496 (final engine, plural preps): the OLD `confirmTappedWithKeystoneAccountWhenIsNoteSplit
    // NeededThrowsPresentsFailureSheetWithoutDelegating` test (mocking `isNoteSplitNeeded` to throw) is
    // deleted rather than adapted — `proposeKeystoneBatch` no longer consults `isNoteSplitNeeded` at
    // all (the unconditional fold below), so that scenario can no longer occur on this path; the test
    // below (mocking the NEW first call, `proposeNoteSplitPCZTs`, to throw) is its replacement as the
    // "first propose call in the fold fails" case.

    @MainActor @Test func confirmTappedWithKeystoneAccountWhenProposeNoteSplitPCZTsThrowsPresentsFailureSheetWithoutDelegating() async {
        struct ProposeFailure: Error { }
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 21) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _ in throw ProposeFailure() }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    @MainActor @Test func confirmTappedWithKeystoneAccountWhenProposeMigrationPCZTsThrowsPresentsFailureSheetWithoutDelegating() async {
        struct ProposeFailure: Error { }
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 22) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in throw ProposeFailure() }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    @MainActor @Test func confirmTappedWithKeystoneAccountWhenPCZTBatchComesBackEmptyPresentsFailureSheetWithoutDelegating() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 23) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in [] }
        }

        await store.send(.confirmTapped)
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    // MARK: - R9-T2 (finding 3): TransferPlan adopts the SAME R14-R17 failure surfaces Sending does

    private func routedFailureState(
        schedule: MigrationSchedule,
        failureKind: MigrationBroadcastFailureRoute
    ) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        state.isFailurePresented = true
        state.failureReason = MigrationTransferPlan.State.FailureReason.commit
        state.failureKind = failureKind
        return state
    }

    private static let retrySchedule = MigrationSchedule(
        transfers: [
            MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
        ],
        estimatedDurationHours: 24
    )

    // MARK: R14: first-run Tor choice

    @MainActor @Test func retryTappedAfterTorFirstRunChoiceReattemptsWithoutOverridingTor() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torFirstRunChoice)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(overrideTorCalls.value == 0)
    }

    @MainActor @Test func proceedWithoutTorTappedPresentsOffWarningAlertWithGradualMessage() async {
        // Scheduled commits are never full-balance (only the immediate lane is) — unlike
        // Sending/NoteSplit, this never reads `migrationManager.migrationMode()`.
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torFirstRunChoice)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.proceedWithoutTorTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: MigrationTransferPlan.Action.offWarningProceedTapped)
        }
    }

    /// Mirrors the real dispatch shape a tap on the "Proceed without Tor" `ButtonState` produces —
    /// see `MigrationTorSheetTests.offWarningProceedTappedClearsAlertAndEmitsDelegateGotItLeavingToggleOff`'s
    /// identical rationale.
    @MainActor @Test func offWarningAlertProceedTappedTurnsTorOffThenReattemptsCommit() async {
        let overrideTorCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torFirstRunChoice)
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: MigrationTransferPlan.Action.offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.overrideTorForRun = { accountUUID, useTor in
                overrideTorCalls.withValue { $0.append((accountUUID, useTor)) }
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.alert(.presented(.offWarningProceedTapped)))
        await store.receive(.offWarningProceedTapped) {
            $0.alert = nil
            $0.isFailurePresented = false
            $0.failureKind = nil
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(overrideTorCalls.value.count == 1)
        #expect(overrideTorCalls.value.first?.1 == false)
    }

    /// "Keep Tor on" — the alert's cancel-role button carries no explicit action (see
    /// `AlertState.migrationTorOffWarning`), relying on the alert's own native dismissal, which
    /// resolves to the same bare `.alert(.dismiss)` simulated directly here. Returns to the R14 sheet
    /// unchanged: nothing else mutates.
    @MainActor @Test func alertDismissKeepsTorOnAndReturnsToTheFailureSheetWithZeroMutations() async {
        var state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torFirstRunChoice)
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: MigrationTransferPlan.Action.offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.alert(.dismiss)) {
            $0.alert = nil
        }

        #expect(store.state.isFailurePresented == true)
        #expect(store.state.failureKind == MigrationBroadcastFailureRoute.torFirstRunChoice)
    }

    @MainActor @Test func cancelTappedClearsFailureKindAlongsideTheFailureSheet() async {
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torFirstRunChoice)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
            $0.failureKind = nil
        }
    }

    // MARK: R15: mid-run Tor hold

    /// R15: Retry keeps Tor — same mechanics as R14's retry (no `overrideTorForRun` call).
    @MainActor @Test func retryTappedAfterTorHoldReattemptsWithoutOverridingTor() async {
        let overrideTorCalls = LockIsolated<Int>(0)
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torHold)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.overrideTorForRun = { _, _ in overrideTorCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(overrideTorCalls.value == 0)
    }

    /// R7-review fix (Minor-3) parity: `.proceedWithoutTorTapped` is gated to `.torFirstRunChoice`
    /// only — the R11 warning it presents leads to a clearnet retry, exactly the mid-run opt-out R15
    /// forbids.
    @MainActor @Test func proceedWithoutTorTappedInTorHoldStateIsANoOp() async {
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.torHold)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.proceedWithoutTorTapped)
    }

    // MARK: R16: within-provider rotation — no new UI, retry simply re-attempts

    /// The rotation itself already happened silently inside `routeBroadcastFailure` — retry simply
    /// re-attempts the whole commit, and the fresh `migrationNetworkOptions` read (mocked here as a
    /// sentinel) picks up whatever the manager now returns.
    @MainActor @Test func retryTappedAfterRotationReattemptsTheCommitWithFreshOptions() async {
        let capturedOptions = LockIsolated<MigrationNetworkPrivacyOptions?>(nil)
        let rotatedSentinel = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(address: "rotated.example.com", port: 9067)
        )
        let state = routedFailureState(schedule: Self.retrySchedule, failureKind: MigrationBroadcastFailureRoute.retryRotated)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000)) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, options in
                capturedOptions.setValue(options)
                return MigrationTransferResult.success(txId: "tx-rotated")
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            $0.migrationManager.migrationNetworkOptions = { _ in rotatedSentinel }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(capturedOptions.value == rotatedSentinel)
    }

    // MARK: R17: provider-exhausted sync-server consent

    @MainActor @Test func confirmTappedWithProviderExhaustedResultRoutesAndSetsFailureKind() async {
        var state = MigrationTransferPlan.State()
        state.schedule = Self.retrySchedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
            $0.sdkSynchronizer.submitNoteSplit = { _, _, _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true) }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped)
        await store.receive(\.broadcastFailureRouted) {
            $0.failureKind = MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        }
        await store.receive(\.noteSplitFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    @MainActor @Test func useSyncServerTappedOverridesThenReattemptsCommitInOrder() async {
        let callOrder = LockIsolated<[String]>([])
        let state = routedFailureState(
            schedule: Self.retrySchedule,
            failureKind: MigrationBroadcastFailureRoute.providerExhausted(torEnabled: true)
        )
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                callOrder.withValue { $0.append("signAndStore") }
            }
            $0.migrationManager.overrideBroadcastEndpointToSyncServer = { _ in
                callOrder.withValue { $0.append("override") }
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.useSyncServerTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(callOrder.value == ["override", "signAndStore"])
    }

    /// "Keep waiting" reuses `cancelTapped`'s exact semantics — dismiss, nothing mutated; the next
    /// failure re-offers the same consent surface.
    @MainActor @Test func cancelTappedFromProviderExhaustedIsKeepWaitingWithZeroMutations() async {
        let state = routedFailureState(
            schedule: Self.retrySchedule,
            failureKind: MigrationBroadcastFailureRoute.providerExhausted(torEnabled: false)
        )
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
            $0.failureKind = nil
        }
    }
}
