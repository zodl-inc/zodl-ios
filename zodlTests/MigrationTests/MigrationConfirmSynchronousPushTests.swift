//
//  MigrationConfirmSynchronousPushTests.swift
//  zodlTests
//
//  FIELD BUG: the first Confirm tap on a signing transfer plan committed (signed + stored) in
//  well under a second, then the screen sat still — the push to "Migration Scheduled" awaited
//  `migrationSummary`, whose compute path crosses the DB write actor TWICE (`migrationState`'s
//  advance-step read, and `residualAfterMigration`), exactly while the post-commit drive's prove
//  sweep can hold that same actor for seconds per Halo2 chunk. The read-only-reads work never
//  touched either of those two hops, so the stall survived that rebuild intact.
//
//  THE CONTRACT this suite pins: a software `.confirmed` on a signing plan pushes `.scheduled`
//  SYNCHRONOUSLY — the path mutation happens in the reducer handling the delegate itself, built
//  from data already in hand (the just-committed schedule's own numbers, plus a synchronous read
//  of the published snapshot for prior rounds' moved value). The engine is never consulted on the
//  navigation path; that is exactly the shape the `.manual` arm already used. A second contract
//  closes the re-tap window the stall used to invite: once `hasConfirmed` is set, a further
//  `.confirmTapped`/`.retryTapped` is a traced no-op — no auth prompt, no second commit leg.
//
//  Field 2026-08-06: the chain in front of that synchronous push grew one more link. Commit
//  success now latches `hasConfirmed` immediately, then KEEPS the Confirm loader up while the
//  newborn run's first drive (prove + first broadcast, at tip) runs to completion — only once
//  that drive lands (or is skipped mid-sync, deferring to the coming edge) does the chain reach
//  `.scheduleSigned` and fire the same synchronous push above. So: commit → latch → awaited first
//  drive under the loader → synchronous push. A back-out mid-wait passes the leave guard, same as
//  any other already-committed visit — the plan IS committed by the time the drive starts, so
//  leaving forfeits nothing.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationConfirmSynchronousPushTests {
    // MARK: - Fixtures

    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x21, count: 16))

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func transfer(id: UInt32, zatoshi: Int64) -> MigrationTransferProposal {
        MigrationTransferProposal(
            id: id,
            amount: Zatoshi(zatoshi),
            anchorHeight: BlockHeight(3_000_000),
            nextExecutableAfterHeight: BlockHeight(3_000_100),
            expiryHeight: BlockHeight(3_000_140)
        )
    }

    /// Two transfers — 100_000_000 + 250_000_000 = 350_000_000 zatoshi — over an estimated 5h.
    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: [
                transfer(id: 0, zatoshi: 100_000_000),
                transfer(id: 1, zatoshi: 250_000_000)
            ],
            estimatedDurationHours: 5,
            proposalHandle: 1,
            preparations: []
        )
    }

    /// Five transfers of 50_000_000 each — 250_000_000 total, over an estimated 3h. Shaped like
    /// what the recovery refresh-stale lane re-serves: the run's STORED schedule, rebuilt in
    /// place, which can include transfers a PRIOR round already broadcast.
    private static func recoveryRebuiltSchedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: (0..<5).map { transfer(id: UInt32($0), zatoshi: 50_000_000) },
            estimatedDurationHours: 3,
            proposalHandle: 2,
            preparations: []
        )
    }

    private static func snapshot(movedByDoneTransfers: Zatoshi, doneTransfers: Int = 0, totalTransfers: Int) -> MigrationViewSnapshot {
        MigrationViewSnapshot(
            orchardRemaining: .zero,
            ironwoodHeld: .zero,
            movedByDoneTransfers: movedByDoneTransfers,
            doneTransfers: doneTransfers,
            totalTransfers: totalTransfers,
            transfers: [],
            summary: MigrationSummary.zero,
            banner: nil,
            preparations: [],
            planTotal: nil,
            isTorHoldActive: false,
            needsTorFirstRunChoice: false,
            isSubmitting: false,
            sessionOrdinal: 1
        )
    }

    private static func upToDateState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = .upToDate
        state.latestBlockHeight = 4_200_000
        return state
    }

    // MARK: - The fix

    /// THE fix. A software `.confirmed` on a signing plan pushes `.scheduled` SYNCHRONOUSLY — the
    /// path mutation happens in the reducer handling the delegate, with the state built from the
    /// in-hand schedule + the published snapshot; no async receive precedes the push.
    @Test func aConfirmedPlanPushesTheScheduledScreenSynchronously() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = nil }

        var planState = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        planState.schedule = Self.schedule()

        var initialState = MigrationCoordFlow.State.initial
        initialState.path.append(.transferPlan(planState))
        let transferPlanID = initialState.path.ids[0]

        let store = TestStore(initialState: initialState) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.currentMigrationSnapshot = { _ in nil }
            client.armNextWindowNotifications = { _ in }
            client.refreshMigrationSnapshot = { _ in }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        // No `store.receive` before this assertion — the push must already be reflected in the
        // SAME send's resulting state, not arrive later off a queued action.
        await store.send(
            .path(.element(id: transferPlanID, action: .transferPlan(.delegate(.confirmed))))
        ) {
            $0.path.append(.scheduled(MigrationScheduled.State(
                totalAmount: Zatoshi(350_000_000),
                sentCount: 0,
                totalCount: 2,
                durationHours: 5
            )))
        }

        // The trailing effect (window arming + snapshot refresh) is fire-and-forget — it must
        // still be let run to completion so it doesn't leak into a later test.
        await store.finish()
    }

    // MARK: - The builder table

    /// Fresh commit, nil snapshot — schedule-only numbers; nothing has moved before this run.
    @Test func theBuilderUsesScheduleOnlyNumbersWithoutASnapshot() {
        let result = MigrationCoordFlow.scheduledStateNow(schedule: Self.schedule(), snapshot: nil)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(350_000_000),
            sentCount: 0,
            totalCount: 2,
            durationHours: 5
        ))
    }

    /// Multi-round: a snapshot carrying a prior round's cumulative totals folds into BOTH
    /// `totalAmount` (moved value) and `sentCount` (done transfers) alongside this round's fresh
    /// schedule sum/count.
    @Test func theBuilderFoldsPriorRoundsMovedValueAndSentCountFromTheSnapshot() {
        let priorRoundSnapshot = Self.snapshot(movedByDoneTransfers: Zatoshi(300_000), doneTransfers: 4, totalTransfers: 0)
        let result = MigrationCoordFlow.scheduledStateNow(schedule: Self.schedule(), snapshot: priorRoundSnapshot)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(300_000) + Zatoshi(350_000_000),
            sentCount: 4,
            totalCount: 2,
            durationHours: 5
        ))
    }

    /// The recovery refresh-stale lane's own shape: it re-serves the run's STORED schedule,
    /// which can already include transfers a PRIOR round broadcast. `sentCount` must fold the
    /// snapshot's cumulative `doneTransfers` here too — a hardcoded 0 would regress this lane's
    /// success screen to "0 of 5" for a run that had already sent 3.
    @Test func theBuilderCountsAlreadySentTransfersOnARecoveryRefresh() {
        let recoverySnapshot = Self.snapshot(movedByDoneTransfers: Zatoshi(600_000_000), doneTransfers: 3, totalTransfers: 0)
        let result = MigrationCoordFlow.scheduledStateNow(schedule: Self.recoveryRebuiltSchedule(), snapshot: recoverySnapshot)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(600_000_000) + Zatoshi(250_000_000),
            sentCount: 3,
            totalCount: 5,
            durationHours: 3
        ))
    }

    /// No fresh schedule — the snapshot's own totals stand in, and a prior round's moved value
    /// still folds through. Never a crash, never a negative total.
    @Test func theBuilderFallsBackToSnapshotTotalsWithoutASchedule() {
        let noScheduleSnapshot = Self.snapshot(movedByDoneTransfers: Zatoshi(750_000), totalTransfers: 5)
        let result = MigrationCoordFlow.scheduledStateNow(schedule: nil, snapshot: noScheduleSnapshot)

        #expect(result == MigrationScheduled.State(
            totalAmount: Zatoshi(750_000),
            sentCount: 0,
            totalCount: 5,
            durationHours: 0
        ))
    }

    // MARK: - The latch

    /// The latch: once `hasConfirmed` is set, another confirmTapped is a traced no-op — no auth
    /// prompt, no commit leg, no state change. An exhaustive `send` with no trailing closure IS
    /// the pin: any mutation (e.g. `isConfirming` flipping true on the way into the auth gate)
    /// fails it outright.
    @Test func aCommittedPlanIgnoresAnotherConfirmTap() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        state.schedule = Self.schedule()
        state.hasConfirmed = true

        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.confirmTapped)

        await store.finish()
    }

    // MARK: - The drive under the loader

    /// Field 2026-08-06: commit success latches `hasConfirmed` and KEEPS the loader up while the
    /// newborn run's first drive (prove + first broadcast) runs to completion — only then does
    /// `.scheduleSigned` clear the loader and delegate `.confirmed`. The advance must land at
    /// `.afterSync`, once, before `.scheduleSigned` arrives.
    @Test func aCommittedScheduleDrivesTheFirstStepUnderTheLoaderAtTip() async {
        let phases = LockIsolated<[MigrationOpenPhase]>([])
        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        state.schedule = Self.schedule()
        state.isConfirming = true

        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            var manager = MigrationManagerClient.noOp
            manager.advance = { phase in
                phases.withValue { $0.append(phase) }
                return .proved(count: 0)
            }
            $0.migrationManager = manager
            $0.sdkSynchronizer = .mocked(latestState: { Self.upToDateState() })
        }

        await store.send(.scheduleCommitted) {
            $0.hasConfirmed = true
        }
        // MOB-1466 (Lukas, 2026-08-07): the commit landed, so the Scheduling screen goes up FOR the
        // drive rather than after it — the ~30 s below used to be spent on this screen under a
        // button spinner. Asserted here (not skipped with `.off`) because the ORDER is the contract:
        // scheduling BEFORE the drive, `.confirmed` after it.
        await store.receive(.delegate(.scheduling))
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        #expect(phases.value == [MigrationOpenPhase.afterSync])
        await store.receive(.delegate(.confirmed))
    }

    /// Mid-sync the drive is SKIPPED — same guard as Root's G1 case: the coming sync edge owns the
    /// drive, and the loader covers just the commit. `.mocked()`'s default `latestState` is
    /// `SynchronizerState.zero`, which is not `.upToDate`.
    @Test func aCommittedScheduleSkipsTheDriveMidSync() async {
        let phases = LockIsolated<[MigrationOpenPhase]>([])
        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        state.schedule = Self.schedule()
        state.isConfirming = true

        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        } withDependencies: {
            var manager = MigrationManagerClient.noOp
            manager.advance = { phase in
                phases.withValue { $0.append(phase) }
                return .proved(count: 0)
            }
            $0.migrationManager = manager
            $0.sdkSynchronizer = .mocked()
        }

        await store.send(.scheduleCommitted) {
            $0.hasConfirmed = true
        }
        // MOB-1466: the Scheduling screen goes up even when the drive is SKIPPED. It costs a frame
        // mid-sync and it keeps one rule instead of two — the screen follows the COMMIT, never the
        // drive's presence, so there is no path where a commit lands and the user is left on the
        // plan screen wondering.
        await store.receive(.delegate(.scheduling))
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
        #expect(phases.value.isEmpty)
        await store.receive(.delegate(.confirmed))
    }

    /// A back-tap DURING the drive wait (`hasConfirmed` already latched, loader still up) passes the
    /// leave guard silently — the plan IS committed, so there is nothing left to guard. Exhaustive
    /// send with no state closure pins "no sheet, no mutation".
    @Test func aBackTapDuringTheDriveWaitPassesThroughTheLeaveGuard() async {
        var state = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: true)
        state.schedule = Self.schedule()
        state.isConfirming = true
        state.hasConfirmed = true

        let store = TestStore(initialState: state) {
            MigrationTransferPlan()
        }

        await store.send(.backTapped)
        await store.receive(.delegate(.leftWithoutConfirming))
    }
}
