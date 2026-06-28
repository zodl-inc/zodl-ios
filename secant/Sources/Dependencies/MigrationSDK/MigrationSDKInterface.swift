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
    var signAndStoreMigrationSchedule: @Sendable (MigrationSchedule) async -> Void = { _ in }

    // ── Background execution ───────────────────────────────────────────────
    var isSyncRequiredBeforeNextTransfer: @Sendable () -> Bool = { false }
    var executeNextPendingTransfer: @Sendable (NetworkPrivacyOptions) async -> TransferResult? = { _ in nil }

    // ── On-launch reconciliation ───────────────────────────────────────────
    var hasOverdueTransfers: @Sendable () -> Bool = { false }
    var hasInvalidTransfers: @Sendable () -> Bool = { false }

    // ── Invalidity recovery ────────────────────────────────────────────────
    var restartCurrentMigrationStep: @Sendable () async -> MigrationSchedule = { MigrationSchedule(transfers: [], estimatedDurationHours: 0) }

    // ── Lifecycle ──────────────────────────────────────────────────────────
    var initializePostUpgrade: @Sendable () -> Void = {}

    // ── PROTOTYPE additions ────────────────────────────────────────────────
    /// Set by the entry screen (immediate vs private). Not in the Kotlin draft — see `MigrationMode`.
    var selectMigrationMode: @Sendable (MigrationMode) -> Void = { _ in }
    /// Convenience read of the simulated Orchard balance at risk, for the entry/banner UI.
    var simulatedOrchardBalance: @Sendable () -> Zatoshi = { Zatoshi.zero }
    /// Debug surface driven by the MigrationDebug panel (DEBUG builds only).
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
