//
//  MigrationSimulatorStateStore.swift
//  zodl
//
//  Persistence for `MigrationSimulatorEngine` (MOB-1480). The simulated state must survive app
//  restarts and the background-task lifecycle, so the live store snapshots itself to a JSON file
//  under Application Support. Envelope-versioned: any decode failure OR a `schemaVersion`
//  mismatch reseeds (and persists the reseed) rather than attempting a migration.
//

import Foundation
import os

/// Load/save/clear the snapshot. Two factories: `.live` (JSON file, for the shared engine) and
/// `.ephemeral` (in-memory, for tests/previews).
struct MigrationSimulatorStateStore: Sendable {
    var load: @Sendable () -> SimulatorSnapshot
    var save: @Sendable (SimulatorSnapshot) -> Void
    var clear: @Sendable () -> Void

    /// Default on-disk location in Application Support.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("migration_simulator_state.json")
    }

    /// JSON-file-backed store. File access is serialized by a lock so the foreground app and a
    /// background-task relaunch never corrupt the file.
    static func live(fileURL: URL = MigrationSimulatorStateStore.defaultFileURL) -> MigrationSimulatorStateStore {
        let lock = OSAllocatedUnfairLock(initialState: ())

        @Sendable func reseed() -> SimulatorSnapshot {
            let fresh = SimulatorSnapshot.seeded()
            if let data = try? JSONEncoder().encode(fresh) {
                try? data.write(to: fileURL, options: .atomic)
            }
            return fresh
        }

        @Sendable func read() -> SimulatorSnapshot {
            guard
                let data = try? Data(contentsOf: fileURL),
                let snapshot = try? JSONDecoder().decode(SimulatorSnapshot.self, from: data),
                snapshot.schemaVersion == SimulatorSnapshot.currentSchemaVersion
            else {
                return reseed()
            }
            return snapshot
        }

        return MigrationSimulatorStateStore(
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
    static func ephemeral() -> MigrationSimulatorStateStore {
        let state = OSAllocatedUnfairLock(initialState: SimulatorSnapshot.seeded())
        return MigrationSimulatorStateStore(
            load: { state.withLock { $0 } },
            save: { snapshot in state.withLock { $0 = snapshot } },
            clear: { state.withLock { $0 = SimulatorSnapshot.seeded() } }
        )
    }
}
