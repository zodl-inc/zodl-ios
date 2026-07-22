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
        // MOB-1513: distinct from `migrationSchedule` — `proposeImmediateMigration` now returns the
        // real SDK's `ImmediateMigrationProposal`, not a `MigrationSchedule`.
        static let immediateMigrationProposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 999),
            amount: Zatoshi(-1),
            fee: Zatoshi(-1)
        )
        static let transferResult = MigrationTransferResult.invalidNote
        static let pczt: Data = Data([0xFF])
        // MOB-1496 (final engine, plural preps): the sentinel fallback for `proposeNoteSplitPCZTs`,
        // now array-returning — reuses `pczt`'s bytes so it stays recognizably "obviously fake".
        static let noteSplitPCZTs: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "sentinel-split", pczt: pczt)]
        static let unsignedBatch: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "sentinel", pczt: Data([0xFF]))]
        static let parsedBatch: [Data] = [Data([0xAB, 0xCD])]
        static let estimatedTimestamp: TimeInterval = 999_999
        // R8-T7 (#15): an obviously-fake amount no seeded/preset engine dust figure would coincide
        // with (`.completeWithDust`'s own dust is 800_000 zatoshi -- see that test below).
        static let residualAfterMigration = Zatoshi(123_456_789)
        // MOB-1496 (W-A): equally obviously-fake — no seeded/preset engine dust figure coincides.
        static let lockMigrationResidual = Zatoshi(987_654_321)
        static let unlockMigrationResidual = 42
        // MOB-1511 (W2): negative — no engine-derived round count is ever <= 0, so this can never
        // collide with a genuine active-engine answer.
        static let estimateMigrationRunCount = -777
    }

    /// One call counter per sentinel closure — see the file header for why this is the primary
    /// "did the override call through to `original`" signal.
    private struct CallCounters: Sendable {
        let getMigrationState = LockIsolated<Int>(0)
        let isNoteSplitNeeded = LockIsolated<Int>(0)
        let proposeMigrationTransfers = LockIsolated<Int>(0)
        let proposeImmediateMigration = LockIsolated<Int>(0)
        let residualAfterMigration = LockIsolated<Int>(0)
        let lockMigrationResidual = LockIsolated<Int>(0)
        let unlockMigrationResidual = LockIsolated<Int>(0)
        let signAndStoreMigrationSchedule = LockIsolated<Int>(0)
        let executeNextPendingMigrationTransfer = LockIsolated<Int>(0)
        let proposeMigrationPCZTs = LockIsolated<Int>(0)
        let parseMigrationPCZTBatch = LockIsolated<Int>(0)
        let urEncoderForMigrationPCZTBatch = LockIsolated<Int>(0)
        let estimateTimestamp = LockIsolated<Int>(0)
        let estimateMigrationRunCount = LockIsolated<Int>(0)
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
            return SentinelValues.immediateMigrationProposal
        }
        client.residualAfterMigration = { _ in
            counters.residualAfterMigration.withValue { $0 += 1 }
            return SentinelValues.residualAfterMigration
        }
        client.lockMigrationResidual = { _ in
            counters.lockMigrationResidual.withValue { $0 += 1 }
            return SentinelValues.lockMigrationResidual
        }
        client.unlockMigrationResidual = { _ in
            counters.unlockMigrationResidual.withValue { $0 += 1 }
            return SentinelValues.unlockMigrationResidual
        }
        client.signAndStoreMigrationSchedule = { _, _, _ in
            counters.signAndStoreMigrationSchedule.withValue { $0 += 1 }
        }
        client.executeNextPendingMigrationTransfer = { _, _ in
            counters.executeNextPendingMigrationTransfer.withValue { $0 += 1 }
            return SentinelValues.transferResult
        }
        client.proposeNoteSplitPCZTs = { _ in SentinelValues.noteSplitPCZTs }
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
        client.estimateMigrationRunCount = { _ in
            counters.estimateMigrationRunCount.withValue { $0 += 1 }
            return SentinelValues.estimateMigrationRunCount
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

    // MARK: - residualAfterMigration (R8-T7 #15)
    //
    // Pre-fix, this member had no override at all in `SDKSynchronizerClient+Simulated.swift` --
    // the one gap in the file's own "wires every migration-surface member" claim -- so it fell
    // through to the real SDK even while the simulator was active. Mirrors `engine.summary().dust`
    // (see that override's doc comment for why this is the exact right engine surface to mirror),
    // seeded via the SAME `.completeWithDust` preset the dust-resolution tests below already use.

    @Test func residualAfterMigrationRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        engine.applyPreset(SimulatorPreset.completeWithDust)
        #expect(engine.readout().dustRemainder.amount > 0)

        // Active: reads the engine's own dust figure, never the sentinel.
        let residual = try await client.residualAfterMigration(Self.accountUUID)
        #expect(residual == engine.readout().dustRemainder)
        #expect(residual != SentinelValues.residualAfterMigration)
        #expect(counters.residualAfterMigration.value == 0)

        // Inactive: falls back to the sentinel original.
        engine.setActive(false)
        let inactiveResidual = try await client.residualAfterMigration(Self.accountUUID)
        #expect(inactiveResidual == SentinelValues.residualAfterMigration)
        #expect(counters.residualAfterMigration.value == 1)
    }

    /// Mirrors the real member's own doc contract ("`nil` when there is none") -- a fresh engine
    /// has no dust remainder yet, so this must read as absent (`nil`), never a fabricated
    /// `Zatoshi.zero`.
    @Test func residualAfterMigrationWithNoDustReturnsNilWhenActive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true)
        client.applySimulatedMigration(engine: engine)

        let residual = try await client.residualAfterMigration(Self.accountUUID)

        #expect(residual == nil)
        #expect(counters.residualAfterMigration.value == 0)
    }

    // MARK: - estimateMigrationRunCount (MOB-1511 W2)
    //
    // Pre-fix, this member had no override at all -- the real SDK stub always answered `nil`, so
    // even with the simulator active the debug panel's "Round N of M" multi-round label could
    // never be exercised. Mirrors `engine.estimatedRunCount()` -- see that method's doc.

    @Test func estimateMigrationRunCountRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        // Active: reads the engine's own estimate (fresh-seeded default balance -> 3 rounds),
        // never the sentinel.
        let estimate = try await client.estimateMigrationRunCount(Self.accountUUID)
        #expect(estimate == 3)
        #expect(estimate != SentinelValues.estimateMigrationRunCount)
        #expect(counters.estimateMigrationRunCount.value == 0)

        // Inactive: falls back to the sentinel original.
        engine.setActive(false)
        let inactiveEstimate = try await client.estimateMigrationRunCount(Self.accountUUID)
        #expect(inactiveEstimate == SentinelValues.estimateMigrationRunCount)
        #expect(counters.estimateMigrationRunCount.value == 1)
    }

    /// A fully drained engine (`.complete` preset) must answer `nil`, not a fabricated `0` or `1`
    /// -- mirrors the real SDK member's own "zero runs is a legitimate answer" contract.
    @Test func estimateMigrationRunCountIsNilWhenDrainedWhileActive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true)
        client.applySimulatedMigration(engine: engine)

        engine.applyPreset(SimulatorPreset.complete)
        let estimate = try await client.estimateMigrationRunCount(Self.accountUUID)

        #expect(estimate == nil)
        #expect(counters.estimateMigrationRunCount.value == 0)
    }

    // MARK: - proposeImmediateMigration

    /// MOB-1513: the real surface's `proposeImmediateMigration` returns an `ImmediateMigrationProposal`
    /// now (an ordinary send-max proposal, executed via `createAndSubmitProposedTransactions`/
    /// `createPCZTFromProposal` like any other transfer) instead of a `MigrationSchedule` signed+
    /// stored in the engine and later broadcast via `executeNextPendingMigrationTransfer`. The
    /// simulator has no fake for either of those general-purpose broadcast members (they're shared
    /// with ordinary sends, outside this file's migration-only override surface), so this test only
    /// covers what the simulator DOES fake — the proposal itself — and no longer exercises a
    /// sign+store+execute continuation, which is dead for immediate mode under the real contract.
    /// NOTE (known gap, flagged for follow-up rather than fixed here — out of MOB-1513's scope): with
    /// the simulator active, the real UI's immediate-mode Confirm would still call the REAL
    /// `createAndSubmitProposedTransactions`/`createPCZTFromProposal` against this fabricated
    /// `.testOnlyFakeProposal`, which throws by design (see that factory's own doc) — so end-to-end
    /// QA of the immediate lane through the simulator panel does not yet work past this propose step.
    @Test func proposeImmediateMigrationReturnsEngineDerivedProposalWhenActiveAndSentinelWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        let proposal = try await client.proposeImmediateMigration(Self.accountUUID)
        #expect(proposal != SentinelValues.immediateMigrationProposal)
        #expect(proposal.amount.amount > 0)
        #expect(counters.proposeImmediateMigration.value == 0)

        // Same seeded snapshot, read again directly — `propose()` is a pure read over persisted
        // state (unlike `signAndStore`/`executeNext`, which mutate it), so a second, independent call
        // must agree with what the override derived the proposal's `amount` from.
        let expectedSchedule = await engine.propose()
        #expect(proposal.amount == expectedSchedule.transfers.first?.amount)

        // Inactive: falls back to the sentinel.
        engine.setActive(false)

        let inactiveProposal = try await client.proposeImmediateMigration(Self.accountUUID)
        #expect(inactiveProposal == SentinelValues.immediateMigrationProposal)
        #expect(counters.proposeImmediateMigration.value == 1)
    }

    // MARK: - Dust resolution (MOB-1496 W-A: lockMigrationResidual/unlockMigrationResidual)
    //
    // MOB-1496 (W-B): the old dust-sweep composite (`migrateMigrationDust`) is retired along with
    // the real SDK member it stood in for — "Migrate anyway" now proposes through the
    // already-covered `proposeImmediateMigrationReturnsEngineDerivedProposalWhenActiveAndSentinelWhenInactive`
    // above. This section now covers only the lock/unlock members `lockMigrationDust`/"Migrate
    // anyway" (unlock-first) call directly.

    /// `SimulatorPreset.completeWithDust` is the SAME preset the Migration Simulator Panel's own
    /// dust preset button applies. The FIRST lock reports the dust value (nothing was locked
    /// before); mirrors the real SDK's idempotent-additive contract.
    @Test func lockMigrationResidualRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        engine.applyPreset(SimulatorPreset.completeWithDust)
        #expect(engine.readout().dustRemainder.amount > 0)

        let locked = try await client.lockMigrationResidual(Self.accountUUID)
        #expect(counters.lockMigrationResidual.value == 0)
        #expect(locked == engine.readout().dustRemainder)
        #expect(engine.isDustLocked() == true)

        // Inactive: falls back to the sentinel original, and the engine's own lock state (already
        // set above) is untouched by the fallback call.
        engine.setActive(false)
        let inactiveResult = try await client.lockMigrationResidual(Self.accountUUID)
        #expect(inactiveResult == SentinelValues.lockMigrationResidual)
        #expect(counters.lockMigrationResidual.value == 1)
    }

    /// Idempotent-additive: a SECOND lock call (already locked, nothing newly spendable) reports
    /// `.zero`, never the dust figure again.
    @Test func lockMigrationResidualSecondCallWhileAlreadyLockedReturnsZero() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true)
        client.applySimulatedMigration(engine: engine)
        engine.applyPreset(SimulatorPreset.completeWithDust)

        _ = try await client.lockMigrationResidual(Self.accountUUID)
        let secondLock = try await client.lockMigrationResidual(Self.accountUUID)

        #expect(secondLock == Zatoshi.zero)
        #expect(engine.isDustLocked() == true)
    }

    /// The release half — mirrors the real SDK's "returns the number unlocked (`0` when nothing was
    /// locked)" contract.
    @Test func unlockMigrationResidualRoutesThroughEngineWhenActiveAndFallsBackWhenInactive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true)
        client.applySimulatedMigration(engine: engine)
        engine.applyPreset(SimulatorPreset.completeWithDust)
        engine.lockDust()
        #expect(engine.isDustLocked() == true)

        let unlocked = try await client.unlockMigrationResidual(Self.accountUUID)
        #expect(counters.unlockMigrationResidual.value == 0)
        #expect(unlocked == 1)
        #expect(engine.isDustLocked() == false)

        // Inactive: falls back to the sentinel original.
        engine.setActive(false)
        let inactiveResult = try await client.unlockMigrationResidual(Self.accountUUID)
        #expect(inactiveResult == SentinelValues.unlockMigrationResidual)
        #expect(counters.unlockMigrationResidual.value == 1)
    }

    /// Nothing locked -> `0`, never a fabricated positive count.
    @Test func unlockMigrationResidualWithNothingLockedReturnsZeroWhenActive() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true)
        client.applySimulatedMigration(engine: engine)

        let unlocked = try await client.unlockMigrationResidual(Self.accountUUID)

        #expect(unlocked == 0)
        #expect(counters.unlockMigrationResidual.value == 0)
    }

    // MARK: - Keystone (PCZT fabrication + batch parse round trip)

    @Test func keystonePCZTsFabricatedWhenActiveAndParseRoundTripsRecognizedHeader() async throws {
        let counters = CallCounters()
        var client = makeBaseClient(counters)
        let engine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral())
        engine.setActive(true) // the fresh-seed default is inactive (opt-in simulation)
        client.applySimulatedMigration(engine: engine)

        let noteSplitPCZTs = try await client.proposeNoteSplitPCZTs(Self.accountUUID)
        #expect(noteSplitPCZTs.count == 1)
        #expect(!(noteSplitPCZTs.first?.pczt.isEmpty ?? true))
        #expect(noteSplitPCZTs != SentinelValues.noteSplitPCZTs)

        // MOB-1513: `proposeImmediateMigration` no longer returns a `MigrationSchedule` (it returns
        // the real SDK's `ImmediateMigrationProposal` now) — `proposeMigrationTransfers` is still a
        // schedule source and is simulated the same way (`engine.propose()` when active), so it
        // stands in here purely as a batch-fabrication fixture; the counter check below is identical
        // either way.
        let schedule = try await client.proposeMigrationTransfers(Self.accountUUID, false)
        let batch = try await client.proposeMigrationPCZTs(Self.accountUUID, schedule)
        #expect(!batch.isEmpty)
        #expect(batch.allSatisfy { !$0.pczt.isEmpty })
        #expect(counters.proposeMigrationPCZTs.value == 0)

        // Active + recognized fabricated-format header -> returns the whole batch as one element.
        let fabricated = engine.fabricateNoteSplitPCZTs().first?.pczt ?? Data()
        #expect(client.parseMigrationPCZTBatch(fabricated) == [fabricated])
        #expect(counters.parseMigrationPCZTBatch.value == 0)

        // Active but NOT the fabricated format -> falls through to original, same as inactive.
        let unrecognized = Data([0x00, 0x01])
        #expect(client.parseMigrationPCZTBatch(unrecognized) == SentinelValues.parsedBatch)
        #expect(counters.parseMigrationPCZTBatch.value == 1)

        // Inactive: every member above falls back to the sentinel.
        engine.setActive(false)

        let inactiveNoteSplitPCZTs = try await client.proposeNoteSplitPCZTs(Self.accountUUID)
        #expect(inactiveNoteSplitPCZTs == SentinelValues.noteSplitPCZTs)

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
    @Test func gateStorageResetPersistedFlagsClearsWalletWideFlagsButLeavesPerAccountOnesAndTheSyncGateWindow() throws {
        let suiteName = "testGateStorageResetPersistedFlagsClearsWalletWideFlagsButLeavesPerAccountOnes"
        let userDefaults = try #require(
            UserDefaults(suiteName: suiteName),
            "MigrationGateStorage: UserDefaults failed to initialize"
        )
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let storage = MigrationGateStorage(userDefaults: userDefaults)
        let accountUUID = AccountUUID(id: [UInt8](repeating: 1, count: 16))
        storage.setMigrationMode(MigrationMode.immediate, for: accountUUID)
        storage.setManualDelivery(true, for: accountUUID)
        storage.setTorEnabledForMigration(true)
        storage.acknowledgeComplete(for: accountUUID)
        storage.recordSyncCompleted(at: Date())

        storage.resetPersistedFlags()

        // MOB-1509: mode/manual are per-account now (the acknowledged flag's R8-T3 transition) —
        // the storage-level reset only deletes the dead legacy wallet-wide keys, so per-account
        // values survive; clearing them per KNOWN account is
        // `MigrationManagerImpl.resetPersistedFlags()`'s job (see the twin test below).
        #expect(storage.migrationMode(for: accountUUID) == MigrationMode.immediate)
        #expect(storage.isManualDelivery(for: accountUUID) == true)
        // MOB-1497 (R1): the stored choice is genuinely gone (see the raw-key check below) — it just
        // reads back `true` now, the new never-written default, rather than `false`.
        #expect(storage.isTorEnabledForMigration() == true)
        #expect(userDefaults.data(forKey: .migrationNetworkPrivacyOptions) == nil)
        // R8-T3 (S2): the acknowledged flag is per-account now — `MigrationGateStorage
        // .resetPersistedFlags()` only clears the dead legacy (wallet-wide, unsuffixed) key; see
        // `MigrationManagerTests.resetPersistedFlagsClearsWalletWideFlagsAndLeavesPerAccountFlags`'s
        // twin assertion for the full explanation.
        #expect(storage.isCompleteAcknowledged(for: accountUUID) == true)

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

        // MOB-1509: mode/manual/dust are per-account — the Impl-level reset is what clears every
        // KNOWN account's flags (the storage-level reset alone leaves them, see the test above),
        // so a selected account must exist for the candidate set to contain it.
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let storage = MigrationGateStorage(userDefaults: userDefaults)
            let account = WalletAccount(Account(
                id: AccountUUID(id: [UInt8](repeating: 7, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            ))
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
            $selectedWalletAccount.withLock { $0 = account }
            storage.setMigrationMode(MigrationMode.privateScheduled, for: account.id)
            storage.setManualDelivery(true, for: account.id)

            let impl = MigrationManagerImpl(gateStorage: storage)
            impl.resetPersistedFlags()

            #expect(storage.migrationMode(for: account.id) == nil)
            #expect(storage.isManualDelivery(for: account.id) == false)
        }
    }
}
