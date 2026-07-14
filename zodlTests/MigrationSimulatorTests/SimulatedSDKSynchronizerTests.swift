//
//  SimulatedSDKSynchronizerTests.swift
//  zodlTests
//
//  Covers `SDKSynchronizerClient.applySimulatedMigration` (MOB-1480,
//  `SDKSynchronizerClient+Simulated.swift`): builds a base client whose migration members (plus
//  `estimateTimestamp`) are SENTINEL closures — never `.noOp`'s bare inert values, so a fallback
//  to "original" is unambiguously distinguishable both by a fixed, obviously-fake return value AND
//  by a call counter (the primary signal — some sentinel values legitimately collide with what a
//  freshly-seeded engine would also answer, e.g. both can plausibly answer `false` for
//  `isNoteSplitNeeded`). Applies the simulated migration against a fresh engine over
//  `MigrationSimulatorStateStore.ephemeral()` and asserts, for a representative spread of members:
//  active-engine behavior, and that `setActive(false)` restores every one of them to the sentinel.
//  Constructs `SDKSynchronizerClient`/`MigrationSimulatorEngine` directly — never touches
//  `MigrationSimulatorClient.sharedEngine` or `liveValue` — mirroring `MigrationSDKStubTests`'
//  precedent, so those pinned `.noOp`/`.mocked()` contract tests stay untouched and green.
//
//  `MigrationManagerResetPersistedFlagsTests` below is `.serialized` because it's the one part of
//  this file that touches `UserDefaults` (even via isolated named suites — same reasoning as
//  `MigrationManagerTests.swift`'s class-level doc comment); the rest of the file has no
//  shared/global state and runs unserialized.
//

import Testing
import Foundation
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture
import URKit
@testable import zodl_internal

@Suite struct SimulatedSDKSynchronizerTests {
    /// Fixed, obviously-fake sentinel values — never a value the engine itself would plausibly
    /// produce for the scenarios below — so a return-value check alone would already catch a
    /// wiring mistake, independent of the call counters.
    private enum SentinelValues {
        static let migrationState = MigrationState.complete
        static let migrationSchedule = MigrationSchedule(transfers: [], estimatedDurationHours: -1)
        static let transferResult = TransferResult.invalidNote
        static let transferRow = MigrationTransferRow(
            id: "sentinel-row", index: 0, amount: Zatoshi(1), status: MigrationTransferRow.Status.sent, hoursFromNow: 0
        )
        static let pczt: Pczt = Data([0xFF])
        static let parsedBatch: [Pczt] = [Data([0xAB, 0xCD])]
        static let estimatedTimestamp: TimeInterval = 999_999
    }

    /// One call counter per sentinel closure — see the file header for why this is the primary
    /// "did the override call through to `original`" signal.
    private struct CallCounters: Sendable {
        let getMigrationState = LockIsolated<Int>(0)
        let migrationStateStream = LockIsolated<Int>(0)
        let isNoteSplitNeeded = LockIsolated<Int>(0)
        let proposeMigrationTransfers = LockIsolated<Int>(0)
        let signAndStoreMigrationSchedule = LockIsolated<Int>(0)
        let executeNextPendingMigrationTransfer = LockIsolated<Int>(0)
        let migrationTransfers = LockIsolated<Int>(0)
        let proposeMigrationPCZTs = LockIsolated<Int>(0)
        let parseMigrationPCZTBatch = LockIsolated<Int>(0)
        let urEncoderForMigrationPCZTBatch = LockIsolated<Int>(0)
        let estimateTimestamp = LockIsolated<Int>(0)
    }

