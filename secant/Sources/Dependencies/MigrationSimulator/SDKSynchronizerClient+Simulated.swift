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
//  byte-for-byte, including the existing 5-row `migrationTransfers` demo fixture (spec §3 flag-off
//  guarantee).
//
//  Member mapping follows spec §5.2 exactly; grouped into one `private mutating func` per table
//  row-group so no single function threatens the 150-line SwiftLint warning.
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
        applySimulatedProgressUI(engine: engine)
        applySimulatedDustResolution(engine: engine)
        applySimulatedKeystone(engine: engine)
        applySimulatedLifecycleAndTimestamp(engine: engine)
    }

    // MARK: - State (spec §5.2 "State" row)

    private mutating func applySimulatedState(engine: MigrationSimulatorEngine) {
        let originalGetMigrationState = self.getMigrationState
        self.getMigrationState = {
            engine.isActive ? engine.currentState() : originalGetMigrationState()
        }

        let originalMigrationStateStream = self.migrationStateStream
        self.migrationStateStream = {
            engine.isActive ? engine.statePublisher() : originalMigrationStateStream()
        }

        let originalGetMigrationProgress = self.getMigrationProgress
        self.getMigrationProgress = {
            engine.isActive ? engine.progress() : originalGetMigrationProgress()
        }
    }

    // MARK: - Note splitting (spec §5.2 "Note splitting" row)

    private mutating func applySimulatedNoteSplit(engine: MigrationSimulatorEngine) {
        let originalIsNoteSplitNeeded = self.isNoteSplitNeeded
        self.isNoteSplitNeeded = {
            engine.isActive ? engine.isNoteSplitNeeded() : originalIsNoteSplitNeeded()
        }

        let originalPrepareNoteSplit = self.prepareNoteSplit
        self.prepareNoteSplit = {
            if engine.isActive {
                return await engine.prepareSplit()
            } else {
                return await originalPrepareNoteSplit()
            }
        }

        let originalSubmitNoteSplit = self.submitNoteSplit
        self.submitNoteSplit = { proposal in
            if engine.isActive {
                return await engine.submitSplit(proposal)
            } else {
                return await originalSubmitNoteSplit(proposal)
            }
        }

        let originalSubmitSignedNoteSplit = self.submitSignedNoteSplit
        self.submitSignedNoteSplit = { pczt in
            if engine.isActive {
                return await engine.submitSignedSplit(pczt)
            } else {
                return await originalSubmitSignedNoteSplit(pczt)
            }
        }
    }

    // MARK: - Proposal / commit (spec §5.2 "Proposal" rows)

    private mutating func applySimulatedProposalAndSchedule(engine: MigrationSimulatorEngine) {
        let originalSelectMigrationMode = self.selectMigrationMode
        self.selectMigrationMode = { mode in
            if engine.isActive {
                engine.selectMode(mode)
            } else {
                originalSelectMigrationMode(mode)
            }
        }

        let originalProposeMigrationTransfers = self.proposeMigrationTransfers
        self.proposeMigrationTransfers = {
            if engine.isActive {
                return await engine.propose()
            } else {
                return await originalProposeMigrationTransfers()
            }
        }

        let originalSignAndStoreMigrationSchedule = self.signAndStoreMigrationSchedule
        self.signAndStoreMigrationSchedule = { schedule in
            if engine.isActive {
                await engine.signAndStore(schedule)
            } else {
                await originalSignAndStoreMigrationSchedule(schedule)
            }
        }
    }

    // MARK: - Background execution (spec §5.2 "Background execution" + "On-launch" rows)

    private mutating func applySimulatedBackgroundExecution(engine: MigrationSimulatorEngine) {
        let originalIsSyncRequired = self.isSyncRequiredBeforeNextMigrationTransfer
        self.isSyncRequiredBeforeNextMigrationTransfer = {
            engine.isActive ? engine.isSyncRequired() : originalIsSyncRequired()
        }

        let originalExecuteNext = self.executeNextPendingMigrationTransfer
        self.executeNextPendingMigrationTransfer = { options in
            if engine.isActive {
                return await engine.executeNext(options)
            } else {
                return await originalExecuteNext(options)
            }
        }

        let originalHasOverdue = self.hasOverdueMigrationTransfers
        self.hasOverdueMigrationTransfers = {
            engine.isActive ? engine.hasOverdue() : originalHasOverdue()
        }

        let originalHasInvalid = self.hasInvalidMigrationTransfers
        self.hasInvalidMigrationTransfers = {
            engine.isActive ? engine.hasInvalid() : originalHasInvalid()
        }
    }

    // MARK: - Recovery (spec §5.2 "Recovery" rows)

    private mutating func applySimulatedRecovery(engine: MigrationSimulatorEngine) {
        let originalRestart = self.restartCurrentMigrationStep
        self.restartCurrentMigrationStep = {
            if engine.isActive {
                return await engine.restart()
            } else {
                return await originalRestart()
            }
        }

        let originalRescheduleStalled = self.rescheduleStalledMigrationTransfer
        self.rescheduleStalledMigrationTransfer = {
            if engine.isActive {
                await engine.rescheduleStalled()
            } else {
                await originalRescheduleStalled()
            }
        }

        let originalRecreateInvalid = self.recreateInvalidMigrationTransfer
        self.recreateInvalidMigrationTransfer = {
            if engine.isActive {
                await engine.recreateInvalid()
            } else {
                await originalRecreateInvalid()
            }
        }
    }

    // MARK: - Progress UI (spec §5.2 "Progress UI" row)

    /// Inactive engine falls back to `original()`, preserving today's 5-row `migrationTransfers`
    /// demo fixture byte-for-byte (spec §3 flag-off guarantee).
    private mutating func applySimulatedProgressUI(engine: MigrationSimulatorEngine) {
        let originalMigrationSummary = self.migrationSummary
        self.migrationSummary = {
            engine.isActive ? engine.summary() : originalMigrationSummary()
        }

        let originalMigrationTransfers = self.migrationTransfers
        self.migrationTransfers = {
            engine.isActive ? engine.transferRows() : originalMigrationTransfers()
        }
    }

    // MARK: - Dust resolution (MOB-1487)

    /// Lock gets a short simulated latency so the "Locking balance" in-flight state is visible;
    /// the sweep's latency lives in `engine.migrateDust()` (mirrors `performSend`).
    private mutating func applySimulatedDustResolution(engine: MigrationSimulatorEngine) {
        let originalLockMigrationDust = self.lockMigrationDust
        self.lockMigrationDust = {
            if engine.isActive {
                try await Task.sleep(for: .seconds(0.5))
                engine.lockDust()
            } else {
                try await originalLockMigrationDust()
            }
        }

        let originalMigrateMigrationDust = self.migrateMigrationDust
        self.migrateMigrationDust = { options in
            if engine.isActive {
                return await engine.migrateDust()
            } else {
                return await originalMigrateMigrationDust(options)
            }
        }

        let originalIsMigrationDustLocked = self.isMigrationDustLocked
        self.isMigrationDustLocked = {
            engine.isActive ? engine.isDustLocked() : originalIsMigrationDustLocked()
        }

        // MOB-1487 R3: the send-form Orchard disclaimer — any positive amount counts as touching
        // Orchard while the simulated wallet still holds an unlocked Orchard balance.
        let originalSendRequiresOrchardFunds = self.sendRequiresOrchardFunds
        self.sendRequiresOrchardFunds = { amount in
            if engine.isActive {
                return amount.amount > 0 && engine.orchardBalance().amount > 0 && !engine.isDustLocked()
            } else {
                return await originalSendRequiresOrchardFunds(amount)
            }
        }
    }

    // MARK: - Keystone / PCZT (spec §5.2 "Keystone" rows + §7)

    private mutating func applySimulatedKeystone(engine: MigrationSimulatorEngine) {
        let originalProposeNoteSplitPCZT = self.proposeNoteSplitPCZT
        self.proposeNoteSplitPCZT = {
            if engine.isActive {
                return engine.fabricateNoteSplitPCZT()
            } else {
                return await originalProposeNoteSplitPCZT()
            }
        }

        let originalProposeMigrationPCZTs = self.proposeMigrationPCZTs
        self.proposeMigrationPCZTs = { schedule in
            if engine.isActive {
                return engine.fabricateMigrationPCZTs(schedule)
            } else {
                return await originalProposeMigrationPCZTs(schedule)
            }
        }

        let originalStoreSignedMigrationTransactions = self.storeSignedMigrationTransactions
        self.storeSignedMigrationTransactions = { pczts in
            if engine.isActive {
                engine.storeSignedBatch(pczts)
            } else {
                await originalStoreSignedMigrationTransactions(pczts)
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

    // MARK: - Lifecycle (spec §5.2 "Lifecycle" row) + estimateTimestamp

    /// `initializeMigrationPostUpgrade` isn't part of the migration member block's spec table by
    /// name overlap alone — it IS the "Lifecycle" row. `estimateTimestamp` sits outside the
    /// migration block entirely (it's a general SDK member), but the Transfer Plan screen's
    /// per-row ETAs and the transfer-complete notification's "next in ~N h"
    /// (`MigrationBGSchedulerLiveKey.arm(margin:)`) both resolve a `BlockHeight` through it —
    /// translating our synthetic (epoch-seconds) heights back into real timestamps is what makes
    /// those readings truthful against the simulated schedule instead of falling back to the
    /// cadence-margin default (spec §9 flag #1, superseded).
    private mutating func applySimulatedLifecycleAndTimestamp(engine: MigrationSimulatorEngine) {
        let originalInitializeMigrationPostUpgrade = self.initializeMigrationPostUpgrade
        self.initializeMigrationPostUpgrade = {
            if engine.isActive {
                engine.initializePostUpgrade()
            } else {
                originalInitializeMigrationPostUpgrade()
            }
        }

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
    private static func simulatedBatchUREncoder(for pczts: [Pczt]) -> UREncoder? {
        let joined = pczts.reduce(into: Data()) { $0.append($1) }
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
