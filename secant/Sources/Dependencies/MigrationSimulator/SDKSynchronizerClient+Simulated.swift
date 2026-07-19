//
//  SDKSynchronizerClient+Simulated.swift
//  zodl
//
//  Wires every migration-surface member of `SDKSynchronizerClient` (plus `estimateTimestamp`)
//  through `MigrationSimulatorEngine` (MOB-1480). `SDKSynchronizerLive.live()` calls
//  `applySimulatedMigration(engine:)` on the client it already built, immediately before
//  returning, whenever `MigrationSimulatorFlag.isEnabled` — the stub/live construction itself
//  never changes.
//
//  CAPTURE-ORIGINAL pattern, applied to every member: read the existing closure into a local
//  `original...` constant BEFORE overwriting `self`'s property, then have the override close over
//  that local constant (never over `self`, which would recurse). When `engine.isActive` is
//  `false`, every override calls straight through to `original...`, so flipping the debug panel's
//  toggle off — or never applying this at all, in `zodl-internal`/`zodl-production` where
//  `MigrationSimulatorFlag.isEnabled` is a compile-time `false` — reproduces today's behavior
//  byte-for-byte.
//
//  MOB-1496: reshaped for the real, per-account, throwing SDK surface. `accountUUID` arrives on
//  every override and is ignored (single simulated wallet, no real per-account bookkeeping).
//  REMOVED members (`migrationStateStream`, `selectMigrationMode`, `rescheduleStalledMigrationTransfer`,
//  `recreateInvalidMigrationTransfer`, `migrationSummary`, `migrationTransfers`, `lockMigrationDust`,
//  `isMigrationDustLocked`, `initializeMigrationPostUpgrade`) have their overrides deleted —
//  `migrationSummary`/`migrationTransfers`/`lockMigrationDust`/`isMigrationDustLocked` relocated to
//  `MigrationManagerClient`, which reach-arounds the engine directly (`MigrationManagerLiveKey.swift`),
//  gated exactly like this file's existing reach-arounds. `selectMigrationMode` had no real-SDK
//  counterpart at all — the engine's internal `snapshot.mode` is now set by whichever propose
//  override runs (`proposeMigrationTransfers` -> `.privateScheduled`, `proposeImmediateMigration`
//  -> `.immediate`), mirroring how the real SDK distinguishes the two by WHICH function the host
//  calls rather than a stored mode flag. `rescheduleStalledMigrationTransfer` is replaced by
//  `rescheduleOverdueMigrationTransfer` (see `MigrationSimulatorEngine.rescheduleOverdue()`'s doc);
//  `recreateInvalidMigrationTransfer` has no replacement (the recovery call site now uses
//  `restartCurrentMigrationStep`, already simulated below).
//

import Foundation
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit
@preconcurrency import KeystoneSDK
import URKit

extension SDKSynchronizerClient {
    mutating func applySimulatedMigration(engine: MigrationSimulatorEngine) {
        applySimulatedState(engine: engine)
        applySimulatedNoteSplit(engine: engine)
        applySimulatedProposalAndSchedule(engine: engine)
        applySimulatedBackgroundExecution(engine: engine)
        applySimulatedRecovery(engine: engine)
        applySimulatedDustResolution(engine: engine)
        applySimulatedKeystone(engine: engine)
        applySimulatedEstimateTimestamp(engine: engine)
    }

    // MARK: - State (spec §5.2 "State" row)

    private mutating func applySimulatedState(engine: MigrationSimulatorEngine) {
        let originalGetMigrationState = self.getMigrationState
        self.getMigrationState = { accountUUID in
            engine.isActive ? engine.currentState() : try await originalGetMigrationState(accountUUID)
        }

        let originalGetMigrationProgress = self.getMigrationProgress
        self.getMigrationProgress = { accountUUID in
            engine.isActive ? engine.progress() : try await originalGetMigrationProgress(accountUUID)
        }
    }

