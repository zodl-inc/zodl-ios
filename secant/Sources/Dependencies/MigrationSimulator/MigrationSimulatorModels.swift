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
//  MOB-1496: `SimulatorSnapshot.state`/`armedTransferResult` now hold the real SDK's
//  `MigrationState`/`MigrationTransferResult`, neither of which conforms to `Codable` (the SDK
//  deliberately keeps them `Equatable, Sendable` only — see `MigrationModels.swift` in the SDK
//  checkout). `SimulatorSnapshot` still needs to round-trip through JSON (`MigrationSimulator
//  StateStore` persists it to disk), so its `Codable` conformance is now hand-written, bridging
//  through the small DTOs below; `currentSchemaVersion` is bumped so any pre-MOB-1496 on-disk
//  snapshot reseeds cleanly through the store's existing mismatch-reseeds path rather than trying
//  (and failing) to decode the old shape.
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
struct SimulatorSnapshot: Equatable, Sendable {
    /// Bump whenever this shape changes; the store treats a mismatch like a decode failure.
    /// MOB-1496: bumped 2 -> 3 — `state`/`armedTransferResult`'s on-disk JSON shape changed when
    /// they moved onto the SDK's (hand-Codable-bridged) `MigrationState`/`MigrationTransferResult`.
    static let currentSchemaVersion = 3

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
            dustRemainder: Zatoshi.zero,
            isDustLocked: false
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
    var armedTransferResult: MigrationTransferResult?
    var armedSplitFailure: Bool
    var splitSubmittedAt: Date?
    /// Keystone: count of PCZTs most recently stored via `storeSignedBatch`.
    var signedBatchCount: Int
    var rngSeed: UInt64
    /// One-line summary of the most recent `executeNext` outcome, for the debug panel.
    var lastBackgroundRunSummary: String?
    /// Balance left over once every transfer has been sent (usually `.zero`).
    var dustRemainder: Zatoshi
    /// MOB-1487: "Lock balance" acknowledged — the dust remainder is marked unspendable and the
    /// complete screen re-enters on its locked confirmation instead of re-offering resolution.
    var isDustLocked: Bool

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
        armedTransferResult: MigrationTransferResult?,
        armedSplitFailure: Bool,
        splitSubmittedAt: Date?,
        signedBatchCount: Int,
        rngSeed: UInt64,
        lastBackgroundRunSummary: String?,
        dustRemainder: Zatoshi,
        isDustLocked: Bool
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
        self.isDustLocked = isDustLocked
    }
}

// MARK: - MOB-1496: hand-written Codable (state / armedTransferResult bridge through DTOs)

extension SimulatorSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, isActive, orchardBalance, notes, mode, state, transfers, timeOffset,
             syncRequired, armedTransferResult, armedSplitFailure, splitSubmittedAt, signedBatchCount,
             rngSeed, lastBackgroundRunSummary, dustRemainder, isDustLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        orchardBalance = try container.decode(Zatoshi.self, forKey: .orchardBalance)
        notes = try container.decode([Zatoshi].self, forKey: .notes)
        mode = try container.decode(MigrationMode.self, forKey: .mode)
        state = try container.decode(MigrationStateDTO.self, forKey: .state).value
        transfers = try container.decode([SimulatorTransfer].self, forKey: .transfers)
        timeOffset = try container.decode(TimeInterval.self, forKey: .timeOffset)
        syncRequired = try container.decode(Bool.self, forKey: .syncRequired)
        armedTransferResult = try container.decodeIfPresent(MigrationTransferResultDTO.self, forKey: .armedTransferResult)?.value
        armedSplitFailure = try container.decode(Bool.self, forKey: .armedSplitFailure)
        splitSubmittedAt = try container.decodeIfPresent(Date.self, forKey: .splitSubmittedAt)
        signedBatchCount = try container.decode(Int.self, forKey: .signedBatchCount)
        rngSeed = try container.decode(UInt64.self, forKey: .rngSeed)
        lastBackgroundRunSummary = try container.decodeIfPresent(String.self, forKey: .lastBackgroundRunSummary)
        dustRemainder = try container.decode(Zatoshi.self, forKey: .dustRemainder)
        isDustLocked = try container.decode(Bool.self, forKey: .isDustLocked)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(orchardBalance, forKey: .orchardBalance)
        try container.encode(notes, forKey: .notes)
        try container.encode(mode, forKey: .mode)
        try container.encode(MigrationStateDTO(state), forKey: .state)
        try container.encode(transfers, forKey: .transfers)
        try container.encode(timeOffset, forKey: .timeOffset)
        try container.encode(syncRequired, forKey: .syncRequired)
        try container.encodeIfPresent(armedTransferResult.map(MigrationTransferResultDTO.init), forKey: .armedTransferResult)
        try container.encode(armedSplitFailure, forKey: .armedSplitFailure)
        try container.encodeIfPresent(splitSubmittedAt, forKey: .splitSubmittedAt)
        try container.encode(signedBatchCount, forKey: .signedBatchCount)
        try container.encode(rngSeed, forKey: .rngSeed)
        try container.encodeIfPresent(lastBackgroundRunSummary, forKey: .lastBackgroundRunSummary)
        try container.encode(dustRemainder, forKey: .dustRemainder)
        try container.encode(isDustLocked, forKey: .isDustLocked)
    }
}

