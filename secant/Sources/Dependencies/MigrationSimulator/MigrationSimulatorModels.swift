//
//  MigrationSimulatorModels.swift
//  zodl
//
//  Value types for the migration SDK simulator (MOB-1480, testnet-only debug tooling). These
//  model the *persisted* simulated state (`SimulatorSnapshot`/`SimulatorTransfer`), the debug
//  panel's preset menu (`SimulatorPreset`), the panel's read-only status display
//  (`SimulatorReadout`), and a seeded RNG (`SplitMix64`) so note splits are reproducible per
//  `rngSeed`. See docs/superpowers/specs/2026-07-13-mob1480-migration-sdk-simulator-design.md §5.1.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// A splittable, reproducible 64-bit RNG (public-domain SplitMix64 algorithm). Used to derive
/// note splits deterministically from a persisted `rngSeed`, so re-deriving the same seed against
/// the same balance always yields the same split (spec §9 flag: "reproducible per reset").
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One scheduled/sent migration transfer as tracked by the simulator. Deliberately minimal:
/// `derivedStatus`/caption fields (`hoursFromNow`, `sentMinutesAgo`, `isBroadcasting`) are NEVER
/// stored here — they're recomputed at read time from `dueAt`/`sentAt` plus the engine's current
/// `MigrationState` (see `MigrationSimulatorEngineDerivations`).
struct SimulatorTransfer: Equatable, Sendable, Codable, Identifiable {
    var id: String
    /// 0-based position in the schedule (stable even as earlier transfers are sent).
    var index: Int
    var amount: Zatoshi
    var dueAt: Date
    var sentAt: Date?

    init(id: String, index: Int, amount: Zatoshi, dueAt: Date, sentAt: Date? = nil) {
        self.id = id
        self.index = index
        self.amount = amount
        self.dueAt = dueAt
        self.sentAt = sentAt
    }
}

/// The complete persisted simulator state. Envelope-versioned via `schemaVersion` — the store
/// reseeds on any decode failure or version mismatch rather than attempting migration.
struct SimulatorSnapshot: Equatable, Sendable, Codable {
    /// Bump whenever this shape changes; the store treats a mismatch like a decode failure.
    static let currentSchemaVersion = 1

    static func seeded(rngSeed: UInt64 = MigrationSimulatorEngineDerivations.Constants.defaultRNGSeed) -> SimulatorSnapshot {
        SimulatorSnapshot(
            schemaVersion: SimulatorSnapshot.currentSchemaVersion,
            // Opt-in: a fresh install simulates nothing until the debug panel's toggle turns the
            // simulation on (Michal 2026-07-15; the long-press panel entry is flag-gated only, so
            // it stays reachable while inactive).
            isActive: false,
            orchardBalance: MigrationSimulatorEngineDerivations.Constants.defaultOrchardBalance,
            notes: [MigrationSimulatorEngineDerivations.Constants.defaultOrchardBalance],
            mode: MigrationMode.privateScheduled,
            state: MigrationState.notStarted,
            transfers: [],
            timeOffset: 0,
            syncRequired: false,
            armedTransferResult: nil,
            armedSplitFailure: false,
            splitSubmittedAt: nil,
            signedBatchCount: 0,
            rngSeed: rngSeed,
            lastBackgroundRunSummary: nil,
            dustRemainder: Zatoshi.zero
        )
    }

    var schemaVersion: Int
    var isActive: Bool
    var orchardBalance: Zatoshi
    var notes: [Zatoshi]
    var mode: MigrationMode
    var state: MigrationState
    var transfers: [SimulatorTransfer]
    /// Simulated-clock offset from the wall clock: `simNow = Date() + timeOffset`.
    var timeOffset: TimeInterval
    var syncRequired: Bool
    var armedTransferResult: TransferResult?
    var armedSplitFailure: Bool
    var splitSubmittedAt: Date?
    /// Keystone: count of PCZTs most recently stored via `storeSignedBatch`.
    var signedBatchCount: Int
    var rngSeed: UInt64
    /// One-line summary of the most recent `executeNext` outcome, for the debug panel.
    var lastBackgroundRunSummary: String?
    /// Balance left over once every transfer has been sent (usually `.zero`).
    var dustRemainder: Zatoshi

    init(
        schemaVersion: Int,
        isActive: Bool = false,
        orchardBalance: Zatoshi,
        notes: [Zatoshi],
        mode: MigrationMode,
        state: MigrationState,
        transfers: [SimulatorTransfer],
        timeOffset: TimeInterval,
        syncRequired: Bool,
        armedTransferResult: TransferResult?,
        armedSplitFailure: Bool,
        splitSubmittedAt: Date?,
        signedBatchCount: Int,
        rngSeed: UInt64,
        lastBackgroundRunSummary: String?,
        dustRemainder: Zatoshi
    ) {
        self.schemaVersion = schemaVersion
        self.isActive = isActive
        self.orchardBalance = orchardBalance
        self.notes = notes
        self.mode = mode
        self.state = state
        self.transfers = transfers
        self.timeOffset = timeOffset
        self.syncRequired = syncRequired
        self.armedTransferResult = armedTransferResult
        self.armedSplitFailure = armedSplitFailure
        self.splitSubmittedAt = splitSubmittedAt
        self.signedBatchCount = signedBatchCount
        self.rngSeed = rngSeed
        self.lastBackgroundRunSummary = lastBackgroundRunSummary
        self.dustRemainder = dustRemainder
    }
}

/// The debug panel's preset menu (spec §5.3). Each preset seeds a whole, internally-consistent
/// snapshot targeting a specific banner variant / re-entry route for manual QA.
enum SimulatorPreset: String, Equatable, Sendable, Codable, CaseIterable {
    case freshRequired
    case splitting
    case readyToPropose
    case inProgress
    case transferReadyManual
    case transferStalled
    case updatePlanInvalid
    case transfersExpired
    case syncRequired
    case complete
    case completeWithDust

    /// True for the one preset that needs the app-side `isManualDelivery` flag flipped on too —
    /// the panel reads this to know which `MigrationManagerClient` flag to align (the engine
    /// itself has no notion of "manual delivery").
    var requiresManualDelivery: Bool {
        self == .transferReadyManual
    }
}

/// Read-only snapshot of engine state for the debug panel's status display.
struct SimulatorReadout: Equatable, Sendable {
    var isActive: Bool
    var state: MigrationState
    var mode: MigrationMode
    var orchardBalance: Zatoshi
    var timeOffset: TimeInterval
    var rows: [MigrationTransferRow]
    var signedBatchCount: Int
    var armedResultDescription: String?
    var isSplitPending: Bool
    var lastBackgroundRunSummary: String?

    init(
        isActive: Bool,
        state: MigrationState,
        mode: MigrationMode,
        orchardBalance: Zatoshi,
        timeOffset: TimeInterval,
        rows: [MigrationTransferRow],
        signedBatchCount: Int,
        armedResultDescription: String?,
        isSplitPending: Bool,
        lastBackgroundRunSummary: String?
    ) {
        self.isActive = isActive
        self.state = state
        self.mode = mode
        self.orchardBalance = orchardBalance
        self.timeOffset = timeOffset
        self.rows = rows
        self.signedBatchCount = signedBatchCount
        self.armedResultDescription = armedResultDescription
        self.isSplitPending = isSplitPending
        self.lastBackgroundRunSummary = lastBackgroundRunSummary
    }
}
