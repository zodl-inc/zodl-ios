//
//  MigrationSimulatorLiveKey.swift
//  zodl
//
//  Live implementation of `MigrationSimulatorClient`. `sharedEngine` is the single engine
//  instance (backed by the on-disk live store) that Phase B's `SDKSynchronizerLive` migration
//  member block and `MigrationManagerLiveKey`'s balance hook also read from directly, so the
//  debug panel and the simulated SDK surface always observe the same state.
//

import Foundation
import ComposableArchitecture

extension MigrationSimulatorClient: DependencyKey {
    /// Backs every simulated migration hook across the app (panel + `SDKSynchronizerLive` +
    /// `MigrationManagerLiveKey`) — a single shared instance, backed by the on-disk live store.
    static let sharedEngine = MigrationSimulatorEngine(store: MigrationSimulatorStateStore.live())

    static let liveValue: MigrationSimulatorClient = Self.live(engine: Self.sharedEngine)

    static func live(engine: MigrationSimulatorEngine) -> Self {
        Self(
            readout: { engine.readout() },
            setActive: { engine.setActive($0) },
            reset: { engine.reset() },
            seed: { orchard, noteCount in engine.seed(orchard: orchard, noteCount: noteCount) },
            applyPreset: { engine.applyPreset($0) },
            advanceTime: { engine.advanceTime(by: $0) },
            makeNextTransferDueNow: { engine.makeNextTransferDueNow() },
            confirmSplitNow: { engine.confirmSplitNow() },
            armTransferResult: { engine.armTransferResult($0) },
            armSplitFailure: { engine.armSplitFailure() },
            setSyncRequired: { engine.setSyncRequired($0) }
        )
    }

    /// A fresh client over a fresh in-memory engine — for tests/previews that need panel-level
    /// behavior without touching `sharedEngine`'s on-disk state.
    static func ephemeral() -> Self {
        Self.live(engine: MigrationSimulatorEngine(store: MigrationSimulatorStateStore.ephemeral()))
    }
}