    // MARK: - Note splitting (spec §5.2 "Note splitting" row)

    private mutating func applySimulatedNoteSplit(engine: MigrationSimulatorEngine) {
        let originalIsNoteSplitNeeded = self.isNoteSplitNeeded
        self.isNoteSplitNeeded = { accountUUID in
            engine.isActive ? engine.isNoteSplitNeeded() : try await originalIsNoteSplitNeeded(accountUUID)
        }

        let originalPrepareNoteSplit = self.prepareNoteSplit
        self.prepareNoteSplit = { accountUUID in
            if engine.isActive {
                return await engine.prepareSplit()
            } else {
                return try await originalPrepareNoteSplit(accountUUID)
            }
        }

        let originalSubmitNoteSplit = self.submitNoteSplit
        self.submitNoteSplit = { accountUUID, proposal, usk, options in
            if engine.isActive {
                return await engine.submitSplit(proposal)
            } else {
                return try await originalSubmitNoteSplit(accountUUID, proposal, usk, options)
            }
        }

        // MOB-1496 (C-1 fix): the old `submitSignedNoteSplit` composite split into a store member and
        // a broadcast member — the simulator's single-snapshot engine has no run to shadow (that
        // hazard is real-engine-only), so there is no separate "store" phase to simulate here.
        // `engine.submitSignedSplit` is unchanged (still exercised directly by
        // `MigrationSimulatorEngineTests`) and does the full store+submit in one shot; its own `pczt`
        // parameter has always been ignored (it re-derives the deterministic split from
        // `prepareSplit()`), so moving the ENTIRE call into `broadcastStoredNoteSplit` below —
        // passing `Data()` — reproduces byte-identical panel/engine behavior to the old composite.
        let originalStoreSignedNoteSplit = self.storeSignedNoteSplit
        self.storeSignedNoteSplit = { accountUUID, pczt in
            if !engine.isActive {
                try await originalStoreSignedNoteSplit(accountUUID, pczt)
            }
        }

        let originalBroadcastStoredNoteSplit = self.broadcastStoredNoteSplit
        self.broadcastStoredNoteSplit = { accountUUID, options in
            if engine.isActive {
                return await engine.submitSignedSplit(Data())
            } else {
                return try await originalBroadcastStoredNoteSplit(accountUUID, options)
            }
        }
    }

    // MARK: - Proposal / commit (spec §5.2 "Proposal" rows)

    private mutating func applySimulatedProposalAndSchedule(engine: MigrationSimulatorEngine) {
        let originalProposeMigrationTransfers = self.proposeMigrationTransfers
        self.proposeMigrationTransfers = { accountUUID, includeResidual in
            if engine.isActive {
                engine.selectMode(MigrationMode.privateScheduled)
                return await engine.propose()
            } else {
                return try await originalProposeMigrationTransfers(accountUUID, includeResidual)
            }
        }

        let originalProposeImmediateMigration = self.proposeImmediateMigration
        self.proposeImmediateMigration = { accountUUID in
            if engine.isActive {
                engine.selectMode(MigrationMode.immediate)
                return await engine.propose()
            } else {
                return try await originalProposeImmediateMigration(accountUUID)
            }
        }

        let originalSignAndStoreMigrationSchedule = self.signAndStoreMigrationSchedule
        self.signAndStoreMigrationSchedule = { accountUUID, schedule, usk in
            if engine.isActive {
                await engine.signAndStore(schedule)
            } else {
                try await originalSignAndStoreMigrationSchedule(accountUUID, schedule, usk)
            }
        }
    }

    // MARK: - Background execution (spec §5.2 "Background execution" + "On-launch" rows)