    private static let networkPrivacy = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)

    private func makeBaseClient(_ counters: CallCounters) -> SDKSynchronizerClient {
        var client = SDKSynchronizerClient.noOp

        client.getMigrationState = {
            counters.getMigrationState.withValue { $0 += 1 }
            return SentinelValues.migrationState
        }
        client.migrationStateStream = {
            counters.migrationStateStream.withValue { $0 += 1 }
            return Just(SentinelValues.migrationState).eraseToAnyPublisher()
        }
        client.isNoteSplitNeeded = {
            counters.isNoteSplitNeeded.withValue { $0 += 1 }
            return false
        }
        client.proposeMigrationTransfers = {
            counters.proposeMigrationTransfers.withValue { $0 += 1 }
            return SentinelValues.migrationSchedule
        }
        client.signAndStoreMigrationSchedule = { _ in
            counters.signAndStoreMigrationSchedule.withValue { $0 += 1 }
        }
        client.executeNextPendingMigrationTransfer = { _ in
            counters.executeNextPendingMigrationTransfer.withValue { $0 += 1 }
            return SentinelValues.transferResult
        }
        client.migrationTransfers = {
            counters.migrationTransfers.withValue { $0 += 1 }
            return [SentinelValues.transferRow]
        }
        client.proposeNoteSplitPCZT = { SentinelValues.pczt }
        client.proposeMigrationPCZTs = { _ in
            counters.proposeMigrationPCZTs.withValue { $0 += 1 }
            return [SentinelValues.pczt]
        }
        client.parseMigrationPCZTBatch = { _ in
            counters.parseMigrationPCZTBatch.withValue { $0 += 1 }
            return SentinelValues.parsedBatch
        }
        client.urEncoderForMigrationPCZTBatch = { _ in
            counters.urEncoderForMigrationPCZTBatch.withValue { $0 += 1 }
            // The payload must beat FountainEncoder's minFragmentLen (10 bytes) — a shorter
            // message makes UREncoder's fragment-count range 1...0, which traps at runtime.
            guard let ur = try? UR(type: "sentinel-ur", cbor: CBOR.bytes(Data(repeating: 0x5A, count: 64))) else { return nil }
            return UREncoder(ur, maxFragmentLen: 200)
        }
        client.estimateTimestamp = { _ in
            counters.estimateTimestamp.withValue { $0 += 1 }
            return SentinelValues.estimatedTimestamp
        }

        return client
    }

    // MARK: - State (getMigrationState / migrationStateStream)

    @Test func stateMembersRouteThroughTheEngineWhenActiveAndFallBackWhenInactive() {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        client.applySimulatedMigration(engine: engine)

        // Active: reads the engine's real (fresh-seeded) state, never the sentinel.
        #expect(client.getMigrationState() == MigrationState.notStarted)
        #expect(counters.getMigrationState.value == 0)

        // Active: a live CurrentValueSubject that re-ticks on state changes (the improvement over
        // HEAD's one-shot `Just`), not the sentinel stream.
        let collected = LockIsolated<[MigrationState]>([])
        let cancellable = client.migrationStateStream().sink { state in
            collected.withValue { $0.append(state) }
        }
        engine.applyPreset(SimulatorPreset.splitting)
        engine.confirmSplitNow()
        #expect(collected.value.contains(MigrationState.splitPendingConfirmation))
        #expect(collected.value.contains(MigrationState.readyToPropose))
        #expect(counters.migrationStateStream.value == 0)
        cancellable.cancel()

        // Inactive: both fall back to the sentinel originals.
        engine.setActive(false)
        #expect(client.getMigrationState() == SentinelValues.migrationState)
        #expect(counters.getMigrationState.value == 1)

        _ = client.migrationStateStream()
        #expect(counters.migrationStateStream.value == 1)
    }

    // MARK: - Note splitting (isNoteSplitNeeded)

    @Test func isNoteSplitNeededRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        client.applySimulatedMigration(engine: engine)

        // Fresh engine default (privateScheduled / notStarted / 1 note) answers true; the sentinel
        // always answers false, so a true here proves the engine (not the sentinel) answered.
        #expect(client.isNoteSplitNeeded() == true)
        #expect(counters.isNoteSplitNeeded.value == 0)

        engine.setActive(false)
        #expect(client.isNoteSplitNeeded() == false)
        #expect(counters.isNoteSplitNeeded.value == 1)
    }

    // MARK: - propose -> signAndStore -> executeNext round trip + transferRows

    @Test func proposeSignAndStoreExecuteNextRoundTripAndTransferRows() async {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.selectMode(MigrationMode.immediate)
        client.applySimulatedMigration(engine: engine)

        let schedule = await client.proposeMigrationTransfers()
        #expect(schedule != SentinelValues.migrationSchedule)
        #expect(schedule.transfers.count == 1)
        #expect(counters.proposeMigrationTransfers.value == 0)

        await client.signAndStoreMigrationSchedule(schedule)
        #expect(counters.signAndStoreMigrationSchedule.value == 0)

        let result = await client.executeNextPendingMigrationTransfer(Self.networkPrivacy)
        #expect(counters.executeNextPendingMigrationTransfer.value == 0)
        guard case .some(TransferResult.success) = result else {
            Issue.record("Expected the immediate-mode transfer to be due right away and succeed")
            return
        }

        let rows = client.migrationTransfers()
        #expect(counters.migrationTransfers.value == 0)
        #expect(rows.count == 1)
        #expect(rows.first?.status == MigrationTransferRow.Status.sent)

        // Inactive: every member above falls back to the sentinel.
        engine.setActive(false)

        let inactiveSchedule = await client.proposeMigrationTransfers()
        #expect(inactiveSchedule == SentinelValues.migrationSchedule)
        #expect(counters.proposeMigrationTransfers.value == 1)

        await client.signAndStoreMigrationSchedule(inactiveSchedule)
        #expect(counters.signAndStoreMigrationSchedule.value == 1)

        let inactiveResult = await client.executeNextPendingMigrationTransfer(Self.networkPrivacy)
        #expect(inactiveResult == SentinelValues.transferResult)
        #expect(counters.executeNextPendingMigrationTransfer.value == 1)

        let inactiveRows = client.migrationTransfers()
        #expect(inactiveRows == [SentinelValues.transferRow])
        #expect(counters.migrationTransfers.value == 1)
    }

    // MARK: - Keystone (PCZT fabrication + batch parse round trip)

    @Test func keystonePCZTsFabricatedWhenActiveAndParseRoundTripsRecognizedHeader() async {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        client.applySimulatedMigration(engine: engine)

        let noteSplitPCZT = await client.proposeNoteSplitPCZT()
        #expect(!noteSplitPCZT.isEmpty)
        #expect(noteSplitPCZT != SentinelValues.pczt)

        let schedule = await client.proposeMigrationTransfers()
        let batch = await client.proposeMigrationPCZTs(schedule)
        #expect(!batch.isEmpty)
        #expect(batch.allSatisfy { !$0.isEmpty })
        #expect(counters.proposeMigrationPCZTs.value == 0)

        // Active + recognized fabricated-format header -> returns the whole batch as one element.
        let fabricated = engine.fabricateNoteSplitPCZT()
        #expect(client.parseMigrationPCZTBatch(fabricated) == [fabricated])
        #expect(counters.parseMigrationPCZTBatch.value == 0)

        // Active but NOT the fabricated format -> falls through to original, same as inactive.
        let unrecognized = Data([0x00, 0x01])
        #expect(client.parseMigrationPCZTBatch(unrecognized) == SentinelValues.parsedBatch)
        #expect(counters.parseMigrationPCZTBatch.value == 1)

        // Inactive: every member above falls back to the sentinel.
        engine.setActive(false)

        let inactiveNoteSplitPCZT = await client.proposeNoteSplitPCZT()
        #expect(inactiveNoteSplitPCZT == SentinelValues.pczt)

        let inactiveBatch = await client.proposeMigrationPCZTs(schedule)
        #expect(inactiveBatch == [SentinelValues.pczt])
        #expect(counters.proposeMigrationPCZTs.value == 1)

        #expect(client.parseMigrationPCZTBatch(fabricated) == SentinelValues.parsedBatch)
        #expect(counters.parseMigrationPCZTBatch.value == 2)
    }

    /// Deliberately does NOT exercise the active path with a non-empty batch: that path calls the
    /// real `KeystoneZcashSDK().generateZcashPczt` with fabricated (not spec-valid) bytes, and
    /// while the Swift-visible contract is "throws on rejection" (caught via `try?`), this is a
    /// native FFI boundary whose crash-safety on malformed input isn't something this unit test
    /// can verify without risking the whole run. Covered instead by Phase C's planned manual smoke
    /// of the panel/Keystone sign screen in the testnet simulator (spec §11) — flagged in the
    /// final report for that verification.
    @Test func urEncoderForMigrationPCZTBatchEmptyBatchIsNilActiveAndFallsBackWhenInactive() {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        client.applySimulatedMigration(engine: engine)

        // Active + empty batch -> nil without reaching KeystoneSDK/URKit or the sentinel.
        #expect(client.urEncoderForMigrationPCZTBatch([]) == nil)
        #expect(counters.urEncoderForMigrationPCZTBatch.value == 0)

        // Inactive -> always the sentinel's (always-constructible) encoder, regardless of input.
        engine.setActive(false)
        #expect(client.urEncoderForMigrationPCZTBatch([]) != nil)
        #expect(counters.urEncoderForMigrationPCZTBatch.value == 1)
    }

    // MARK: - estimateTimestamp (synthetic-height translation + real-height passthrough)

    @Test func estimateTimestampTranslatesSyntheticHeightsAndPassesThroughRealLookingOnes() {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        client.applySimulatedMigration(engine: engine)

        let syntheticHeight = MigrationSimulatorEngineDerivations.syntheticHeight(for: Date())
        let realLookingHeight = BlockHeight(3_000_000)

        // Active + synthetic height -> translated back to (approximately) the original timestamp.
        guard let syntheticResult = client.estimateTimestamp(syntheticHeight) else {
            Issue.record("Expected a non-nil timestamp for a synthetic height while the engine is active")
            return
        }
        #expect(abs(syntheticResult - Date().timeIntervalSince1970) < 5)
        #expect(counters.estimateTimestamp.value == 0)

        // Active + real-looking (non-synthetic) height -> passes straight through to the sentinel.
        #expect(client.estimateTimestamp(realLookingHeight) == SentinelValues.estimatedTimestamp)
        #expect(counters.estimateTimestamp.value == 1)

        // Inactive -> always the sentinel, even for a synthetic-looking height.
        engine.setActive(false)
        #expect(client.estimateTimestamp(syntheticHeight) == SentinelValues.estimatedTimestamp)
        #expect(counters.estimateTimestamp.value == 2)
    }

    // MARK: - isNextTransferDue hook (MigrationManagerLiveKey's simulated hook)
    //
    // `MigrationManagerLiveKey.isNextTransferDue()`'s simulated branch reads the process-wide
    // `MigrationSimulatorClient.sharedEngine` singleton and is `private`, so it isn't independently
    // unit-testable from this file without touching global state. `MigrationSimulatorEngineTests`
    // already covers the engine-level `isNextTransferDue()` API that hook delegates to
    // (`isNextTransferDueFalseUntilEarliestUnsentTransferMatures`,
    // `isNextTransferDueFalseOutsideInProgressState`). The seam directly testable from here — and
    // the one actually chosen — is the pure derivation underneath both:
    // `MigrationSimulatorEngineDerivations.isNextTransferDue(snapshot:now:)`.

    @Test func isNextTransferDueDerivationMatchesTheSimulatedHookContract() {
        var snapshot = SimulatorSnapshot.seeded()
        snapshot.transfers = [
            SimulatorTransfer(id: "xfer-0", index: 0, amount: Zatoshi(1), dueAt: Date().addingTimeInterval(-1))
        ]
        snapshot.state = MigrationState.inProgress(
            MigrationProgress(completedTransfers: 0, totalTransfers: 1, remainingOrchard: Zatoshi(1), nextTransferReadyAtHeight: nil)
        )
        #expect(MigrationSimulatorEngineDerivations.isNextTransferDue(snapshot: snapshot, now: Date()) == true)

        snapshot.transfers = [
            SimulatorTransfer(id: "xfer-0", index: 0, amount: Zatoshi(1), dueAt: Date().addingTimeInterval(3600))
        ]
        #expect(MigrationSimulatorEngineDerivations.isNextTransferDue(snapshot: snapshot, now: Date()) == false)
    }
}

