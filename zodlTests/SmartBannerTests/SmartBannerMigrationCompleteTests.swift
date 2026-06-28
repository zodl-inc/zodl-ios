//
//  SmartBannerMigrationCompleteTests.swift
//  zodlTests
//
//  PROTOTYPE: when the migration reaches `.complete`, the SmartBanner must SWITCH to a "Migration
//  complete" state (and capture the residual dust for its subtitle) — not hide itself. That banner is
//  the only way to reach the C6 summary from Home after a background completion.
//

import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SmartBannerMigrationCompleteTests {
    private func makeStore(
        orchardBalance: Zatoshi,
        dust: Zatoshi,
        priorityContent: SmartBanner.State.PriorityContent? = nil
    ) -> TestStore<SmartBanner.State, SmartBanner.Action> {
        var initialState = SmartBanner.State()
        initialState.priorityContent = priorityContent

        // Inject deps via the initializer closure (applied atomically before any send). Post-init
        // `store.dependencies` mutation does not reach the reducer here. MigrationSDKClient registers
        // only a liveValue (no testValue), so install a full ephemeral base, then override the two
        // closures the `.migrationStateUpdated` reducer reads.
        let store = TestStore(initialState: initialState) {
            SmartBanner()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationSDK = .live(store: .ephemeral())
            $0.migrationSDK.simulatedOrchardBalance = { orchardBalance }
            $0.migrationSDK.migrationSummary = {
                MigrationSummary(
                    transferred: Zatoshi(1_245_800_000),
                    dust: dust,
                    transfersSent: 5,
                    transfersTotal: 5,
                    estimatedDurationHours: 24
                )
            }
        }
        store.exhaustivity = .off
        return store
    }

    /// Clean completion drains Orchard to zero, yet the banner must still SHOW — this is the path the
    /// user takes to reach C6 from Home. (Previously `.complete` was suppressed and the banner vanished.)
    @Test func completeWithNoBalanceStillOpensBanner() async {
        let store = makeStore(orchardBalance: .zero, dust: .zero)

        await store.send(.migrationStateUpdated(.complete)) {
            $0.migrationState = .complete
            $0.migrationDust = .zero
        }
        await store.receive(\.triggerPriority)

        #expect(store.state.priorityContentRequested == .priorityMigration)
    }

    /// Dust completion captures the residual so the banner subtitle can read "Dust balance stays…".
    @Test func completeWithDustCapturesDust() async {
        let store = makeStore(orchardBalance: Zatoshi(31_000), dust: Zatoshi(31_000))

        await store.send(.migrationStateUpdated(.complete)) {
            $0.migrationState = .complete
            $0.migrationDust = Zatoshi(31_000)
        }
        await store.receive(\.triggerPriority)

        #expect(store.state.migrationDust.amount == 31_000)
    }

    /// Regression guard: nothing to migrate (not complete, no Orchard balance) still HIDES the banner.
    @Test func notCompleteWithNoBalanceClosesBanner() async {
        let store = makeStore(orchardBalance: .zero, dust: .zero, priorityContent: .priorityMigration)

        await store.send(.migrationStateUpdated(.notStarted)) {
            $0.migrationState = .notStarted
        }
        await store.receive(\.closeAndCleanupBanner)
    }
}
