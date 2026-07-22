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

import Foundation
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

/// Atomic per-run snapshot of the migration's network configuration (MOB-1496 W4): Tor choice, sync
/// provider/endpoint, and broadcast provider/endpoint, taken once at the first read of a run and
/// immune to mid-run auto server switches — see `MigrationManagerClient.migrationNetworkOptions`'s
/// doc for the full lifecycle. Not part of the SDK surface: `LightWalletEndpoint` itself is not
/// `Codable`, so `Endpoint` is the persisted wrapper (`toLightWalletEndpoint()` reconstructs one for
/// SDK calls). [ext]
struct MigrationNetworkSnapshot: Equatable, Sendable, Codable {
    /// `Codable`/`Sendable` stand-in for `LightWalletEndpoint` (which is neither). Deliberately
    /// narrower than the SDK type — `singleCallTimeoutInMillis`/`streamingCallTimeoutInMillis` are
    /// fixed app constants, not part of a server's persisted identity, so they're re-applied on
    /// reconstruction (`toLightWalletEndpoint()`) rather than stored.
    struct Endpoint: Equatable, Sendable, Codable {
        let host: String
        let port: Int
        let secure: Bool

        init(host: String, port: Int, secure: Bool) {
            self.host = host
            self.port = port
            self.secure = secure
        }

        init(_ endpoint: LightWalletEndpoint) {
            self.host = endpoint.host
            self.port = endpoint.port
            self.secure = endpoint.secure
        }

        /// Reconstructs a `LightWalletEndpoint` for SDK calls, using the same
        /// `streamingCallTimeoutInMillis` constant the built-in endpoint list uses.
        func toLightWalletEndpoint() -> LightWalletEndpoint {
            LightWalletEndpoint(
                address: host,
                port: port,
                secure: secure,
                streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
            )
        }
    }

    /// The persisted pre-run Tor choice at the moment this snapshot was taken. Authoritative for the
    /// whole run once taken — a later flip of the app-wide Tor setting or `setNetworkPrivacyOptions`
    /// does not alter an already-active run; only a FRESH run (after this snapshot is cleared at
    /// run-end) picks up a new choice.
    let useTor: Bool
    let syncEndpoint: Endpoint
    let broadcastEndpoint: Endpoint
    let takenAt: Date

    /// R8-T3 (#22): computed, not stored — every construction site set this to exactly
    /// `ServerProvider.classify(host:)` of `syncEndpoint`'s own host, and both readers
    /// (`AutoServerSelectionLiveKey`'s pinning, `ServerSetupStore`'s manual-switch privacy warning)
    /// already compare it against a freshly-computed `classify(host:)` call — a stored, potentially
    /// stale copy carried no information a live re-derivation didn't already have. Dropping these
    /// two from the stored/`Codable`/memberwise-init surface also drops them from the 7 construction
    /// sites' argument lists (both compile-time enforced: the auto-generated memberwise `init` no
    /// longer accepts them). A legacy persisted blob encoded WITH these as stored keys still decodes
    /// fine — `JSONDecoder` silently ignores JSON keys that aren't in the (now-shorter) synthesized
    /// `CodingKeys`.
    var syncProvider: ServerProvider { ServerProvider.classify(host: syncEndpoint.host) }
    /// See `syncProvider`'s doc — same computed treatment, classifying `broadcastEndpoint`'s host.
    var broadcastProvider: ServerProvider { ServerProvider.classify(host: broadcastEndpoint.host) }
}

/// MOB-1496 (W4; extracted R8-T7 #10): shared active-snapshot pinning predicate for automatic
/// server selection. `true` when NO account has an active migration network snapshot (unfiltered —
/// every candidate stays eligible, byte-identical to pre-W4 behavior), or when `host`'s classified
/// provider is a member of the snapshotted SYNC providers (rotation within an active run's own
/// family stays allowed). That single check already keeps out any provider that is ONLY some
/// snapshot's broadcast provider, with no separate exclusion clause needed: the custom/testnet
/// same-server case (sync == broadcast) stays allowed because that provider IS a sync provider too.
///
/// Single source of truth for the two independent automatic-selection entry points that must never
/// let a switch land on an in-flight migration run's separated broadcast provider:
/// `AutoServerSelectionLiveKey`'s own automatic-selection loop (`findBestServer`/`applySwitch`,
/// where this predicate originated as a private, file-local copy — W4) and `ServerSetup`'s
/// automatic Save path (R8-T7 #10, which had no filter of its own at all before this).
enum MigrationServerPinning {
    static func isCandidateAllowed(host: String, activeSnapshots: [MigrationNetworkSnapshot]) -> Bool {
        guard !activeSnapshots.isEmpty else { return true }

        let syncProviders = Set(activeSnapshots.map { $0.syncProvider })
        return syncProviders.contains(ServerProvider.classify(host: host))
    }
}

/// App-persisted record of the committed migration schedule (MOB-1496 W2): the SDK retains no
/// proposal list once a schedule is committed, so this is the app's only record of it — the
/// payload `migrationSummary`/`migrationTransfers` derive rows/totals from. Not part of the SDK
/// surface, though it embeds `MigrationSchedule` (already `Codable`) as-is. [ext]
struct MigrationCommittedSchedule: Equatable, Sendable, Codable {
    /// One broadcast transfer, recorded the moment its broadcast succeeds — append-only across
    /// restarts within one logical run (a re-created plan after a restart continues the same run,
    /// preserving prior sent rows with their checks).
    struct SentRecord: Equatable, Sendable, Codable {
        let transferId: String
        let amount: Zatoshi
        /// `nil` when the broadcast landed but the txId is unknown (e.g. the engine's recording
        /// itself failed after a successful broadcast) — never an empty string.
        let txId: String?
        let sentAt: Date
    }

    /// The confirmed schedule (SDK type, already `Codable`).
    var schedule: MigrationSchedule
    var sentRecords: [SentRecord]
    var committedAt: Date
}