/// Lossless Codable mirror of the SDK's `MigrationState` (not itself `Codable`). `.value` converts
/// back; the failable initializer direction is total (every `MigrationState` case has a DTO case).
private enum MigrationStateDTO: Codable {
    case notStarted
    case splitPendingConfirmation
    case readyToPropose
    case inProgress(MigrationProgressDTO)
    case requiresAttention(MigrationAttentionReasonDTO)
    case complete

    init(_ state: MigrationState) {
        switch state {
        case MigrationState.notStarted: self = .notStarted
        case MigrationState.splitPendingConfirmation: self = .splitPendingConfirmation
        case MigrationState.readyToPropose: self = .readyToPropose
        case let MigrationState.inProgress(progress): self = .inProgress(MigrationProgressDTO(progress))
        case let MigrationState.requiresAttention(reason): self = .requiresAttention(MigrationAttentionReasonDTO(reason))
        case MigrationState.complete: self = .complete
        }
    }

    var value: MigrationState {
        switch self {
        case .notStarted: return MigrationState.notStarted
        case .splitPendingConfirmation: return MigrationState.splitPendingConfirmation
        case .readyToPropose: return MigrationState.readyToPropose
        case let .inProgress(progress): return MigrationState.inProgress(progress.value)
        case let .requiresAttention(reason): return MigrationState.requiresAttention(reason.value)
        case .complete: return MigrationState.complete
        }
    }
}

/// Lossless Codable mirror of the SDK's `MigrationProgress`.
private struct MigrationProgressDTO: Codable {
    var completedTransfers: Int
    var totalTransfers: Int
    var remainingOrchard: Zatoshi
    var nextTransferReadyAtHeight: BlockHeight?

    init(_ progress: MigrationProgress) {
        completedTransfers = progress.completedTransfers
        totalTransfers = progress.totalTransfers
        remainingOrchard = progress.remainingOrchard
        nextTransferReadyAtHeight = progress.nextTransferReadyAtHeight
    }

    var value: MigrationProgress {
        MigrationProgress(
            completedTransfers: completedTransfers,
            totalTransfers: totalTransfers,
            remainingOrchard: remainingOrchard,
            nextTransferReadyAtHeight: nextTransferReadyAtHeight
        )
    }
}

/// Lossless Codable mirror of the SDK's `MigrationAttentionReason`.
private enum MigrationAttentionReasonDTO: Codable {
    case invalidTransfer(transferId: String)
    case transferExpired
    case syncRequiredBeforeNext

    init(_ reason: MigrationAttentionReason) {
        switch reason {
        case let MigrationAttentionReason.invalidTransfer(transferId): self = .invalidTransfer(transferId: transferId)
        case MigrationAttentionReason.transferExpired: self = .transferExpired
        case MigrationAttentionReason.syncRequiredBeforeNext: self = .syncRequiredBeforeNext
        }
    }

    var value: MigrationAttentionReason {
        switch self {
        case let .invalidTransfer(transferId): return MigrationAttentionReason.invalidTransfer(transferId: transferId)
        case .transferExpired: return MigrationAttentionReason.transferExpired
        case .syncRequiredBeforeNext: return MigrationAttentionReason.syncRequiredBeforeNext
        }
    }
}

/// Lossless Codable mirror of the SDK's `MigrationTransferResult`.
private enum MigrationTransferResultDTO: Codable {
    case success(txId: String)
    case networkError(retryable: Bool)
    case invalidNote
    case expired

    init(_ result: MigrationTransferResult) {
        switch result {
        case let MigrationTransferResult.success(txId): self = .success(txId: txId)
        case let MigrationTransferResult.networkError(retryable): self = .networkError(retryable: retryable)
        case MigrationTransferResult.invalidNote: self = .invalidNote
        case MigrationTransferResult.expired: self = .expired
        }
    }

    var value: MigrationTransferResult {
        switch self {
        case let .success(txId): return MigrationTransferResult.success(txId: txId)
        case let .networkError(retryable): return MigrationTransferResult.networkError(retryable: retryable)
        case .invalidNote: return MigrationTransferResult.invalidNote
        case .expired: return MigrationTransferResult.expired
        }
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
    /// MOB-1487: dust remainder + lock acknowledgement, surfaced in the panel's status readout.
    var dustRemainder: Zatoshi
    var isDustLocked: Bool

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
        lastBackgroundRunSummary: String?,
        dustRemainder: Zatoshi,
        isDustLocked: Bool
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
        self.dustRemainder = dustRemainder
        self.isDustLocked = isDustLocked
    }
}
