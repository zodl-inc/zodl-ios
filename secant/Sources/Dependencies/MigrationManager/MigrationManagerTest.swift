//
//  MigrationManagerTest.swift
//  zodl
//
//  A22 — `MigrationManagerClient`'s test implementation.
//
//  THE PROBLEM THIS FIXES is not "some tests are red". Until now this client had NO `testValue` at
//  all, and swift-dependencies' behaviour in that case is a trap in two directions:
//
//  1. A test that merely RESOLVES `@Dependency(\.migrationManager)` — without calling anything —
//     fails. Migration wiring reached `AutoServerSelection`, `ServerSetup`, `Flexa`, `WalletConfig`
//     and `Root`, so suites with nothing to do with migration started failing on a dependency they
//     never meant to exercise. That is noise, and noise is what stops people running tests.
//
//  2. Far worse: a test that overrode ANY ONE member unlocked the whole client, and every member it
//     did NOT override then fell through to the LIVE implementation. Partial mocking silently ran
//     production code inside tests — real reads against a real synchronizer — which is how
//     `RootIronwoodAnnouncementGateTests` came to record 66 `SDKSynchronizerClient.latestState`
//     failures for a suite that is about an announcement banner.
//
//  Both disappear once a `testValue` exists, because un-overridden members now resolve to THIS
//  value rather than to `liveValue`.
//
//  WHERE THE LINE IS DRAWN. Reads answer as an account with no migration: no banner, `.entry`
//  route, not activated, zero balance, a `.sync` visit. Those are truthful defaults for a test
//  wallet that never set a migration up, and letting them answer quietly is what keeps unrelated
//  suites unrelated.
//
//  Everything that MOVES MONEY OR MUTATES PERSISTED STATE stays loud, naming itself when called. A
//  test may silently observe that there is no migration; a test may never silently broadcast one,
//  commit a schedule, or clear a user's flags. Same shape and same reason as
//  `SDKSynchronizerClient.testValue`.
//
//  Built by mutating a default-constructed client rather than by a full memberwise call:
//  `@DependencyClient` synthesizes an all-or-nothing initializer (a partial call reports the
//  baffling "argument passed to call that takes no arguments"), and spelling out all 53 members to
//  change nine of them would bury the distinction this file exists to draw.
//

@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension MigrationManagerClient: TestDependencyKey {
    /// Quiet reads, loud side effects — see this file's header for why the line is there.
    static let testValue: MigrationManagerClient = {
        var client = MigrationManagerClient()

        // Persisted records of what a migration DID. A test reaching one of these unstubbed is
        // writing a schedule or a broadcast record it never meant to write.
        client.recordCommittedSchedule = unimplemented("MigrationManagerClient.recordCommittedSchedule", placeholder: {}())
        client.markRunCancelledByUser = unimplemented("MigrationManagerClient.markRunCancelledByUser", placeholder: {}())
        client.recordTransferBroadcast = unimplemented("MigrationManagerClient.recordTransferBroadcast", placeholder: {}())

        // Spends and submissions. `runBroadcastSession` is the headless broadcast driver: reaching
        // it unstubbed is an attempted real submission, and there is no defensible quiet answer.
        client.lockMigrationDust = unimplemented("MigrationManagerClient.lockMigrationDust")
        client.runBroadcastSession = unimplemented("MigrationManagerClient.runBroadcastSession", placeholder: false)

        // User choices. Silently rewriting the mode or the acknowledged flag would make a later
        // assertion about either meaningless.
        client.setMigrationMode = unimplemented("MigrationManagerClient.setMigrationMode", placeholder: {}())
        client.acknowledgeComplete = unimplemented("MigrationManagerClient.acknowledgeComplete", placeholder: {}())

        // The run's pinned network identity, and the reset that wipes every persisted flag.
        client.markNetworkSnapshotCommitted = unimplemented("MigrationManagerClient.markNetworkSnapshotCommitted", placeholder: {}())
        client.wipeAllMigrationState = unimplemented("MigrationManagerClient.wipeAllMigrationState", placeholder: {}())
        client.resetPersistedFlags = unimplemented("MigrationManagerClient.resetPersistedFlags", placeholder: {}())

        return client
    }()

    /// Fully inert: every member answers its declared default, side effects included.
    ///
    /// For suites that construct a reducer graph incidentally and want no migration behaviour at
    /// all — the role `SDKSynchronizerClient.noOp` plays. Deliberately NOT the default: opting out
    /// of the loud members should be a visible choice at the call site.
    static let noOp = MigrationManagerClient()
}
