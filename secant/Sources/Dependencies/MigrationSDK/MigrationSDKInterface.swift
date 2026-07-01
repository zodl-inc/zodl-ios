//
//  MigrationSDKInterface.swift
//  zodl
//
//  Orchard → Ironwood migration SDK boundary.
//
//  Swift mirror of `interface OrchardMigrationSdk` from the Kotlin `MigrationSdk.kt` draft. The
//  production SDK is expected to expose the same shape; the dummy lives entirely in
//  `MigrationSDKLiveKey` so swapping to the real implementation means replacing `liveValue` only.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var migrationSDK: MigrationSDKClient {
        get { self[MigrationSDKClient.self] }
        set { self[MigrationSDKClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationSDKClient: Sendable {
    // ── State ──────────────────────────────────────────────────────────────
    var getMigrationState: @Sendable () -> MigrationState = { .notStarted }
    /// PROTOTYPE convenience (the Kotlin draft notes "consider exposing as Flow"): the UI observes
    /// this instead of polling `getMigrationState`.
    var stateStream: @Sendable () -> AnyPublisher<MigrationState, Never> = { Empty().eraseToAnyPublisher() }
    var getMigrationProgress: @Sendable () -> MigrationProgress? = { nil }

    // ── Note splitting ─────────────────────────────────────────────────────
    var isNoteSplitNeeded: @Sendable () -> Bool = { false }
    var prepareNoteSplit: @Sendable () async -> NoteSplitProposal = { NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) }
    var submitNoteSplit: @Sendable (NoteSplitProposal) async -> TransferResult = { _ in TransferResult.success(txId: "") }

    // ── Migration proposal ─────────────────────────────────────────────────
    var proposeMigrationTransfers: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
    /// Immediate (single-transaction) path: sweep the whole spendable Orchard balance into one
    /// Ironwood output, executable now (no denomination, no note split).
    var proposeImmediateMigrationTransfers: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
    var signAndStoreMigrationSchedule: @Sendable (MigrationSchedule) async -> Void = { _ in }

    // ── Background execution ───────────────────────────────────────────────
    var isSyncRequiredBeforeNextTransfer: @Sendable () -> Bool = { false }
    var executeNextPendingTransfer: @Sendable (NetworkPrivacyOptions) async -> TransferResult? = { _ in nil }

    // ── On-launch reconciliation ───────────────────────────────────────────
    var hasOverdueTransfers: @Sendable () -> Bool = { false }
    var hasInvalidTransfers: @Sendable () -> Bool = { false }

    // ── Invalidity recovery ────────────────────────────────────────────────
    var restartCurrentMigrationStep: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
    /// PROTOTYPE: clears a stalled transfer (reschedules it to the next window) and returns to in-progress.
    var rescheduleStalledTransfer: @Sendable () async -> Void = {}
    /// PROTOTYPE: re-creates the invalid/expired transfer in place, keeping the rest, and returns to
    /// in-progress (Figma C5).
    var recreateInvalidTransfer: @Sendable () async -> Void = {}

    // ── Lifecycle ──────────────────────────────────────────────────────────
    var initializePostUpgrade: @Sendable () -> Void = {}

    // ── PROTOTYPE additions ────────────────────────────────────────────────
    /// Set by the entry screen (immediate vs private). Not in the Kotlin draft — see `MigrationMode`.
    var selectMigrationMode: @Sendable (MigrationMode) -> Void = { _ in }
    /// Convenience read of the simulated Orchard balance at risk, for the entry/banner UI.
    var simulatedOrchardBalance: @Sendable () -> Zatoshi = { Zatoshi.zero }
    /// PROTOTYPE: completion summary for the "Migration Complete" screen (Figma C6).
    var migrationSummary: @Sendable () -> MigrationSummary = { MigrationSummary.zero }
    /// PROTOTYPE: per-transfer rows for the in-progress status list (Figma B8).
    var migrationTransfers: @Sendable () -> [MigrationTransferRow] = { [] }
    /// PROTOTYPE: whether the user dismissed the "Migration Complete" (C6) screen — the SmartBanner
    /// stops showing the completion state once true.
    var isMigrationCompleteAcknowledged: @Sendable () -> Bool = { false }
    /// PROTOTYPE: called when the user taps Done on C6, so the completion banner stops showing.
    var acknowledgeMigrationComplete: @Sendable () -> Void = {}

    // ── PROTOTYPE: background-task run log (debug observability) ──────────────
    /// Records one entry per `MigrationBackgroundWorker` run (real BGTask or the debug "Run now"), so
    /// the debug panel can show when background tasks actually fired and what the send returned.
    var recordBackgroundRun: @Sendable (MigrationBackgroundRun.Outcome) -> Void = { _ in }
    /// Persisted run history, newest first (capped). Survives Reset/Seed.
    var backgroundRunLog: @Sendable () -> [MigrationBackgroundRun] = { [] }
    var clearBackgroundRunLog: @Sendable () -> Void = {}

    /// Debug surface driven by the MigrationDebug panel (prototype; enabled in all builds).
    var debug: MigrationDebugControls = .noOp
}

/// PROTOTYPE: debug hooks that drive the dummy engine deterministically from the MigrationDebug panel.
struct MigrationDebugControls: Sendable {
    var reset: @Sendable () async -> Void = {}
    var seed: @Sendable (_ orchard: Zatoshi, _ noteCount: Int) async -> Void = { _, _ in }
    var advanceHeight: @Sendable (_ blocks: Int) async -> Void = { _ in }
    /// Confirms a pending note split immediately (skips the simulated confirmation wait).
    var confirmSplitNow: @Sendable () async -> Void = {}
    /// Arms the result the next `executeNextPendingTransfer` will return (for reproducible failures).
    var armNextTransferResult: @Sendable (TransferResult) async -> Void = { _ in }
    /// Forces the engine into a target state for previewing recovery/complete screens.
    var jumpTo: @Sendable (MigrationDebugTarget) async -> Void = { _ in }
    /// Snapshot of the current schedule + per-transfer status, for the debug read-out.
    var snapshotDescription: @Sendable () -> String = { "" }

    static let noOp = MigrationDebugControls()
}

enum MigrationDebugTarget: Equatable, Sendable {
    case overdue
    case invalidTransfer
    case syncRequired
    case complete
    case completeWithDust
}
