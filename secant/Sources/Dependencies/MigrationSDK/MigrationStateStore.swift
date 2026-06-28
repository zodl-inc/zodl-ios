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
            bannerVariant: 0
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
        bannerVariant: Int
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
