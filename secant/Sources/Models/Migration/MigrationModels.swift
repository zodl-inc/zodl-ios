//
//  MigrationModels.swift
//  zodl
//
//  Orchard → Ironwood migration — value types.
//
//  Swift mirror of the Kotlin `MigrationSdk.kt` draft (1:1, idiomatic Swift). The real SDK is
//  expected to expose the same shape, so swapping the dummy implementation for the production SDK
//  should not require changes here. Amounts use `Zatoshi`; heights use `BlockHeight` (Int).
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// Which migration option the user chose at the entry screen.
///
/// PROTOTYPE: not present in the Kotlin draft — the Figma offers "Migrate Immediately" vs
/// "Migrate with Privacy" at entry, and the engine returns a 1-transfer (immediate, executable now)
/// or N-transfer (private, scheduled) plan from the same `proposeMigrationTransfers()` depending on
/// the selected mode. The real SDK can decide how to model this distinction.
enum MigrationMode: String, Equatable, Sendable, Codable {
    case immediate
    case privateScheduled
}

/// Controls how migration transactions are broadcast.
///
/// `submissionEndpoint == nil` means "use the same LWD server as sync". A secondary endpoint
/// de-correlates sync and submission traffic (privacy improvement).
struct NetworkPrivacyOptions: Equatable, Sendable, Codable {
    var useTor: Bool
    var submissionEndpoint: String?

    init(useTor: Bool, submissionEndpoint: String? = nil) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }
}

/// SDK-generated note-split proposal. The SDK decides the number of output notes, their sizes, and
/// randomisation — the app only shows this for confirmation.
struct NoteSplitProposal: Equatable, Sendable, Codable {
    var outputNotes: [Zatoshi]
    var fee: Zatoshi

    init(outputNotes: [Zatoshi], fee: Zatoshi) {
        self.outputNotes = outputNotes
        self.fee = fee
    }
}

/// A single scheduled migration transfer.
///
/// `anchorHeight` is chosen from a shared, network-wide 288-block bucket (≈6h), hiding the wallet's
/// last sync time. `nextExecutableAfterHeight` is what the app uses to schedule the background task.
/// `expiryHeight` — if not broadcast before this height the transfer becomes invalid and
/// `restartCurrentMigrationStep()` must be called.
struct TransferProposal: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var amount: Zatoshi
    var anchorHeight: BlockHeight
    var nextExecutableAfterHeight: BlockHeight
    var expiryHeight: BlockHeight

    init(
        id: String,
        amount: Zatoshi,
        anchorHeight: BlockHeight,
        nextExecutableAfterHeight: BlockHeight,
        expiryHeight: BlockHeight
    ) {
        self.id = id
        self.amount = amount
        self.anchorHeight = anchorHeight
        self.nextExecutableAfterHeight = nextExecutableAfterHeight
        self.expiryHeight = expiryHeight
    }
}

/// Full migration schedule. Shown to the user for one-time review before signing. After sign+store,
/// individual transfers do not require per-send confirmation.
struct MigrationSchedule: Equatable, Sendable, Codable {
    var transfers: [TransferProposal]
    var estimatedDurationHours: Int

    init(transfers: [TransferProposal], estimatedDurationHours: Int) {
        self.transfers = transfers
        self.estimatedDurationHours = estimatedDurationHours
    }
}

/// Live migration progress used by the progress UI.
///
/// `nextTransferReadyAtHeight` is nil when all transfers are complete or migration has not started.
struct MigrationProgress: Equatable, Sendable, Codable {
    var completedTransfers: Int
    var totalTransfers: Int
    var remainingOrchard: Zatoshi
    var nextTransferReadyAtHeight: BlockHeight?

    init(
        completedTransfers: Int,
        totalTransfers: Int,
        remainingOrchard: Zatoshi,
        nextTransferReadyAtHeight: BlockHeight?
    ) {
        self.completedTransfers = completedTransfers
        self.totalTransfers = totalTransfers
        self.remainingOrchard = remainingOrchard
        self.nextTransferReadyAtHeight = nextTransferReadyAtHeight
    }
}

