//
//  MigrationStateStore.swift
//  zodl
//
//  Persistence for the dummy migration engine. The simulated state must survive app restarts and the
//  background-task lifecycle (a background task may run in a freshly relaunched process, and on-launch
//  reconciliation must see the committed schedule), so the engine snapshots itself to a JSON file.
//
//  PROTOTYPE: the real SDK owns its own (Rust-backed) storage; this whole file goes away with the
//  dummy engine.
//

import Foundation
import os
@preconcurrency import ZcashLightClientKit

/// One stored transfer plus its simulated lifecycle status.
struct StoredTransfer: Equatable, Sendable, Codable {
    enum Status: Equatable, Sendable, Codable {
        case pending
        case sent(txId: String)
        case invalid
        case expired
    }

    var proposal: TransferProposal
    var status: Status

    init(proposal: TransferProposal, status: Status) {
        self.proposal = proposal
        self.status = status
    }
}

/// The complete persisted simulation state.
struct MigrationSnapshot: Equatable, Sendable, Codable {
    var orchard: Zatoshi
    var notes: [Zatoshi]
    var currentHeight: BlockHeight
    var minAnchorHeight: BlockHeight?
    var mode: MigrationMode
    var state: MigrationState
    var transfers: [StoredTransfer]
    var networkPrivacy: NetworkPrivacyOptions
    var armedFailure: TransferResult?
    var syncRequired: Bool
    var dustThreshold: Zatoshi
    /// Optional target number of notes/transfers (set by the debug "note count" control). When nil
    /// the engine derives the count from the balance.
    var noteCountOverride: Int?
    // PROTOTYPE debug-only display state.
    var bannerVisible: Bool
    var bannerVariant: Int
    /// PROTOTYPE: set when the user taps Done on the "Migration Complete" (C6) screen, so the Home
    /// SmartBanner stops showing the completion state. Persisted; cleared by debug Reset (reseed).
    var completionAcknowledged: Bool

    /// Seeded default ≈ 12.458 ZEC in a single Orchard note (matches the Figma), so a split is needed.
    static var seededDefault: MigrationSnapshot {
        MigrationSnapshot(
            orchard: Zatoshi(1_245_800_000),
            notes: [Zatoshi(1_245_800_000)],
            currentHeight: 2_500_000,
            minAnchorHeight: nil,
            mode: .privateScheduled,
            state: .notStarted,
            transfers: [],
            networkPrivacy: NetworkPrivacyOptions(useTor: false),
            armedFailure: nil,
            syncRequired: false,
            dustThreshold: Zatoshi(10_000),
            noteCountOverride: nil,
            bannerVisible: true,
            bannerVariant: 0,
            completionAcknowledged: false
        )
    }

    init(
        orchard: Zatoshi,
        notes: [Zatoshi],
        currentHeight: BlockHeight,
        minAnchorHeight: BlockHeight?,
        mode: MigrationMode,
        state: MigrationState,
        transfers: [StoredTransfer],
        networkPrivacy: NetworkPrivacyOptions,
        armedFailure: TransferResult?,
        syncRequired: Bool,
        dustThreshold: Zatoshi,
        noteCountOverride: Int?,
        bannerVisible: Bool,
        bannerVariant: Int,
        completionAcknowledged: Bool = false
    ) {
        self.orchard = orchard
        self.notes = notes
        self.currentHeight = currentHeight
        self.minAnchorHeight = minAnchorHeight
        self.mode = mode
        self.state = state
        self.transfers = transfers
        self.networkPrivacy = networkPrivacy
        self.armedFailure = armedFailure
        self.syncRequired = syncRequired
        self.dustThreshold = dustThreshold
        self.noteCountOverride = noteCountOverride
        self.bannerVisible = bannerVisible
        self.bannerVariant = bannerVariant
        self.completionAcknowledged = completionAcknowledged
    }
}

/// Load/save/clear the snapshot. Two factories: `live` (JSON file) and `ephemeral` (in-memory, tests).
struct MigrationStateStore: Sendable {
    var load: @Sendable () -> MigrationSnapshot = { MigrationSnapshot.seededDefault }
    var save: @Sendable (MigrationSnapshot) -> Void
    var clear: @Sendable () -> Void

    /// JSON-file-backed store. File access is serialized by a lock so the foreground app and a
    /// background-task relaunch never corrupt the file.
    static func live(fileURL: URL) -> MigrationStateStore {
        let lock = OSAllocatedUnfairLock(initialState: ())

        @Sendable func read() -> MigrationSnapshot {
            guard
                let data = try? Data(contentsOf: fileURL),
                let snapshot = try? JSONDecoder().decode(MigrationSnapshot.self, from: data)
            else {
                return MigrationSnapshot.seededDefault
            }
            return snapshot
        }

        return MigrationStateStore(
            load: { lock.withLockUnchecked { _ in read() } },
            save: { snapshot in
                lock.withLockUnchecked { _ in
                    guard let data = try? JSONEncoder().encode(snapshot) else { return }
                    try? data.write(to: fileURL, options: .atomic)
                }
            },
            clear: { lock.withLockUnchecked { _ in try? FileManager.default.removeItem(at: fileURL) } }
        )
    }

