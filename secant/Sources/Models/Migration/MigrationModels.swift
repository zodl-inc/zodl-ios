//
//  MigrationModels.swift
//  Zashi
//
//  Value models for the Orchard -> Ironwood migration (MOB-1459). All types are
//  `Equatable, Sendable, Codable` since they will be persisted via `@Shared(.appStorage)`
//  later. Each type's doc comment maps it to its `MigrationSdk.kt` counterpart and carries a
//  `[draft]` (Kotlin draft 1:1) or `[ext]` (proposed SDK extension) marker.
//

@preconcurrency import ZcashLightClientKit

/// Network/privacy configuration for migration transfer submission.
/// Kotlin: `NetworkPrivacyOptions` — [draft]
struct NetworkPrivacyOptions: Equatable, Sendable, Codable {
    var useTor: Bool
    /// `nil` = same LWD server as sync.
    var submissionEndpoint: String?

    init(useTor: Bool, submissionEndpoint: String?) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }
}

/// Proposal to split existing Orchard notes so migration transfers have suitable note sizes.
/// Kotlin: `NoteSplitProposal` — [draft]
struct NoteSplitProposal: Equatable, Sendable, Codable {
    var outputNotes: [Zatoshi]
    var fee: Zatoshi

    init(outputNotes: [Zatoshi], fee: Zatoshi) {
        self.outputNotes = outputNotes
        self.fee = fee
    }
}

/// A single scheduled migration transfer.
/// Kotlin: `TransferProposal` — [draft]
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

/// The full set of proposed migration transfers plus a duration estimate.
/// Kotlin: `MigrationSchedule` — [draft]
struct MigrationSchedule: Equatable, Sendable, Codable {
    var transfers: [TransferProposal]
    var estimatedDurationHours: Int

    init(transfers: [TransferProposal], estimatedDurationHours: Int) {
        self.transfers = transfers
        self.estimatedDurationHours = estimatedDurationHours
    }
}

/// Snapshot of in-progress migration execution.
/// Kotlin: `MigrationProgress` — [draft]
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

/// Aggregate summary of the migration for progress UI. Not part of the Kotlin draft.
/// [ext]
struct MigrationSummary: Equatable, Sendable, Codable {
    /// All-zero convenience value, e.g. before any migration data has loaded.
    static let zero = MigrationSummary(
        transferred: Zatoshi.zero,
        dust: Zatoshi.zero,
        transfersSent: 0,
        transfersTotal: 0,
        estimatedDurationHours: 0
    )

    var transferred: Zatoshi
    var dust: Zatoshi
    var transfersSent: Int
    var transfersTotal: Int
    var estimatedDurationHours: Int

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

/// A single row in the migration transfers list UI. Not part of the Kotlin draft.
/// [ext]
struct MigrationTransferRow: Equatable, Sendable, Codable, Identifiable {
    enum Status: Equatable, Sendable, Codable {
        case sent
        case active
        case overdue
        case pending
        case invalid
        case expired
    }

    var id: String
    /// 0-based position in the schedule.
    var index: Int
    var amount: Zatoshi
    var status: Status
    /// 0 = ready now; meaningful for pending rows.
    var hoursFromNow: Int

    init(id: String, index: Int, amount: Zatoshi, status: Status, hoursFromNow: Int) {
        self.id = id
        self.index = index
        self.amount = amount
        self.status = status
        self.hoursFromNow = hoursFromNow
    }
}

/// Reasons the migration flow needs the user's attention.
enum AttentionReason: Equatable, Sendable, Codable {
    /// Kotlin: `AttentionReason.InvalidTransfer` — [draft]
    case invalidTransfer(transferId: String)
    /// Kotlin: `AttentionReason.TransferExpired` — [draft]
    case transferExpired
    /// Kotlin: `AttentionReason.SyncRequiredBeforeNext` — [draft]
    case syncRequiredBeforeNext
    /// 1-based. Not part of the Kotlin draft. [ext]
    case transferStalled(transferNumber: Int)
}

/// Overall migration state machine.
/// Kotlin: `MigrationState` — [draft]
enum MigrationState: Equatable, Sendable, Codable {
    case notStarted
    case splitPendingConfirmation
    case readyToPropose
    case inProgress(MigrationProgress)
    case requiresAttention(AttentionReason)
    case complete
}

/// Outcome of submitting a single migration transfer (or note split).
/// Kotlin: `TransferResult` — [draft]
enum TransferResult: Equatable, Sendable, Codable {
    case success(txId: String)
    case networkError(retryable: Bool)
    case invalidNote
    case expired
}

/// User's chosen migration privacy/timing mode. Not part of the Kotlin draft.
/// [ext]
enum MigrationMode: String, Equatable, Sendable, Codable {
    case immediate
    case privateScheduled
}
