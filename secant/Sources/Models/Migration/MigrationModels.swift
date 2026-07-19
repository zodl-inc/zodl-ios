//
//  MigrationModels.swift
//  Zashi
//
//  App-only value models for the Orchard -> Ironwood migration (MOB-1459/MOB-1496). The SDK-shaped
//  models (`MigrationState`, `MigrationAttentionReason`, `MigrationProgress`, `NoteSplitProposal`,
//  `MigrationTransferProposal`, `MigrationSchedule`, `MigrationTransferResult`,
//  `MigrationNetworkPrivacyOptions`, …) now come straight from `ZcashLightClientKit` — this file
//  only keeps the types that have no SDK counterpart.
//

@preconcurrency import ZcashLightClientKit

/// Aggregate summary of the migration for progress UI. Not part of the SDK surface. [ext]
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

/// A single row in the migration transfers list UI. Not part of the SDK surface. [ext]
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
    /// Precise "sent N minutes ago" recency for a `.sent` row under an hour old; `nil` keeps the
    /// existing `hoursFromNow`-based caption (0 = "sent recently", otherwise "Sent Nh ago").
    var sentMinutesAgo: Int?
    /// True for the row currently broadcasting to the network — same `.active` badge as a
    /// merely-queued row, captioned "Sending now" instead of an ETA.
    var isBroadcasting: Bool

    init(
        id: String,
        index: Int,
        amount: Zatoshi,
        status: Status,
        hoursFromNow: Int,
        sentMinutesAgo: Int? = nil,
        isBroadcasting: Bool = false
    ) {
        self.id = id
        self.index = index
        self.amount = amount
        self.status = status
        self.hoursFromNow = hoursFromNow
        self.sentMinutesAgo = sentMinutesAgo
        self.isBroadcasting = isBroadcasting
    }
}

/// User's chosen migration privacy/timing mode. Not part of the SDK surface. [ext]
enum MigrationMode: String, Equatable, Sendable, Codable {
    case immediate
    case privateScheduled
}
