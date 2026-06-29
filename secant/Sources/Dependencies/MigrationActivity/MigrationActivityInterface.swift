//
//  MigrationActivityInterface.swift
//  zodl
//
//  Tracks "last app activity" for the Ironwood migration background task. A scheduled background run
//  must not broadcast a transfer within one hour of the user last using the app, so the app lifecycle
//  records activity via `recordActivity()` and `MigrationBackgroundWorker` reads `lastActivity()`.
//
//  PROTOTYPE: persisted next to the dummy migration. The real (Rust-backed) SDK would own this signal.
//

import ComposableArchitecture
import Foundation

extension DependencyValues {
    var migrationActivity: MigrationActivityClient {
        get { self[MigrationActivityClient.self] }
        set { self[MigrationActivityClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationActivityClient: Sendable {
    /// Stamp "the app was just used" with the current time. Persisted so it survives the
    /// background-task relaunch (a background run may execute in a freshly relaunched process).
    var recordActivity: @Sendable () -> Void
    /// The last recorded activity time, or nil if it was never recorded.
    var lastActivity: @Sendable () -> Date?
}