    private mutating func applySimulatedBackgroundExecution(engine: MigrationSimulatorEngine) {
        let originalIsSyncRequired = self.isSyncRequiredBeforeNextMigrationTransfer
        self.isSyncRequiredBeforeNextMigrationTransfer = { accountUUID in
            engine.isActive ? engine.isSyncRequired() : try await originalIsSyncRequired(accountUUID)
        }

        let originalExecuteNext = self.executeNextPendingMigrationTransfer
        self.executeNextPendingMigrationTransfer = { accountUUID, options in
            if engine.isActive {
                return await engine.executeNext(options)
            } else {
                return try await originalExecuteNext(accountUUID, options)
            }
        }

        let originalHasOverdue = self.hasOverdueMigrationTransfers
        self.hasOverdueMigrationTransfers = { accountUUID in
            engine.isActive ? engine.hasOverdue() : try await originalHasOverdue(accountUUID)
        }

        let originalHasInvalid = self.hasInvalidMigrationTransfers
        self.hasInvalidMigrationTransfers = { accountUUID in
            engine.isActive ? engine.hasInvalid() : try await originalHasInvalid(accountUUID)
        }
    }

    // MARK: - Recovery (spec §5.2 "Recovery" rows)

    private mutating func applySimulatedRecovery(engine: MigrationSimulatorEngine) {
        let originalRestart = self.restartCurrentMigrationStep
        self.restartCurrentMigrationStep = { accountUUID, includeResidual in
            if engine.isActive {
                return await engine.restart()
            } else {
                return try await originalRestart(accountUUID, includeResidual)
            }
        }

        let originalRescheduleOverdue = self.rescheduleOverdueMigrationTransfer
        self.rescheduleOverdueMigrationTransfer = { accountUUID in
            if engine.isActive {
                return await engine.rescheduleOverdue()
            } else {
                return try await originalRescheduleOverdue(accountUUID)
            }
        }
    }

    // MARK: - Dust resolution (MOB-1487)

    /// The sweep ("Migrate anyway") is a broadcast, so its stub takes the transaction guard like
    /// the other broadcast-path stubs and is correct-by-construction once real broadcasting lands.
    /// `lockMigrationDust`/`isMigrationDustLocked` relocated to `MigrationManagerClient` (MOB-1496)
    /// — see that client's own reach-around, gated identically to this file's.
    private mutating func applySimulatedDustResolution(engine: MigrationSimulatorEngine) {
        let originalMigrateMigrationDust = self.migrateMigrationDust
        self.migrateMigrationDust = { accountUUID, usk, options in
            if engine.isActive {
                return await engine.migrateDust()
            } else {
                return try await originalMigrateMigrationDust(accountUUID, usk, options)
            }
        }

        // MOB-1487 R3: the send-form Orchard disclaimer — any positive amount counts as touching
        // Orchard while the simulated wallet still holds an unlocked Orchard balance.
        let originalSendRequiresOrchardFunds = self.sendRequiresOrchardFunds
        self.sendRequiresOrchardFunds = { accountUUID, amount in
            if engine.isActive {
                return amount.amount > 0 && engine.orchardBalance().amount > 0 && !engine.isDustLocked()
            } else {
                return await originalSendRequiresOrchardFunds(accountUUID, amount)
            }
        }
    }

    // MARK: - Keystone / PCZT (spec §5.2 "Keystone" rows + §7)

