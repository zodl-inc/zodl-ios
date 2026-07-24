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
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                return schedule
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 0, minutesFromNow: 0)
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
            estimatedDurationHours: 12,
            proposalHandle: 1
        )
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(200_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 12
            $0.schedule = schedule
        }
        await store.receive(\.roundContextLoaded)

        #expect(proposeCalls.value == 0)
    }

    // MARK: - MOB-1513 (A2): synthesized split row + transfer renumbering

    /// Default state (no rows loaded yet): no schedule to summarize, so no split row either.
    @MainActor @Test func splitRowIsNilBeforeAnyRowsHaveLoaded() async {
        let state = MigrationTransferPlan.State()

        #expect(state.splitRow == nil)
    }

    /// The defect this fixes: the timeline component used to relabel `rows[0]` (an ORDINARY
    /// crossing transfer) as "Split Balance", showing its own multi-hour ETA/amount instead of the
    /// real note-split's. The split is now a synthesized row the STORE exposes separately from
    /// `rows` — never a third `schedule.transfers` entry — so `rows` stays 1:1 with the schedule
    /// (Transfer 1..N, real per-row ETA `apply` already computed, unchanged) while the split gets
    /// its own truthful amount/status/caption-input.
    @MainActor @Test func onAppearForScheduledVariantSynthesizesSplitRowAheadOfNumberedTransfers() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in schedule }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        await store.receive(\.transfersProposed) {
            // Unchanged from `onAppearWithNoInjectedScheduleProposesTransfersAndPopulatesRows`: the
            // two transfers, 1:1 with `schedule.transfers`, no third "split" entry.
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }

        // Row count stays N (the two transfers above) — the split is the separate synthesized
        // `splitRow`, not an element of `rows`.
        #expect(store.state.rows.count == 2)
        #expect(store.state.splitRow?.kind == MigrationTransferRow.Kind.splitBalance)
        // Android parity: the split row's amount is the SUM of every listed transfer.
        #expect(store.state.splitRow?.amount == Zatoshi(800_000_000))
        // Pre-commit, the split hasn't broadcast yet — `.active`, paired with the timeline's
        // check-style (not numbered) badge for this row specifically.
        #expect(store.state.splitRow?.status == .active)
        // `minutesFromNow == 0` is the Ready-now caption INPUT — the view renders it through the
        // shared `MigrationETA.caption` path (see `MigrationTransferPlanView.caption(for:)`), never
        // a hardcoded string.
        #expect(store.state.splitRow?.minutesFromNow == 0)
    }

    /// `.recreated` is a fresh pre-commit run too (the restart lane) — `apply` carries no
    /// variant branch, so the same split-row treatment applies via the injected-schedule path,
    /// exactly like the fresh-propose path above.
    @MainActor @Test func onAppearForRecreatedVariantWithInjectedScheduleAlsoSynthesizesSplitRow() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(600_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(150_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150)
            ],
            estimatedDurationHours: 12,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(600_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(150_000_000), status: .pending, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 12
            $0.schedule = schedule
        }
        await store.receive(\.roundContextLoaded)

        #expect(store.state.splitRow?.kind == MigrationTransferRow.Kind.splitBalance)
        #expect(store.state.splitRow?.amount == Zatoshi(750_000_000))
        #expect(store.state.splitRow?.status == .active)
        #expect(store.state.splitRow?.minutesFromNow == 0)
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
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                called.setValue(true)
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)

        #expect(called.value == false)
    }

    // MARK: - MOB-1513 (B3): minute-precise forward ETA from the live chain tip

    /// B3 root cause: `apply` converted a transfer's execution height via `estimateTimestamp`, which
    /// returns nil for every FUTURE height (beyond the newest bundled checkpoint) — floored to 0,
    /// rendered as the "~10 mins" fallback. The fix derives a block delta against the LIVE chain tip
    /// (`latestState().latestBlockHeight`) at 75 s/block: a transfer 96 blocks ahead of the tip is
    /// exactly 120 minutes (2 hours) out. A ready-at-tip transfer is 0.
    @MainActor @Test func onAppearComputesMinutePreciseForwardETAFromChainTipNotEstimateTimestamp() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 1_000, nextExecutableAfterHeight: 1_000, expiryHeight: 2_000),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 1_000, nextExecutableAfterHeight: 1_096, expiryHeight: 2_000)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let tipState: SynchronizerState = {
            var state = SynchronizerState.zero
            state.latestBlockHeight = 1_000
            return state
        }()
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            // `latestState` is a non-`@DependencyClient` `let` — replace the whole client via
            // `.mocked(...)` (noOp defaults otherwise), then layer the `var` overrides.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(latestState: { tipState })
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in schedule }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 2, minutesFromNow: 120)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }
    }

    // MARK: - confirmTapped: sign + store, then delegate

    @MainActor @Test func confirmTappedSignsAndStoresScheduleThenEmitsDelegateConfirmed() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
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
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
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
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(.delegate(.keystoneSignRequested(pczts))) {
            $0.isConfirming = false
        }

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
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(.delegate(.keystoneSignRequested(pczts))) {
            $0.isConfirming = false
        }

        #expect(proposeCalls.value == 1)
    }

    @MainActor @Test func confirmTappedWithZcashAccountUsesSoftwarePathUnchanged() async {
        let proposeCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
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

    // MARK: - MOB-1513 (B4): the confirm chain signs only — no broadcast, no proving, no Tor

    /// B4 reorder ("everything signed at once, splits execute immediately, transfers per
    /// offsets"): the confirm chain is USK -> `signAndStoreMigrationSchedule` (the sign-only
    /// atomic commit, which signs every transfer AND any note-split preparation layers straight
    /// from the plan cache the schedule's own propose call wrote) -> `recordCommittedSchedule` ->
    /// `reconcile`. The monolithic `submitNoteSplit` (proving + inline Tor bootstrap + broadcast —
    /// the multi-second, DB-actor-blocking freeze QA hit) and its
    /// `stopSyncBeforeMigrationBroadcast` companion are gone from this chain entirely: the first
    /// prep broadcasts AFTER navigation, via the coordinator's background kick.
    ///
    /// MOB-1513 (F1-A1): the confirm-time note-split propose must never collide with the schedule
    /// it is about to sign. The real SDK holds ONE proposal-handle slot per account —
    /// `NoteSplitProposal.proposalHandle`/`MigrationSchedule.proposalHandle`'s shared doc: "the
    /// native side refuses to sign any plan other than the one it identifies — throwing
    /// `migrationPlanStale` when a later propose/prepare call superseded it" — modeled here as a
    /// shared `LockIsolated` slot seeded with the displayed `schedule`'s own handle.
    /// `signAndStoreMigrationSchedule`'s mock throws `ZcashError.migrationPlanStale` whenever the
    /// schedule it is handed no longer matches the slot, exactly like the real echo-validated
    /// commit — the blind spot the old version of this test had (a stateless mock that always
    /// succeeded regardless of which handle it saw, so it couldn't tell a real SDK would reject
    /// the sequence it was pinning). `commitSoftware` must sign+store the ORIGINAL displayed
    /// schedule without ever superseding its own handle first — proven here by reaching
    /// `.scheduleSigned`/`.delegate(.confirmed)` rather than the plan-stale recovery path
    /// (`.planStaleRefreshed`, a toast instead of a commit).
    @MainActor @Test func confirmTappedWithNoteSplitNeededCommitsWithoutSelfInflictedPlanStale() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        // The engine's single per-account plan-cache slot, seeded with the handle the user was
        // actually shown. ANY propose/prepare call for the account overwrites this slot — the real
        // contract shared by every `proposalHandle` doc in the SDK.
        let planCacheHandle = LockIsolated<UInt64>(schedule.proposalHandle)
        let prepareNoteSplitCalls = LockIsolated<Int>(0)
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
            $0.sdkSynchronizer.prepareNoteSplit = { _ in
                prepareNoteSplitCalls.withValue { $0 += 1 }
                // The real engine mints a FRESH handle for the note-split-only plan it just
                // cached — superseding whatever the slot held before, same as the real
                // single-slot plan cache.
                planCacheHandle.setValue(2)
                return NoteSplitProposal(outputNotes: [Zatoshi(500_000_000)], fee: Zatoshi(100_000), proposalHandle: 2)
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, schedule, _ in
                guard schedule.proposalHandle == planCacheHandle.value else {
                    throw ZcashError.migrationPlanStale
                }
                signedSchedule.setValue(schedule)
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
        #expect(prepareNoteSplitCalls.value == 0)
        #expect(recordCommittedScheduleCalls.value == 1)
        #expect(reconcileCalls.value == 1)
    }

    /// B4 (controller resolution 4): a thrown `signAndStoreMigrationSchedule` persists NOTHING —
    /// the app records no schedule, no reconcile runs, the user stays on the plan with the
    /// existing failure sheet, and Retry re-attempts the commit (whose `prepareNoteSplit` is
    /// itself a fresh propose-side cache write).
    @MainActor @Test func confirmTappedCommitFailureRecordsNothingAndRetryReattemptsTheCommit() async {
        struct CommitFailure: Error { }
        let signCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in false }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                let call = signCalls.withValue {
                    $0 += 1
                    return $0
                }
                if call == 1 {
                    throw CommitFailure()
                }
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(reconcileCalls.value == 0)

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 2)
        #expect(recordCommittedScheduleCalls.value == 1)
        #expect(reconcileCalls.value == 1)
    }


    @MainActor @Test func confirmTappedWithNoteSplitNotNeededSkipsSplitAndSignsDirectly() async {
        let prepareCalls = LockIsolated<Int>(0)
        // MOB-1496 (R8-T1, S3): non-empty — Confirm now guards against a zero-transfer schedule.
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
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
                return NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero, proposalHandle: 0)
            }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in }
            // MOB-1496 (W2): see `confirmTappedForManualVariantSignsAndStoresScheduleThenEmitsDelegateConfirmed`'s comment.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))

        #expect(prepareCalls.value == 0)
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
            estimatedDurationHours: 24,
            proposalHandle: 1
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
            $0.isConfirming = true
            $0.isFailurePresented = false
        }
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
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
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _, _ in
                proposeOrder.withValue { $0.append("split") }
                return [MigrationUnsignedTransferPczt(id: "p0", pczt: splitPczt)]
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeOrder.withValue { $0.append("schedule") }
                return schedulePczts
            }
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(.delegate(.keystoneSignRequested(expectedBatch))) {
            $0.isConfirming = false
        }

        #expect(proposeOrder.value == ["split", "schedule"])
        // W6 review Minor (sentinel drift guard, W7): the literal three independent sites use
        // (here, this producer, and `MigrationReviewTransferStore`'s twin) must not silently drift
        // apart — pin this producer's real, emitted id against the coordinator's own constant.
        #expect(expectedBatch.first?.id == MigrationCoordFlow.keystoneNoteSplitSentinelPrefix + "p0")
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
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in throw ProposeFailure() }
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signAndStoreCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
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
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let state = MigrationTransferPlan.State(variant: .scheduled)
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                let call = proposeCalls.withValue {
                    $0 += 1
                    return $0
                }
                if call == 1 {
                    throw ProposeFailure()
                }
                return schedule
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.propose
        }

        await store.send(.retryTapped) {
            $0.isConfirming = true
            $0.isFailurePresented = false
            $0.failureReason = nil
        }
        await store.receive(\.transfersProposed) {
            $0.isConfirming = false
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }

        #expect(proposeCalls.value == 2)
    }

    @MainActor @Test func confirmTappedWithZeroTransferScheduleNeverSigns() async {
        let signAndStoreCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
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
        state.schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
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
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 21) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _, _ in throw ProposeFailure() }
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
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
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    @MainActor @Test func confirmTappedWithKeystoneAccountWhenPCZTBatchComesBackEmptyPresentsFailureSheetWithoutDelegating() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
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

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    // MARK: - MOB-1511 (W2): multi-round label

    /// The display rule: round 1 with no known total stays label-free; a later round (or a known
    /// multi-round estimate) shows the label; an estimate of exactly one run clears it back off.
    @MainActor @Test func roundContextLoadedAppliesTheDisplayRule() async {
        let store = TestStore(initialState: MigrationTransferPlan.State()) {
            MigrationTransferPlan()
        }

        await store.send(.roundContextLoaded(round: 1, totalRounds: nil))

        await store.send(.roundContextLoaded(round: 2, totalRounds: nil)) {
            $0.round = 2
        }

        await store.send(.roundContextLoaded(round: 1, totalRounds: 4)) {
            $0.round = 1
            $0.totalRounds = 4
        }

        await store.send(.roundContextLoaded(round: 1, totalRounds: 1)) {
            $0.round = nil
            $0.totalRounds = nil
        }
    }

    // MARK: - MOB-1513 (B4): confirm loading + single-flight

    /// QA 2026-07-22 (B4 symptom 1): tapping Confirm froze the UI with no feedback and a second tap
    /// spawned a CONCURRENT commit (the plan-cache overwrite race behind the `MIGRATION_PLAN_STALE`
    /// error sheet). The fix is a loading flag (`isConfirming`, driving the button's
    /// disabled+spinner state) plus a single-flight guard: a second `.confirmTapped` while a commit
    /// is in flight must be a complete no-op — no second effect, no second SDK call.
    @MainActor @Test func confirmTappedSetsIsConfirmingAndIgnoresSecondTapWhileCommitInFlight() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let signCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                signCalls.withValue { $0 += 1 }
                // Hold the commit in flight until the test releases it.
                for await _ in releaseStream { break }
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        // Second tap while the commit is in flight: a complete no-op — no state change, no second
        // effect (exhaustive TestStore would fail on any unasserted mutation or extra receive).
        await store.send(.confirmTapped)

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 1)
    }

    /// A failed commit must clear the loading flag alongside presenting the failure sheet, so
    /// Retry is tappable again.
    @MainActor @Test func confirmTappedFailureClearsIsConfirmingAlongsidePresentingFailureSheet() async {
        struct CommitFailure: Error { }
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in throw CommitFailure() }
            // Unlocks the no-testValue `migrationManager` client for this test (the commit effect
            // captures it) — the thrown sign+store means no member is actually reached.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }
    }

    /// The Keystone propose leg gets the same treatment: `isConfirming` while the PCZT batch is
    /// being proposed, single-flight against a second tap, cleared once the batch is handed to the
    /// coordinator (`.delegate(.keystoneSignRequested)`) so a later pop-back re-enables Confirm.
    @MainActor @Test func confirmTappedKeystoneSetsIsConfirmingAndIgnoresSecondTapWhileProposeInFlight() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let proposeCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 9) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _, _ in
                proposeCalls.withValue { $0 += 1 }
                for await _ in releaseStream { break }
                return []
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0x01]))]
            }
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.send(.confirmTapped)

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(.delegate(.keystoneSignRequested([MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0x01]))]))) {
            $0.isConfirming = false
        }

        #expect(proposeCalls.value == 1)
    }

    /// A propose-failure Retry (`failureReason == .propose`) re-proposes — that leg shows the same
    /// loader and clears it when the fresh proposal lands (or fails again).
    @MainActor @Test func retryTappedAfterProposeFailureSetsIsConfirmingUntilFreshProposalLands() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(200_000_000), anchorHeight: 50, nextExecutableAfterHeight: 50, expiryHeight: 150)
            ],
            estimatedDurationHours: 12,
            proposalHandle: 1
        )
        var state = MigrationTransferPlan.State()
        state.isFailurePresented = true
        state.failureReason = MigrationTransferPlan.State.FailureReason.propose
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in schedule }
        }

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureReason = nil
            $0.isConfirming = true
        }
        await store.receive(\.transfersProposed) {
            $0.isConfirming = false
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(200_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 12
            $0.schedule = schedule
        }
    }

    // MARK: - MOB-1513 (E2-FIX): bounded quiet retry at entry when the wallet isn't ready yet

    /// E2 window: right after a restore the propose comes back with an EMPTY schedule (the engine's
    /// non-throwing "nothing to migrate yet / nothing due" answer while notes aren't witnessable).
    /// Instead of silently populating an empty plan (today's behavior), the entry propose stays
    /// quietly in its loading state and re-proposes on the clock, only surfacing the EXISTING
    /// propose-failure sheet once the bounded window expires.
    @MainActor @Test func onAppearWhenProposeReturnsEmptyScheduleRetriesQuietlyThenSurfacesOnExpiry() async {
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        // Quiet: neither an empty plan nor a failure sheet appears on the first empty outcome.
        #expect(store.state.isFailurePresented == false)
        #expect(store.state.rows.isEmpty)

        await clock.advance(by: .seconds(3))
        #expect(store.state.isFailurePresented == false)

        // Past the bounded window: the existing propose-failure sheet finally surfaces.
        await clock.advance(by: .seconds(120))
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.propose
        }

        #expect(proposeCalls.value >= 2)
        #expect(store.state.schedule == nil)
    }

    /// A later attempt within the window returns a non-empty schedule → rows populate and the flow
    /// proceeds exactly as a first-attempt success would, with no failure sheet ever shown.
    @MainActor @Test func onAppearWhenEmptyScheduleThenBecomesAvailableProposesOnLaterAttempt() async {
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                let call = proposeCalls.withValue {
                    $0 += 1
                    return $0
                }
                if call < 3 {
                    return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
                }
                return schedule
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        #expect(store.state.isFailurePresented == false)

        await clock.advance(by: .seconds(3))
        await clock.advance(by: .seconds(3))
        await store.receive(\.transfersProposed) {
            $0.rows = [
                MigrationTransferRow(id: "t0", index: 0, amount: Zatoshi(500_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0),
                MigrationTransferRow(id: "t1", index: 1, amount: Zatoshi(300_000_000), status: .pending, hoursFromNow: 0, minutesFromNow: 0)
            ]
            $0.totalDurationHours = 24
            $0.schedule = schedule
        }

        #expect(store.state.isFailurePresented == false)
        #expect(proposeCalls.value == 3)
    }

    /// Conservative classification: a propose THROW (as opposed to the non-throwing empty schedule)
    /// is a genuine failure — it surfaces immediately through the existing error path, with zero
    /// retries.
    @MainActor @Test func onAppearWhenProposeThrowsNonWindowErrorSurfacesImmediatelyWithoutRetrying() async {
        struct HardFailure: Error { }
        let clock = TestClock()
        let proposeCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationTransferPlan.State(variant: .scheduled)) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.continuousClock = clock
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeCalls.withValue { $0 += 1 }
                throw HardFailure()
            }
            $0.migrationManager.migrationRoundContext = { _ in (1, nil) }
        }

        await store.send(.onAppear)
        await store.receive(\.roundContextLoaded)
        await store.receive(\.transferProposalFailed) {
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.propose
        }

        #expect(proposeCalls.value == 1)
    }

    // MARK: - MOB-1458 (Task 3): migrationPlanStale defensive recovery on the pre-commit consent-echo paths

    /// `ZcashError.migrationPlanStale` from the software commit's consent echo
    /// (`signAndStoreMigrationSchedule`) is caught SPECIFICALLY — instead of the generic
    /// `.noteSplitFailed` failure sheet, a fresh `proposeMigrationTransfers` re-propose silently
    /// replaces the displayed (now-stale) schedule, and a toast tells the user to review it
    /// before re-confirming. Nothing is signed or stored (`recordCommittedSchedule`/`reconcile`
    /// never called).
    ///
    /// Toast is `@Shared(.inMemory(.toast))` — following the established codebase idiom for
    /// asserting it (`WalletBirthdayTests`/`AddressDetailsTests`), this test turns exhaustivity
    /// off and asserts the resulting state via `#expect` instead of the trailing closure.
    @MainActor @Test func confirmTappedWhenCommitThrowsMigrationPlanStaleReProposesFreshScheduleShowsNoticeAndCommitsNothing() async {
        let staleSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "stale", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let freshSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "fresh", amount: Zatoshi(400_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 20,
            proposalHandle: 1
        )
        let signCalls = LockIsolated<Int>(0)
        let proposeCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State()
        state.schedule = staleSchedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in
                signCalls.withValue { $0 += 1 }
                throw ZcashError.migrationPlanStale
            }
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeCalls.withValue { $0 += 1 }
                return freshSchedule
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            withDependenciesUSKDerivable(&$0)
        }
        store.exhaustivity = .off

        await store.send(.confirmTapped)
        await store.receive(\.planStaleRefreshed)

        #expect(store.state.schedule == freshSchedule)
        #expect(
            store.state.rows == [
                MigrationTransferRow(id: "fresh", index: 0, amount: Zatoshi(400_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0)
            ]
        )
        #expect(store.state.totalDurationHours == 20)
        #expect(store.state.isConfirming == false)
        #expect(store.state.isFailurePresented == false)
        #expect(store.state.toast == .topDelayed(String(localizable: .migrationPlanStaleRefreshed)))
        #expect(signCalls.value == 1)
        #expect(proposeCalls.value == 1)
        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(reconcileCalls.value == 0)
    }

    /// MOB-1458 (final review I1): the Keystone propose leg's plan-stale recovery RESTARTS (not
    /// re-proposes). `proposeKeystoneBatch`'s run-creating `proposeNoteSplitPCZTs` means a plain
    /// re-propose can never converge on the committed run (infinite toast loop), so the Keystone catch
    /// calls `restartCurrentMigrationStep` — which both cancels any stranded run AND returns a fresh,
    /// committable preview — and feeds its schedule through the SAME `.planStaleRefreshed` apply+toast.
    /// (The stateless `proposeNoteSplitPCZTs → []` mock can't reproduce the non-convergence itself; the
    /// achievable, load-bearing assertion is the pinned call CHOICE: restart, never re-propose.)
    @MainActor @Test func confirmTappedWithKeystoneAccountWhenProposeMigrationPCZTsThrowsMigrationPlanStaleRestartsFreshScheduleShowsNoticeWithoutDelegating() async {
        let staleSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "stale", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let freshSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "fresh", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 18,
            proposalHandle: 1
        )
        let proposeMigrationPCZTsCalls = LockIsolated<Int>(0)
        let restartCalls = LockIsolated<Int>(0)
        let proposeMigrationTransfersCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = staleSchedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 30) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposeMigrationPCZTsCalls.withValue { $0 += 1 }
                throw ZcashError.migrationPlanStale
            }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return freshSchedule
            }
            // Pinned NOT to be called on the Keystone leg — a re-propose here would loop forever.
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeMigrationTransfersCalls.withValue { $0 += 1 }
                return freshSchedule
            }
        }
        store.exhaustivity = .off

        await store.send(.confirmTapped)
        await store.receive(\.planStaleRefreshed)

        #expect(store.state.schedule == freshSchedule)
        #expect(
            store.state.rows == [
                MigrationTransferRow(id: "fresh", index: 0, amount: Zatoshi(300_000_000), status: .active, hoursFromNow: 0, minutesFromNow: 0)
            ]
        )
        #expect(store.state.isConfirming == false)
        #expect(store.state.isFailurePresented == false)
        #expect(store.state.toast == .topDelayed(String(localizable: .migrationPlanStaleRefreshed)))
        #expect(proposeMigrationPCZTsCalls.value == 1)
        #expect(restartCalls.value == 1)
        #expect(proposeMigrationTransfersCalls.value == 0)
    }

    /// Regression: a DIFFERENT `ZcashError` case on the software commit path — proving the new
    /// catch clause is scoped to `.migrationPlanStale` specifically, not "any `ZcashError`" — keeps
    /// today's generic failure-sheet handling and never re-proposes.
    @MainActor @Test func confirmTappedWhenCommitThrowsADifferentZcashErrorKeepsExistingFailureHandling() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State()
        state.schedule = schedule
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in throw ZcashError.migrationSyncBlocked }
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeCalls.withValue { $0 += 1 }
                return schedule
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            withDependenciesUSKDerivable(&$0)
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }

        #expect(proposeCalls.value == 0)
    }

    /// Regression: same specificity proof on the Keystone propose leg — a different `ZcashError`
    /// case from `proposeMigrationPCZTs` still routes to the existing failure sheet, never
    /// re-proposing.
    @MainActor @Test func confirmTappedWithKeystoneAccountWhenProposeThrowsADifferentZcashErrorKeepsExistingFailureHandling() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24,
            proposalHandle: 1
        )
        let proposeTransfersCalls = LockIsolated<Int>(0)
        var state = MigrationTransferPlan.State(variant: .scheduled)
        state.schedule = schedule
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 31) }
        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in throw ZcashError.migrationSyncBlocked }
            $0.sdkSynchronizer.proposeMigrationTransfers = { _ in
                proposeTransfersCalls.withValue { $0 += 1 }
                return schedule
            }
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.noteSplitFailed) {
            $0.isConfirming = false
            $0.isFailurePresented = true
            $0.failureReason = MigrationTransferPlan.State.FailureReason.commit
        }

        #expect(proposeTransfersCalls.value == 0)
    }
}
