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
    /// Convenience value for e.g. before any migration data has loaded: `dust`/the transfer
    /// counts read genuinely zero, while `transferred`/`estimatedDurationHours` read `nil` — the
    /// same "not yet known" pairing the W1 fallback (no committed schedule persisted) returns for
    /// both (MOB-1513; see `MigrationManagerImpl.migrationSummary`'s doc).
    static let zero = MigrationSummary(
        transferred: nil,
        dust: Zatoshi.zero,
        transfersSent: 0,
        transfersTotal: 0,
        estimatedDurationHours: nil
    )

    /// The value transferred so far. `nil` when not derivable from a persisted schedule (the W1
    /// fallback, before any committed schedule exists) — never a placeholder `Zatoshi.zero`
    /// (MOB-1513).
    var transferred: Zatoshi?
    var dust: Zatoshi
    var transfersSent: Int
    var transfersTotal: Int
    /// A rough estimate of the schedule's total remaining duration, in hours. `nil` on the same
    /// W1 fallback `transferred` is — never a placeholder `0` (MOB-1513).
    var estimatedDurationHours: Int?

    init(
        transferred: Zatoshi?,
        dust: Zatoshi,
        transfersSent: Int,
        transfersTotal: Int,
        estimatedDurationHours: Int?
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
        /// GROUND_RULES R11 (2026-08-03): DONE — and "done" means WALLET-CONFIRMED: the transaction
        /// is mined AND the wallet's own transaction store has observed it, the same standard
        /// Activity and the home balances use. Only this state renders the green check, counts
        /// toward "N of M", and moves the pool-header figures — because this is the moment the
        /// transfer has pool impact. Before R11 this fired at broadcast success (two phases early),
        /// which is how the field got three green checks summing 55.2 ZEC over an Ironwood balance
        /// of 0.
        case sent
        /// GROUND_RULES R11: ON THE CHAIN'S SIDE of the turnstile — broadcast (possibly already
        /// mined per the ENGINE) but not yet observed by the wallet's own store. Routine, not an
        /// edge: the SDK deliberately holds sync after a broadcast (180 s testnet / 600 s mainnet
        /// privacy buffer, ZIP 318 session separation), so every transfer sits here for minutes.
        /// Renders as the neutral (non-green) check with the "Confirming…" caption, no spinner —
        /// the work is the chain's, not the app's, and closing the app costs nothing
        /// (see `isInFlight`'s doc for why the spinner is reserved for the app's own work).
        /// Never actionable: not replannable (it is on the wire), never "next".
        case confirming
        case active
        case overdue
        case pending
        case invalid
        case expired
    }

    /// MOB-1513 (A2): which kind of row this is — a genuine element of `schedule.transfers`
    /// (numbered "Transfer N", the ordinary active/pending/overdue/etc. badge machinery) or the
    /// synthesized "Split Balance" row a caller opts into ahead of them. The note-split is a real,
    /// separate broadcast (immediate at commit) that is never itself an element of
    /// `schedule.transfers` — see `MigrationTransferTimeline`'s header doc for the fix this
    /// replaced (a silent index-0 relabel that let an ordinary transfer masquerade as the split).
    /// `.transfer` is the default so every existing construction site (all of them genuine
    /// schedule/sent-record rows) needs no change.
    enum Kind: Equatable, Sendable, Codable {
        case transfer
        case splitBalance
    }

    var id: String
    /// 0-based position in the schedule.
    var index: Int
    /// The value crossing the turnstile on this row. `nil` when not derivable — a status-only
    /// (live per-transaction statuses, no persisted schedule) or progress-only synthesized
    /// fallback row (MOB-1513; see `MigrationDerivations.statusOnlyTransferRows`'s and
    /// `MigrationManagerImpl.synthesizedTransferRows`'s docs). A genuine schedule/sentRecord-
    /// derived row always carries its real, non-nil value — never a placeholder `Zatoshi.zero`.
    var amount: Zatoshi?
    var status: Status
    /// 0 = ready now; meaningful for pending rows. Coarse (whole-hour) — the forward-ETA caption
    /// prefers `minutesFromNow` when set; the BACKWARD "Sent Nh ago" / "Overdue Nh ago" captions
    /// read this directly.
    var hoursFromNow: Int
    /// MOB-1513 (B3): minute-precise FORWARD ETA for a pending/active row — the block-delta value
    /// `MigrationETA.minutesFromNow(scheduledHeight:currentTip:)` computes, so a sub-hour transfer
    /// renders "in ~N mins" instead of flooring to `hoursFromNow` and hitting the old "~10 mins"
    /// fallback. MOB-1513 (A3): `MigrationDerivations.transferRows` now sets this for every non-sent
    /// row derived from a committed schedule (Status/Progress/Resume included), from that row's own
    /// `nextExecutableAfterHeight` — so it's `nil` only on the W1 progress-only fallback
    /// (`synthesizedTransferRows`, no committed schedule persisted yet), where the caption falls
    /// back to `hoursFromNow`'s coarse position-based estimate. Backward ("ago") captions never
    /// read this. See `forwardETAMinutes`.
    var minutesFromNow: Int?
    /// Precise "sent N minutes ago" recency for a `.sent` row under an hour old; `nil` keeps the
    /// existing `hoursFromNow`-based caption (0 = "sent recently", otherwise "Sent Nh ago").
    var sentMinutesAgo: Int?
    /// True for a row the engine has BROADCAST (`.broadcast(txid:)`) and not yet seen mined — same
    /// `.active` badge as a merely-queued row, captioned "Sent recently" instead of an ETA.
    ///
    /// The name says "broadcasting" and the state means "broadcast". That is the distinction the
    /// field caught on 2026-08-01 ("there is never ending sending of split 1"): the submit itself is
    /// about two seconds, while this flag stays true for the minutes it takes to mine — plus the
    /// SDK's post-broadcast privacy buffer, during which the wallet is not even allowed to look.
    /// Anything reading this flag is describing a transaction ON THE WIRE, not one being typed onto
    /// it.
    var isBroadcasting: Bool
    /// MOB-1466 (smart-banner pass): true for a row the engine says the wallet can PROVE right now
    /// — `MigrationTransactionStatus.isReady` with `nextAction == .prove`. Captioned "Preparing
    /// transaction…" instead of an ETA (Figma C5), and it is what raises the run-level
    /// `.preparing` banner.
    ///
    /// Deliberately the engine's own readiness verdict rather than the lifecycle state: a `.signed`
    /// transfer whose anchor boundary the wallet has not scanned yet reports `isReady == false` /
    /// `blockedOn == .anchorBoundary`, and that row is NOT preparing — nothing the user does by
    /// staying in the app makes it prove. Only a row the app can act on this second earns the
    /// "keep Zodl open" ask.
    ///
    /// Unlike `status`, this is a FLAG because preparing is plural: `C5` shows Transfer 1 and
    /// Transfer 2 both preparing at once (one prove sweep proves the whole run), while `.active` is
    /// by construction the single first non-sent row. Mutually exclusive with `isBroadcasting` in
    /// practice — a broadcast transfer is already proved.
    var isPreparing: Bool
    /// MOB-1466 (field, 2026-08-03): this row's transaction is ON THE WIRE right now — the app is
    /// inside `performMigrationBroadcast` for it, this second.
    ///
    /// NOT the same fact as `isBroadcasting`, and the difference is the whole point. `isBroadcasting`
    /// comes from the engine's durable `.broadcast(txid:)`: SUBMITTED, awaiting mining, minutes of
    /// chain work with the app free to close. `isSubmitting` is the ~7 s window BEFORE that, when the
    /// submit call has not returned, the work is this device's, and closing the app kills it.
    ///
    /// It exists because that window had no representation anywhere. The field log:
    ///
    ///     +0.50s broadcasting migration tx 0 — headless send session
    ///     +0.58s BANNER -> inProgress   ·   why: submitting now      <- "We'll notify you when to send"
    ///     +7.67s broadcast result: success(txId: dd8792ff…)
    ///
    /// The banner's own reason string said "submitting now" while its copy said nothing was
    /// happening, and the timeline agreed with the copy rather than the truth — no spinner, no
    /// caption, because the durable row was still `ready`. A user who opened the app on a
    /// notification, watched it blink, and read "we'll notify you when to send" has been told their
    /// tap was pointless. It was the opposite: it put their note-split on the network.
    ///
    /// Purely in-session by nature — there is no durable form of "a call is in progress", and an app
    /// kill mid-submit means it is no longer true.
    var isSubmitting: Bool
    /// FIND-1 (2026-08-05, campaign 7): the engine says this row is waiting on OTHER transactions
    /// of its own run (`blockedOn == .dependencies` — unmined preparations, an earlier transfer).
    /// Straight from the row's joined live status; `false` when no status joined (no guess).
    ///
    /// Two honesty rules read it. The derivation's `nonSentRowStatus` vetoes the schedule-clock
    /// `.overdue` badge for such a row — the wallet-wide overdue aggregate counts preparation rows
    /// too, so a due note-split used to stamp "Overdue · 1 min ago" on Transfer 1 while the very
    /// preparations funding it were still unmined; a dependency-blocked row is ON PLAN, not late.
    /// And `MigrationStatusView`'s caption prefers the dependency truth over a "Ready now" the
    /// engine would refuse.
    ///
    /// NOT part of `isInFlight`: nothing is running on this device for a dependency-blocked row,
    /// so it never earns the spinner or the keep-open ask.
    var isAwaitingRunDependencies: Bool
    /// MOB-1466 (Lukas's ruling, 2026-08-08): the engine says this row is held by its drawn ANCHOR
    /// BOUNDARY (`blockedOn == .anchorBoundary`) — the boundary block has not settled, so the
    /// transfer cannot be proved against it yet. Straight from the row's joined live status;
    /// `false` when no status joined (no guess), exactly like `isAwaitingRunDependencies`.
    ///
    /// It exists because this is the ONE arrived-window row whose time is not being recomputed.
    /// The engine's overdue re-spread deliberately excludes anchor-gated transfers — re-spreading
    /// on one "would shift the whole plan … every time the gate was waited out, chasing its own
    /// tail" (`zcash_pool_migration`, satisfiability.rs) — so no shift will ever move this row's
    /// scheduled height. Every OTHER arrived row says "Recomputing ETA…" truthfully, because a
    /// shift really is coming for it; saying it here would promise a recomputation the engine has
    /// decided never to perform.
    var isAwaitingAnchorBoundary: Bool
    /// GROUND_RULES D4: minutes since this row's window passed — set only for `.overdue` rows
    /// (Figma B8: "Overdue · 5h ago"); nil elsewhere. The derivation populates it; a plain 0 hid
    /// real elapsed time behind "just overdue".
    var overdueMinutesAgo: Int?
    /// See `Kind`'s doc.
    var kind: Kind

    /// Whether this row is work IN FLIGHT right now — the state whose whole message is "the app is
    /// doing something". Drives the timeline's inline spinner.
    ///
    /// `isBroadcasting` was dropped from this 2026-08-01 for the same reason its caption changed
    /// from "Sending now" to "Sent recently": a `.broadcast(txid:)` row is SUBMITTED and awaiting
    /// mining, which is minutes, and a spinner over it claims the app is working when the work is
    /// the chain's. A spinner that never stops is how a wallet teaches someone it is broken.
    ///
    /// Proving is the one row-level state that genuinely runs on this device, for tens of seconds,
    /// and stops the moment the app closes — so it keeps the spinner.
    ///
    /// NARROWED 2026-08-02, from a field screenshot, alongside the caption it sits beside (see
    /// `MigrationStatusView`'s `.isPreparing` case). `isPreparing` alone was wrong here for the same
    /// reason: it means "the engine can prove this one NOW", and provability is gated on each
    /// transfer's own anchor boundary, drawn on a jittered grid — so it fires OUT of send order. A
    /// spinner on a row captioned "~16 mins" claims the app is busy with a transfer that will not
    /// move for a quarter of an hour. True of the proof; meaningless to the user, who reads a
    /// spinner as "this row is happening".
    ///
    /// A spinner belongs to a row whose OWN next step is blocked on work in progress: window open
    /// (`.active`) or past (`.overdue`), waiting on its proof. Those are exactly the rows that
    /// caption "Preparing transaction…", so caption and spinner stay in step by construction.
    ///
    /// `isSubmitting` joins it (2026-08-03) and does NOT reopen the case `isBroadcasting` was dropped
    /// for. That exclusion was about the minutes-long wait for MINING, where the spinner would run
    /// forever over work the app is not doing. This is the seconds-long wait for the SUBMIT CALL,
    /// which is precisely "the app is doing something", ends on its own, and is the one window where
    /// closing the app actually costs the user something.
    var isInFlight: Bool {
        isSubmitting || (isPreparing && (status == .active || status == .overdue))
    }

    /// MOB-1466 (Lukas, 2026-08-07): whether the clock that produced this row's timings knew the
    /// chain tip. `false` ⇒ there is no ETA to state, and every surface says "Recomputing ETA…".
    ///
    /// STORED, not derived, and written in the same expression as the numbers it qualifies (see
    /// `MigrationDerivations.transferRows`) — the value and its trustworthiness come from ONE
    /// `MigrationChainClock` read, so they cannot drift apart. That is what makes this a property of
    /// the measurement rather than a second opinion about someone else's number.
    ///
    /// Defaults to `true` so every existing construction site keeps its meaning — including
    /// `synthesizedTransferRows`, whose `hoursFromNow` is a position-based cadence estimate that
    /// never consults a tip and is therefore unaffected by this bug.
    var isETAKnown = true

    /// The value the forward-ETA caption buckets: the minute-precise `minutesFromNow` when present,
    /// else the coarse `hoursFromNow` promoted to minutes (the synthetic-cadence surfaces).
    ///
    /// `nil` when the tip was unknown at build time. That is NOT "no forward time" — a finished row
    /// never renders an ETA at all — it is "cannot answer yet", which is what the caption prints.
    var forwardETAMinutes: Int? {
        guard isETAKnown else { return nil }
        return minutesFromNow ?? hoursFromNow * 60
    }

    init(
        id: String,
        index: Int,
        amount: Zatoshi?,
        status: Status,
        hoursFromNow: Int,
        minutesFromNow: Int? = nil,
        sentMinutesAgo: Int? = nil,
        isBroadcasting: Bool = false,
        isPreparing: Bool = false,
        isSubmitting: Bool = false,
        isAwaitingRunDependencies: Bool = false,
        isAwaitingAnchorBoundary: Bool = false,
        overdueMinutesAgo: Int? = nil,
        kind: Kind = .transfer,
        isETAKnown: Bool = true
    ) {
        self.id = id
        self.index = index
        self.amount = amount
        self.status = status
        self.hoursFromNow = hoursFromNow
        self.minutesFromNow = minutesFromNow
        self.isETAKnown = isETAKnown
        self.sentMinutesAgo = sentMinutesAgo
        self.isBroadcasting = isBroadcasting
        self.isPreparing = isPreparing
        self.isSubmitting = isSubmitting
        self.isAwaitingRunDependencies = isAwaitingRunDependencies
        self.isAwaitingAnchorBoundary = isAwaitingAnchorBoundary
        self.overdueMinutesAgo = overdueMinutesAgo
        self.kind = kind
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
///
/// MOB-1497: forming moved earlier (the Tor-choice step, not the first broadcast-bearing read) and
/// gained a provisional-until-commit lifecycle — see `committedAt`'s doc and
/// `MigrationManagerClient.formNetworkSnapshot`/`markNetworkSnapshotCommitted`/
/// `clearProvisionalNetworkSnapshot`.
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
    /// MOB-1497: nil while the snapshot is PROVISIONAL — formed at the Tor-choice step but not yet
    /// committed to a schedule. Stamped exactly once, by `markCommitted`/`markNetworkSnapshotCommitted`,
    /// at the same moment `recordCommittedSchedule` persists the committed schedule (co-located there
    /// so the two can never drift). A still-provisional snapshot is discarded at migration flow
    /// teardown (`clearProvisionalNetworkSnapshot`) or left alone by a background reconcile tick that
    /// observes a stale `.notStarted` (only a COMMITTED snapshot is stale-cleared) — a user sitting on
    /// the sheet/plan screen must not have their just-formed pick wiped out from under them. `var`
    /// (unlike every other field here, fixed for the snapshot's whole life): this is the one field
    /// ever mutated in place, and only ever nil -> a date, never back.
    ///
    /// Plain optional `Codable` — no custom decode needed. The feature is unreleased (no old payload
    /// without this field exists in the wild), and Swift's synthesized `Decodable` already treats a
    /// missing key on an `Optional` property as `nil` (`decodeIfPresent` under the hood), so an old
    /// payload would decode as provisional even if one somehow existed.
    var committedAt: Date?

    /// R8-T3 (#22): computed, not stored — every construction site set this to exactly
    /// `ServerProvider.classify(host:)` of `syncEndpoint`'s own host, and both readers
    /// (`AutoServerSelectionLiveKey`'s pinning, `ServerSetupStore`'s manual-switch privacy warning)
    /// already compare it against a freshly-computed `classify(host:)` call — a stored, potentially
    /// stale copy carried no information a live re-derivation didn't already have. Dropping these
    /// two from the stored/`Codable`/memberwise-init surface also drops them from the construction
    /// sites' argument lists (both compile-time enforced). A legacy persisted blob encoded WITH
    /// these as stored keys still decodes fine — `JSONDecoder` silently ignores JSON keys that
    /// aren't in the (now-shorter) synthesized `CodingKeys`.
    var syncProvider: ServerProvider { ServerProvider.classify(host: syncEndpoint.host) }
    /// See `syncProvider`'s doc — same computed treatment, classifying `broadcastEndpoint`'s host.
    var broadcastProvider: ServerProvider { ServerProvider.classify(host: broadcastEndpoint.host) }

    /// Explicit init (rebase of MOB-1497 onto R8-T3's computed providers): the provider arguments
    /// are gone — they derive from the endpoints — and `committedAt` defaults nil so every pre-1497
    /// construction site keeps compiling as a PROVISIONAL snapshot.
    init(
        useTor: Bool,
        syncEndpoint: Endpoint,
        broadcastEndpoint: Endpoint,
        takenAt: Date,
        committedAt: Date? = nil
    ) {
        self.useTor = useTor
        self.syncEndpoint = syncEndpoint
        self.broadcastEndpoint = broadcastEndpoint
        self.takenAt = takenAt
        self.committedAt = committedAt
    }
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
///
/// FOR DISPLAY ONLY — NEVER COMMIT THE EMBEDDED SCHEDULE (SDK addendum §6). `MigrationSchedule
/// .proposalHandle` identifies an entry in a PROCESS-LIFETIME native plan cache, so no persisted
/// copy can ever identify a live plan; the SDK now omits the handle from its encoding entirely and
/// every decoded copy reads `0`. Committing one would hand the SDK a handle to nothing.
///
/// The rule is satisfied by construction today: the three readers of this type
/// (`migrationTransfers`, `bannerTransferRows`, `migrationPreparationRows`) all build ROWS, and
/// every commit path takes its schedule from a live `proposeMigrationTransfers` instead. Keep it
/// that way — the failure would be silent at the call site and only visible as a commit that does
/// nothing.
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
    /// MOB-1466 (Lukas, 2026-08-07): when the user cancelled this run from Advanced Settings →
    /// Restart Migration. `nil` for every other terminal outcome.
    ///
    /// WHY THE APP HAS TO REMEMBER THIS. `zcashlc_migration_restart_step` calls the engine's
    /// `cancel_migration()`, which records the run terminal — and the SDK folds cancelled into the
    /// same `.complete` step as every other terminal run ("`complete` is terminal for the STORED
    /// run — including a CANCELLED one"). Nothing in `advanceStep`/`progress`/`statuses`/
    /// `hasInvalidTransfers` separates "the user asked to start over" from "this run died
    /// unfinished", so the M1 rule read the cancelled run as `.requiresAttention(.invalidTransfer)`
    /// and the banner offered "Update migration plan" instead of "Migration required".
    ///
    /// We performed the cancel, so we are entitled to remember it. This is NOT the app
    /// second-guessing an engine number — every value still comes from the engine; this records an
    /// action of ours the engine has no field for.
    ///
    /// FALSE POSITIVES ARE THE WHOLE RISK ("migration complete must be protected.. we really only
    /// want to show migration required when I used restart migration"). Three things bound it:
    /// exactly ONE writer (the restart's own confirm), it lives INSIDE this payload so
    /// `recordCommittedSchedule` drops it by construction when a new plan is committed, and the
    /// only derivation that reads it is the terminated-UNFINISHED arm — a genuinely complete run
    /// (every transfer mined) never reaches that arm and cannot be affected.
    var cancelledByUserAt: Date?
}