    /// In-memory store for tests and previews.
    static func ephemeral() -> MigrationStateStore {
        let state = OSAllocatedUnfairLock(initialState: MigrationSnapshot.seededDefault)
        return MigrationStateStore(
            load: { state.withLock { $0 } },
            save: { snapshot in state.withLock { $0 = snapshot } },
            clear: { state.withLock { $0 = MigrationSnapshot.seededDefault } }
        )
    }

    /// Default on-disk location in Application Support.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ironwood_migration_state.json")
    }
}

// MARK: - Background-task run log (PROTOTYPE debug observability)

/// One recorded execution of `MigrationBackgroundWorker.runMigrationStep` — when it ran and what the
/// transfer-send attempt returned. Persisted independently of the migration snapshot so it survives the
/// debug Reset / Seed (which reset the simulation) and the background-task relaunch lifecycle.
struct MigrationBackgroundRun: Equatable, Sendable, Codable, Identifiable {
    enum Outcome: Equatable, Sendable, Codable {
        case sent(txId: String)
        case networkError
        case invalidNote
        case expired
        case nothingPending
        case syncRequired
    }

    enum Severity: Equatable, Sendable {
        case success
        case failure
        case neutral
    }

    var id: UUID
    var timestamp: Date
    var outcome: Outcome

    init(id: UUID = UUID(), timestamp: Date, outcome: Outcome) {
        self.id = id
        self.timestamp = timestamp
        self.outcome = outcome
    }

    /// One-line description for the debug list.
    var summary: String {
        switch outcome {
        case let .sent(txId): return "Sent ✓  \(txId)"
        case .networkError: return "Network error ✗"
        case .invalidNote: return "Invalid note ✗"
        case .expired: return "Expired ✗"
        case .nothingPending: return "Nothing pending"
        case .syncRequired: return "Sync required (skipped)"
        }
    }

    var severity: Severity {
        switch outcome {
        case .sent: return .success
        case .networkError, .invalidNote, .expired: return .failure
        case .nothingPending, .syncRequired: return .neutral
        }
    }
}

/// Append/load/clear the background-task run log. Mirrors `MigrationStateStore`: `live` (JSON file,
/// newest-first, capped) and `ephemeral` (in-memory, tests). Kept separate from the migration snapshot
/// so Reset/Seed don't wipe the record of when background tasks actually fired.
struct MigrationRunLogStore: Sendable {
    /// Keep only the most recent N runs.
    static let capacity = 50

    var load: @Sendable () -> [MigrationBackgroundRun] = { [] }
    var append: @Sendable (MigrationBackgroundRun) -> Void
    var clear: @Sendable () -> Void

    static func live(fileURL: URL) -> MigrationRunLogStore {
        let lock = OSAllocatedUnfairLock(initialState: ())

        @Sendable func read() -> [MigrationBackgroundRun] {
            guard
                let data = try? Data(contentsOf: fileURL),
                let log = try? JSONDecoder().decode([MigrationBackgroundRun].self, from: data)
            else {
                return []
            }
            return log
        }

        return MigrationRunLogStore(
            load: { lock.withLockUnchecked { _ in read() } },
            append: { entry in
                lock.withLockUnchecked { _ in
                    var log = read()
                    log.insert(entry, at: 0)
                    if log.count > MigrationRunLogStore.capacity {
                        log = Array(log.prefix(MigrationRunLogStore.capacity))
                    }
                    guard let data = try? JSONEncoder().encode(log) else { return }
                    try? data.write(to: fileURL, options: .atomic)
                }
            },
            clear: { lock.withLockUnchecked { _ in try? FileManager.default.removeItem(at: fileURL) } }
        )
    }

    static func ephemeral() -> MigrationRunLogStore {
        let state = OSAllocatedUnfairLock(initialState: [MigrationBackgroundRun]())
        return MigrationRunLogStore(
            load: { state.withLock { $0 } },
            append: { entry in
                state.withLock { log in
                    log.insert(entry, at: 0)
                    if log.count > MigrationRunLogStore.capacity {
                        log = Array(log.prefix(MigrationRunLogStore.capacity))
                    }
                }
            },
            clear: { state.withLock { $0 = [] } }
        )
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ironwood_migration_runlog.json")
    }
}