/// Summary of a finished (or in-flight) migration, used by the "Migration Complete" screen (Figma C6).
///
/// PROTOTYPE: the real SDK can expose an equivalent for its completion UI. `dust` is the remainder left
/// in Orchard (0 in the clean case, a sub-threshold amount in the dust case).
struct MigrationSummary: Equatable, Sendable, Codable {
    var transferred: Zatoshi
    var dust: Zatoshi
    var transfersSent: Int
    var transfersTotal: Int
    var estimatedDurationHours: Int

    static let zero = MigrationSummary(
        transferred: .zero,
        dust: .zero,
        transfersSent: 0,
        transfersTotal: 0,
        estimatedDurationHours: 0
    )

    init(
        transferred: Zatoshi,
        dust: Zatoshi,
        transfersSent: Int,
        transfersTotal: Int,
        estimatedDurationHours: Int
    ) {
        self.transferred = transferred
        self.dust = dust
        self.transfersSent = transfersSent
        self.transfersTotal = transfersTotal
        self.estimatedDurationHours = estimatedDurationHours
    }
}

/// A single row in the in-progress transfer list (Figma B8). PROTOTYPE view-model surfaced by the SDK
/// so the status screen can render per-transfer state without owning the schedule.
struct MigrationTransferRow: Equatable, Sendable, Codable, Identifiable {
    enum Status: Equatable, Sendable, Codable {
        /// Broadcast and confirmed.
        case sent
        /// The next transfer, ready to send now.
        case active
        /// Pending but its window has passed.
        case overdue
        /// A future scheduled transfer.
        case pending
        case invalid
        case expired
    }

    var id: String
    /// 0-based position in the schedule.
    var index: Int
    var amount: Zatoshi
    var status: Status
    /// Approx hours until this transfer's window (0 = ready now). Only meaningful for pending rows.
    var hoursFromNow: Int

    init(id: String, index: Int, amount: Zatoshi, status: Status, hoursFromNow: Int) {
        self.id = id
        self.index = index
        self.amount = amount
        self.status = status
        self.hoursFromNow = hoursFromNow
    }
}

/// Why a migration cannot proceed automatically and needs the user.
enum AttentionReason: Equatable, Sendable, Codable {
    /// Input note was spent externally before the transfer was broadcast.
    case invalidTransfer(transferId: String)
    /// Transaction anchor expired before broadcast (e.g. extended offline period).
    case transferExpired
    /// A transfer produced change back to Orchard that must be synced before the next transfer.
    case syncRequiredBeforeNext
    /// A scheduled transfer wasn't sent (network error / the background task didn't run). Retryable:
    /// the user can send it now or reschedule it. `transferNumber` is the 1-based position in the plan.
    case transferStalled(transferNumber: Int)
}

/// Top-level migration state machine.
///
/// `notStarted → splitPendingConfirmation → readyToPropose → inProgress → (requiresAttention) → complete`
enum MigrationState: Equatable, Sendable, Codable {
    /// No migration has been initiated. Show the migration entry point.
    case notStarted
    /// Note-split transaction submitted, waiting for on-chain confirmation (~1 block).
    case splitPendingConfirmation
    /// Split confirmed (or not needed). Ready to call `proposeMigrationTransfers()`.
    case readyToPropose
    /// Schedule is committed and transfers are executing.
    case inProgress(MigrationProgress)
    /// A transfer cannot proceed automatically; surface a non-error prompt and call
    /// `restartCurrentMigrationStep()` after the user acknowledges.
    case requiresAttention(AttentionReason)
    /// All transfers confirmed on-chain. Orchard balance is zero.
    case complete
}

/// Result of a broadcast attempt. The app maps each case to a specific action — do not collapse
/// these into a generic error.
enum TransferResult: Equatable, Sendable, Codable {
    case success(txId: String)
    /// Transient network failure. Retry in the next background window.
    case networkError(retryable: Bool)
    /// Input note already spent — sets `requiresAttention`; call `restartCurrentMigrationStep()`.
    case invalidNote
    /// Anchor height expired — same handling as `invalidNote`.
    case expired
}
