//
//  MigrationCoordFlowKeystoneScheduleStoreTests.swift
//  zodlTests
//
//  Audit 2026-08-03 (P1): a preps-present Keystone batch used to DEFER its schedule transfers
//  into a `PendingScheduleStore` nothing ever consumed — the flow reported "Migration Scheduled"
//  over transfers that never received their signatures. The store step now persists BOTH halves
//  inline, in one straight line, before the ceremony resumes. These tests pin that line end to
//  end through the real coordinator: the last signing round lands → both stores run with the
//  positionally split slices → the committed schedule records → reconcile → the ceremony
//  resumes. The failure twin pins the honest surface: a schedule-store failure abandons the
//  ceremony (which cancels the stored run) instead of resuming into a success screen.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: installs the process-global `@Shared(.inMemory(.selectedWalletAccount))` the
// coordinator reads — the same shared-state discipline the sibling migration suites hold.
@Suite(.serialized) @MainActor struct MigrationCoordFlowKeystoneScheduleStoreTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0B, count: 16))

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

    /// One preparation (id 0) followed by one schedule transfer (id 4) — `preparationCount: 1`
    /// makes the positional split exactly [prep] / [transfer].
    private static func unsignedBatch() -> [MigrationUnsignedTransferPczt] {
        [
            MigrationUnsignedTransferPczt(id: 0, pczt: Data([0x01]), actions: 4),
            MigrationUnsignedTransferPczt(id: 4, pczt: Data([0x02]), actions: 4)
        ]
    }

    private static func signedBatch() -> [MigrationSignedTransferPczt] {
        [
            MigrationSignedTransferPczt(id: 0, pczt: Data([0x11])),
            MigrationSignedTransferPczt(id: 4, pczt: Data([0x12]))
        ]
    }

    private static func schedule() -> MigrationSchedule {
        MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 1,
            proposalHandle: 7,
            preparations: []
        )
    }

    /// The path shape at the moment the last round's apply lands: the plan (carrying the signed
    /// schedule) beneath `keystoneSign` + `scan` — the exact shape `pendingKeystoneSchedule`
    /// reads at `depthBelowTop: 2` and the resume pops two elements off.
    private static func makeState() -> MigrationCoordFlow.State {
        var state = MigrationCoordFlow.State()
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = schedule()
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsignedBatch())))
        state.path.append(.scan(Scan.State.initial))
        state.pendingKeystoneSigning = .planCommit
        state.pendingKeystoneSigningAccountUUID = accountUUID
        state.keystoneBatchApplyInFlight = true
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(
            rounds: [unsignedBatch()],
            preparationCount: 1
        )
        return state
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The P1 pin: both halves store, split positionally, and the committed schedule records —
    /// no deferral, no drop.
    @Test func lastRoundStoresBothHalvesAndRecordsTheSchedule() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let storedPreps = LockIsolated<[MigrationSignedTransferPczt]>([])
        let storedSchedule = LockIsolated<[MigrationSignedTransferPczt]>([])
        let recordedSchedules = LockIsolated<Int>(0)
        let reconciles = LockIsolated<Int>(0)

        let store = TestStore(initialState: Self.makeState()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate

            var client = MigrationManagerClient.noOp
            client.recordCommittedSchedule = { _, _ in recordedSchedules.withValue { $0 += 1 } }
            client.reconcile = { reconciles.withValue { $0 += 1 } }
            client.armNextWindowNotifications = { _ in }
            client.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager = client

            $0.sdkSynchronizer = .mocked(
                storeSignedNoteSplits: { _, entries in
                    storedPreps.withValue { $0 = entries }
                },
                storeSignedMigrationTransactions: { _, entries in
                    storedSchedule.withValue { $0 = entries }
                }
            )
        }
        store.exhaustivity = .off

        await store.send(
            .keystoneBatchSignaturesApplied(
                context: .planCommit,
                accountUUID: Self.accountUUID,
                unsignedPczts: Self.unsignedBatch(),
                signed: Self.signedBatch()
            )
        )

        await store.receive(
            { action in
                guard case .keystoneSigningSubmitted = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(storedPreps.value.map(\.id) == [0], "the preparation half stores by position")
        #expect(storedSchedule.value.map(\.id) == [4], "the schedule half stores by position — the audit's dropped payload")
        #expect(recordedSchedules.value == 1, "the committed schedule records exactly once")
        await waitUntil { reconciles.value >= 1 }
        #expect(reconciles.value >= 1, "reconcile runs after the stores")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// The honest-failure twin: a schedule-store failure abandons the ceremony (run cancelled,
    /// nothing resumes) rather than landing on "Migration Scheduled" with half a batch stored.
    @Test func scheduleStoreFailureAbandonsInsteadOfResuming() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let recordedSchedules = LockIsolated<Int>(0)
        let scheduleFixture = Self.schedule()

        let store = TestStore(initialState: Self.makeState()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate

            var client = MigrationManagerClient.noOp
            client.recordCommittedSchedule = { _, _ in recordedSchedules.withValue { $0 += 1 } }
            client.reconcile = { }
            $0.migrationManager = client

            $0.sdkSynchronizer = .mocked(
                restartCurrentMigrationStep: { _ in scheduleFixture },
                storeSignedNoteSplits: { _, _ in },
                storeSignedMigrationTransactions: { _, _ in
                    struct StoreFailure: Error { }
                    throw StoreFailure()
                }
            )
        }
        store.exhaustivity = .off

        await store.send(
            .keystoneBatchSignaturesApplied(
                context: .planCommit,
                accountUUID: Self.accountUUID,
                unsignedPczts: Self.unsignedBatch(),
                signed: Self.signedBatch()
            )
        )

        await store.receive(
            { action in
                guard case .keystoneScanAbandoned = action else { return false }
                return true
            },
            timeout: .seconds(5)
        )

        #expect(recordedSchedules.value == 0, "a failed store must never record the schedule as committed")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }
}
