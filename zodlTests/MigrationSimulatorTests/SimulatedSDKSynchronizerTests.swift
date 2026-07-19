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
//  `MigrationSimulatorClient.sharedEngine` or `liveValue` — mirroring the deleted
//  `MigrationSDKStubTests`' precedent, so pinned `.noOp`/`.mocked()` contract tests stay untouched
//  and green.
//
//  MOB-1496: reshaped for the real, per-account, throwing SDK surface. `migrationStateStream` and
//  `migrationTransfers` (both covered here pre-MOB-1496) are GONE from `SDKSynchronizerClient`
//  entirely — the former had no real-SDK counterpart (a per-account `stateEvents` replaced it,
//  owned by `MigrationManagerClient`, which reach-arounds the engine directly in
//  `MigrationManagerLiveKey.swift`, outside this file's `applySimulatedMigration` wiring
//  altogether); the latter relocated the same way. Their coverage is accordingly dropped here, not
//  replaced — `MigrationManagerLiveKey`'s reach-around isn't independently unit-testable from this
//  file without touching the process-wide `MigrationSimulatorClient.sharedEngine` singleton (same
//  reasoning the `isNextTransferDue` section below already documents for a sibling case).
//  `proposeMigrationTransfers`'s simulated override now unconditionally selects `.privateScheduled`
//  mode (mirroring the real SDK's WHICH-function-you-call distinction — see
//  `SDKSynchronizerClient+Simulated.swift`'s file doc) and `proposeImmediateMigration` selects
//  `.immediate` — so the round-trip test below drives its deterministic single-transfer path
//  through `proposeImmediateMigration`, not `proposeMigrationTransfers`.
//
//  `MigrationManagerResetPersistedFlagsTests` below is `.serialized` because it's the one part of
//  this file that touches `UserDefaults` (even via isolated named suites — same reasoning as
//  `MigrationManagerTests.swift`'s class-level doc comment); the rest of the file has no
//  shared/global state and runs unserialized.
//

import Testing
import Foundation
@preconcurrency import Combine
@testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
import URKit
@testable import zodl_internal

@Suite struct SimulatedSDKSynchronizerTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0, count: 16))

    /// Fixed, obviously-fake sentinel values — never a value the engine itself would plausibly
    /// produce for the scenarios below — so a return-value check alone would already catch a
    /// wiring mistake, independent of the call counters.
    private enum SentinelValues {
        static let migrationState = MigrationState.complete
        static let migrationSchedule = MigrationSchedule(transfers: [], estimatedDurationHours: -1)
        static let transferResult = MigrationTransferResult.invalidNote
        static let pczt: Data = Data([0xFF])
        static let unsignedBatch: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "sentinel", pczt: Data([0xFF]))]
        static let parsedBatch: [Data] = [Data([0xAB, 0xCD])]
        static let estimatedTimestamp: TimeInterval = 999_999
    }

    /// One call counter per sentinel closure — see the file header for why this is the primary
    /// "did the override call through to `original`" signal.
    private struct CallCounters: Sendable {
        let getMigrationState = LockIsolated<Int>(0)
        let isNoteSplitNeeded = LockIsolated<Int>(0)
        let proposeMigrationTransfers = LockIsolated<Int>(0)
        let proposeImmediateMigration = LockIsolated<Int>(0)
        let signAndStoreMigrationSchedule = LockIsolated<Int>(0)
        let executeNextPendingMigrationTransfer = LockIsolated<Int>(0)
        let proposeMigrationPCZTs = LockIsolated<Int>(0)
        let parseMigrationPCZTBatch = LockIsolated<Int>(0)
        let urEncoderForMigrationPCZTBatch = LockIsolated<Int>(0)
        let estimateTimestamp = LockIsolated<Int>(0)
    }

    private static let networkPrivacy = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )

    /// `UnifiedSpendingKey` has no public initializer anywhere in the SDK — derive a real (test)
    /// one from `StoredWallet.placeholder`'s seed, matching the established repo-wide pattern
    /// (`MigrationTransferPlanTests`' `withDependenciesUSKDerivable` and siblings). The simulated
    /// `signAndStoreMigrationSchedule` override never actually inspects this value (see
    /// `SDKSynchronizerClient+Simulated.swift` — the active branch calls `engine.signAndStore
    /// (schedule)`, which takes no USK at all), so any validly-derived key works here.
    private func usk() throws -> UnifiedSpendingKey {
        try MigrationSpendingKeyDerivation.deriveUSK(
            zip32AccountIndex: Zip32AccountIndex(0),
            walletStorage: WalletStorageClient.noOp,
            mnemonic: MnemonicClient.mock,
            derivationTool: DerivationToolClient.liveValue,
            networkType: NetworkType.testnet
        )
    }

    private func makeBaseClient(_ counters: CallCounters) -> SDKSynchronizerClient {
        var client = SDKSynchronizerClient.noOp

        client.getMigrationState = { _ in
            counters.getMigrationState.withValue { $0 += 1 }
            return SentinelValues.migrationState
        }
        client.isNoteSplitNeeded = { _ in
            counters.isNoteSplitNeeded.withValue { $0 += 1 }
            return false
        }
        client.proposeMigrationTransfers = { _, _ in
            counters.proposeMigrationTransfers.withValue { $0 += 1 }
            return SentinelValues.migrationSchedule
        }
        client.proposeImmediateMigration = { _ in
            counters.proposeImmediateMigration.withValue { $0 += 1 }
            return SentinelValues.migrationSchedule
        }
        client.signAndStoreMigrationSchedule = { _, _, _ in
            counters.signAndStoreMigrationSchedule.withValue { $0 += 1 }
        }
        client.executeNextPendingMigrationTransfer = { _, _ in
            counters.executeNextPendingMigrationTransfer.withValue { $0 += 1 }
            return SentinelValues.transferResult
        }
        client.proposeNoteSplitPCZT = { _ in SentinelValues.pczt }
        client.proposeMigrationPCZTs = { _, _ in
            counters.proposeMigrationPCZTs.withValue { $0 += 1 }
            return SentinelValues.unsignedBatch
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

    // MARK: - State (getMigrationState)
    //
    // MOB-1496: `migrationStateStream` is gone from `SDKSynchronizerClient` (no real-SDK
    // counterpart — see the file header) — this section now covers `getMigrationState` alone.

    @Test func getMigrationStateRoutesThroughTheEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        // Active: reads the engine's real (fresh-seeded) state, never the sentinel.
        #expect(try await client.getMigrationState(Self.accountUUID) == MigrationState.notStarted)
        #expect(counters.getMigrationState.value == 0)

        // Inactive: falls back to the sentinel original.
        engine.setActive(false)
        #expect(try await client.getMigrationState(Self.accountUUID) == SentinelValues.migrationState)
        #expect(counters.getMigrationState.value == 1)
    }

    // MARK: - Note splitting (isNoteSplitNeeded)

    @Test func isNoteSplitNeededRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        // Fresh engine default (privateScheduled / notStarted / 1 note) answers true; the sentinel
        // always answers false, so a true here proves the engine (not the sentinel) answered.
        #expect(try await client.isNoteSplitNeeded(Self.accountUUID) == true)
        #expect(counters.isNoteSplitNeeded.value == 0)

        engine.setActive(false)
        #expect(try await client.isNoteSplitNeeded(Self.accountUUID) == false)
        #expect(counters.isNoteSplitNeeded.value == 1)
    }

    // MARK: - proposeMigrationTransfers: forces .privateScheduled mode when active

    @Test func proposeMigrationTransfersRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        let schedule = try await client.proposeMigrationTransfers(Self.accountUUID, false)
        #expect(schedule != SentinelValues.migrationSchedule)
        // Scheduled mode splits into 3-5 notes (RNG-driven) — not a fixed count, unlike immediate.
        #expect((3...5).contains(schedule.transfers.count))
        #expect(counters.proposeMigrationTransfers.value == 0)

        engine.setActive(false)
        let inactiveSchedule = try await client.proposeMigrationTransfers(Self.accountUUID, false)
        #expect(inactiveSchedule == SentinelValues.migrationSchedule)
        #expect(counters.proposeMigrationTransfers.value == 1)
    }

    // MARK: - proposeImmediateMigration -> signAndStore -> executeNext round trip

    @Test func proposeImmediateSignAndStoreExecuteNextRoundTrip() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        let schedule = try await client.proposeImmediateMigration(Self.accountUUID)
        #expect(schedule != SentinelValues.migrationSchedule)
        #expect(schedule.transfers.count == 1)
        #expect(counters.proposeImmediateMigration.value == 0)

        try await client.signAndStoreMigrationSchedule(Self.accountUUID, schedule, try usk())
        #expect(counters.signAndStoreMigrationSchedule.value == 0)

        let result = try await client.executeNextPendingMigrationTransfer(Self.accountUUID, Self.networkPrivacy)
        #expect(counters.executeNextPendingMigrationTransfer.value == 0)
        guard case .some(MigrationTransferResult.success) = result else {
            Issue.record("Expected the immediate-mode transfer to be due right away and succeed")
            return
        }

        #expect(engine.transferRows().count == 1)
        #expect(engine.transferRows().first?.status == MigrationTransferRow.Status.sent)

        // Inactive: every member above falls back to the sentinel.
        engine.setActive(false)

        let inactiveSchedule = try await client.proposeImmediateMigration(Self.accountUUID)
        #expect(inactiveSchedule == SentinelValues.migrationSchedule)
        #expect(counters.proposeImmediateMigration.value == 1)

        try await client.signAndStoreMigrationSchedule(Self.accountUUID, inactiveSchedule, try usk())
        #expect(counters.signAndStoreMigrationSchedule.value == 1)

        let inactiveResult = try await client.executeNextPendingMigrationTransfer(Self.accountUUID, Self.networkPrivacy)
        #expect(inactiveResult == SentinelValues.transferResult)
        #expect(counters.executeNextPendingMigrationTransfer.value == 1)
    }

    // MARK: - Keystone (PCZT fabrication + batch parse round trip)

    @Test func keystonePCZTsFabricatedWhenActiveAndParseRoundTripsRecognizedHeader() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        let noteSplitPCZT = try await client.proposeNoteSplitPCZT(Self.accountUUID)
        #expect(!noteSplitPCZT.isEmpty)
        #expect(noteSplitPCZT != SentinelValues.pczt)

        let schedule = try await client.proposeImmediateMigration(Self.accountUUID)
        let batch = try await client.proposeMigrationPCZTs(Self.accountUUID, schedule)
        #expect(!batch.isEmpty)
        #expect(batch.allSatisfy { !$0.pczt.isEmpty })
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

        let inactiveNoteSplitPCZT = try await client.proposeNoteSplitPCZT(Self.accountUUID)
        #expect(inactiveNoteSplitPCZT == SentinelValues.pczt)

        let inactiveBatch = try await client.proposeMigrationPCZTs(Self.accountUUID, schedule)
        #expect(inactiveBatch == SentinelValues.unsignedBatch)
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
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
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
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
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
        storage.setTorEnabledForMigration(true)
        storage.acknowledgeComplete()
        storage.setDustLocked(true)
        storage.recordSyncCompleted(at: Date())

        storage.resetPersistedFlags()

        #expect(storage.migrationMode() == nil)
        #expect(storage.isManualDelivery() == false)
        #expect(storage.isTorEnabledForMigration() == false)
        #expect(storage.isCompleteAcknowledged() == false)
        #expect(storage.isDustLocked() == false)

        // Deliberately untouched: the send gate's timing window is a short-lived value, not a
        // durable app flag (see `resetPersistedFlags`'s doc comment) — MOB-1496 (W3): a non-zero
        // `buffer` proves the persisted `migrationLastSyncCompletedAt` itself survived, independent
        // of whatever buffer value happens to be in force at read time.
        guard case MigrationSendGate.waitUntil = storage.sendGate(now: Date(), buffer: 600) else {
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
