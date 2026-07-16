//
//  MigrationSimulatorInterface.swift
//  zodl
//
//  Panel-facing dependency surface over the shared `MigrationSimulatorEngine` (MOB-1480). Phase B's
//  debug panel drives the engine exclusively through this client; the simulated
//  `SDKSynchronizerClient`/`MigrationManagerClient` hooks (also Phase B) talk to
//  `MigrationSimulatorClient.sharedEngine` directly instead, since their surface is the much larger
//  SDK-shaped member list already pinned on the engine itself.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var migrationSimulator: MigrationSimulatorClient {
        get { self[MigrationSimulatorClient.self] }
        set { self[MigrationSimulatorClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationSimulatorClient: Sendable {
    var readout: @Sendable () -> SimulatorReadout = {
        SimulatorReadout(
            isActive: false,
            state: MigrationState.notStarted,
            mode: MigrationMode.privateScheduled,
            orchardBalance: Zatoshi.zero,
            timeOffset: 0,
            rows: [],
            signedBatchCount: 0,
            armedResultDescription: nil,
            isSplitPending: false,
            lastBackgroundRunSummary: nil,
            dustRemainder: Zatoshi.zero,
            isDustLocked: false
        )
    }
    var setActive: @Sendable (Bool) -> Void
    var reset: @Sendable () -> Void
    var seed: @Sendable (Zatoshi, Int) -> Void
    var applyPreset: @Sendable (SimulatorPreset) -> Void
    var advanceTime: @Sendable (TimeInterval) -> Void
    var makeNextTransferDueNow: @Sendable () -> Void
    var confirmSplitNow: @Sendable () -> Void
    var armTransferResult: @Sendable (TransferResult) -> Void
    var armSplitFailure: @Sendable () -> Void
    var setSyncRequired: @Sendable (Bool) -> Void
}
