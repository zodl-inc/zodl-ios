//
//  MigrationScheduleStore.swift
//  zodl
//
//  Persistence for `LiveMigrationEngine`'s app-side state: the committed transfer schedule (so a
//  relaunch mid-migration can rehydrate the transfer rows the status screen renders — progress/
//  totals come live from the SDK either way, but without the committed rows the screen would show
//  "0 of N" with an empty list right after every restart) and the user's chosen `MigrationMode`
//  (which the coordinator must be able to read back across a relaunch, per the mode-routing rule).
//
//  This is the app-side complement to the SDK's own (Rust-backed) migration storage — it never
//  substitutes for it, it just remembers what the app needs to redraw before the next `refresh()`.
//

import Foundation
import os

/// One transfer from a committed `MigrationSchedule` plus its locally tracked broadcast status.
/// `.sent`/`.invalid`/`.expired` are advanced by the engine as SDK calls report outcomes; the SDK's
/// own live reads (`hasOverdueTransfers`, `hasInvalidTransfers`, `migrationProgress`) are the source
/// of truth for anything not tracked here — this is only enough to rehydrate rows after a relaunch.
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

/// The persisted slice of `LiveMigrationEngine`'s cache: the committed schedule's rows and duration,
/// plus the user's chosen mode. Everything else the engine needs is read live from the SDK.
struct MigrationScheduleSnapshot: Equatable, Sendable, Codable {
    static let seededDefault = MigrationScheduleSnapshot(
        mode: .privateScheduled,
        transfers: [],
        scheduleDurationHours: nil
    )

    var mode: MigrationMode
    var transfers: [StoredTransfer]
    /// The committed schedule's estimated duration (hours), persisted alongside `transfers` so the
    /// engine can rehydrate its schedule cache after a relaunch. Optional for backward compatibility
    /// with snapshots written before this field existed.
    var scheduleDurationHours: Int?

    init(mode: MigrationMode, transfers: [StoredTransfer], scheduleDurationHours: Int?) {
        self.mode = mode
        self.transfers = transfers
        self.scheduleDurationHours = scheduleDurationHours
    }
}

/// Load/save the snapshot. Two factories: `live` (JSON file) and `ephemeral` (in-memory, tests).
struct MigrationScheduleStore: Sendable {
    var load: @Sendable () -> MigrationScheduleSnapshot = { MigrationScheduleSnapshot.seededDefault }
    var save: @Sendable (MigrationScheduleSnapshot) -> Void

    /// JSON-file-backed store. File access is serialized by a lock so the foreground app and a
    /// background-task relaunch never corrupt the file.
    static func live(fileURL: URL) -> MigrationScheduleStore {
        let lock = OSAllocatedUnfairLock(initialState: ())

        @Sendable func read() -> MigrationScheduleSnapshot {
            guard
                let data = try? Data(contentsOf: fileURL),
                let snapshot = try? JSONDecoder().decode(MigrationScheduleSnapshot.self, from: data)
            else {
                return MigrationScheduleSnapshot.seededDefault
            }
            return snapshot
        }

        return MigrationScheduleStore(
            load: { lock.withLockUnchecked { _ in read() } },
            save: { snapshot in
                lock.withLockUnchecked { _ in
                    guard let data = try? JSONEncoder().encode(snapshot) else { return }
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        )
    }

    /// In-memory store for tests and previews.
    static func ephemeral() -> MigrationScheduleStore {
        let state = OSAllocatedUnfairLock(initialState: MigrationScheduleSnapshot.seededDefault)
        return MigrationScheduleStore(
            load: { state.withLock { $0 } },
            save: { snapshot in state.withLock { $0 = snapshot } }
        )
    }

    /// Default on-disk location in Application Support.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ironwood_migration_schedule.json")
    }
}