    private mutating func applySimulatedKeystone(engine: MigrationSimulatorEngine) {
        let originalProposeNoteSplitPCZT = self.proposeNoteSplitPCZT
        self.proposeNoteSplitPCZT = { accountUUID in
            if engine.isActive {
                return engine.fabricateNoteSplitPCZT()
            } else {
                return try await originalProposeNoteSplitPCZT(accountUUID)
            }
        }

        let originalProposeMigrationPCZTs = self.proposeMigrationPCZTs
        self.proposeMigrationPCZTs = { accountUUID, schedule in
            if engine.isActive {
                return engine.fabricateMigrationPCZTs(schedule)
            } else {
                return try await originalProposeMigrationPCZTs(accountUUID, schedule)
            }
        }

        let originalStoreSignedMigrationTransactions = self.storeSignedMigrationTransactions
        self.storeSignedMigrationTransactions = { accountUUID, signed in
            if engine.isActive {
                engine.storeSignedBatch(signed)
            } else {
                try await originalStoreSignedMigrationTransactions(accountUUID, signed)
            }
        }

        let originalUrEncoderForMigrationPCZTBatch = self.urEncoderForMigrationPCZTBatch
        self.urEncoderForMigrationPCZTBatch = { pczts in
            guard engine.isActive else { return originalUrEncoderForMigrationPCZTBatch(pczts) }
            return SDKSynchronizerClient.simulatedBatchUREncoder(for: pczts)
        }

        let originalParseMigrationPCZTBatch = self.parseMigrationPCZTBatch
        self.parseMigrationPCZTBatch = { data in
            let header = Data(MigrationSimulatorEngineDerivations.Constants.fabricatedPCZTHeader.utf8)
            guard engine.isActive, data.starts(with: header) else {
                return originalParseMigrationPCZTBatch(data)
            }
            return [data]
        }
    }

    // MARK: - estimateTimestamp

    /// `estimateTimestamp` sits outside the migration block entirely (it's a general SDK member),
    /// but the Transfer Plan screen's per-row ETAs and the transfer-complete notification's "next
    /// in ~N h" (`MigrationBGSchedulerLiveKey.arm(margin:)`) both resolve a `BlockHeight` through
    /// it — translating our synthetic (epoch-seconds) heights back into real timestamps is what
    /// makes those readings truthful against the simulated schedule instead of falling back to the
    /// cadence-margin default (spec §9 flag #1, superseded).
    private mutating func applySimulatedEstimateTimestamp(engine: MigrationSimulatorEngine) {
        let originalEstimateTimestamp = self.estimateTimestamp
        self.estimateTimestamp = { height in
            if engine.isActive && MigrationSimulatorEngineDerivations.isSyntheticHeight(height) {
                return MigrationSimulatorEngineDerivations.timestamp(forSyntheticHeight: height)
            } else {
                return originalEstimateTimestamp(height)
            }
        }
    }

    // MARK: - Keystone batch UR encoding helper

    /// Real rendering `UREncoder` over the fabricated batch (spec §7 — the sign screen must look
    /// real, including an actually-animating QR). Joins every fabricated PCZT blob into ONE `Data`
    /// payload — the whole batch, not just the first blob, for a more realistic multi-part payload
    /// size — then feeds it through the exact `KeystoneZcashSDK` mechanism `urEncoderForPCZT` uses
    /// for the single-PCZT path (`SDKSynchronizerLive.swift`). The fabricated bytes aren't a
    /// spec-valid PCZT (spec §9 flag #2), so `generateZcashPczt` rejecting them is the
    /// expected/common case; the fallback constructs a `UR` directly via URKit, under a distinct,
    /// self-describing type so nothing could mistake it for a real Zcash PCZT UR, so the screen
    /// still has something to render. `nil` (both paths failing, or an empty batch) is tolerable —
    /// the Keystone bypass button is the real lane — but worth flagging during QA.
    private static func simulatedBatchUREncoder(for pczts: [MigrationUnsignedTransferPczt]) -> UREncoder? {
        let joined = pczts.reduce(into: Data()) { $0.append($1.pczt) }
        // FountainEncoder traps (fragment-count range 1...0) for messages shorter than its
        // 10-byte minFragmentLen, and UREncoder.init cannot throw — refuse tiny payloads instead.
        // Fabricated PCZTs are always larger (the 13-byte header alone), so this only guards
        // impossible/foreign inputs.
        guard joined.count >= 10 else { return nil }

        if let encoder = try? KeystoneZcashSDK().generateZcashPczt(pczt_hex: joined) {
            return encoder
        }

        guard let fallbackUR = try? UR(type: "zodl-sim-pczt-batch", cbor: CBOR.bytes(joined)) else { return nil }
        return UREncoder(fallbackUR, maxFragmentLen: 200)
    }
}