// MARK: - resetPersistedFlags (UserDefaults-backed; dedicated serialized suite)

@Suite(.serialized)
struct MigrationManagerResetPersistedFlagsTests {
    @Test func gateStorageResetPersistedFlagsClearsEveryNamedFlagButLeavesTheSyncGateWindow() throws {
        let suiteName = "testGateStorageResetPersistedFlagsClearsEveryNamedFlagButLeavesTheSyncGateWindow"
        let userDefaults = try #require(
            UserDefaults(suiteName: suiteName),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.setMigrationMode(MigrationMode.immediate)
        storage.setManualDelivery(true)
        storage.setNetworkPrivacyOptions(NetworkPrivacyOptions(useTor: true, submissionEndpoint: "https://example.com:9067"))
        storage.acknowledgeComplete()
        storage.recordMigrationBroadcast(at: Date())
        storage.recordSyncCompletion(at: Date())

        storage.resetPersistedFlags()

        #expect(storage.migrationMode() == nil)
        #expect(storage.isManualDelivery() == false)
        #expect(storage.networkPrivacyOptions() == NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil))
        #expect(storage.isCompleteAcknowledged() == false)
        #expect(storage.isSyncDeferredAfterBroadcast(now: Date()) == false)

        // Deliberately untouched: the 10-minute sync<->send gate window is a short-lived timing
        // value, not a durable app flag (see `resetPersistedFlags`'s doc comment).
        guard case MigrationSendGate.waitUntil = storage.sendGate(now: Date()) else {
            Issue.record("Expected the sync<->send gate window to survive resetPersistedFlags")
            return
        }
    }

    @Test func migrationManagerImplResetPersistedFlagsDelegatesToGateStorage() throws {
        let suiteName = "testMigrationManagerImplResetPersistedFlagsDelegatesToGateStorage"
        let userDefaults = try #require(
            UserDefaults(suiteName: suiteName),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        storage.setMigrationMode(MigrationMode.privateScheduled)
        storage.setManualDelivery(true)

        let impl = MigrationManagerImpl(gateStorage: storage)
        impl.resetPersistedFlags()

        #expect(storage.migrationMode() == nil)
        #expect(storage.isManualDelivery() == false)
    }
}
