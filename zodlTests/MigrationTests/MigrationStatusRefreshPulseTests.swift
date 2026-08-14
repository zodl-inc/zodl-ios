//
//  MigrationStatusRefreshPulseTests.swift
//  zodlTests
//
//  MOB-1466 — the status screen's 30s REFRESH PULSE. Field-caught 2026-08-02: with the foreground
//  tick loop running, the Migration Progress screen sat frozen while OPEN and only showed fresh
//  rows after closing and reopening. The event-driven refresh chain is real but narrower than the
//  screen's truth: ETA captions age with the wall clock, and no DB write announces the passage of
//  time — so something must ask on a cadence while the screen is up.
//
//  R13 Brick 2 changed WHAT the pulse does, not whether it exists: it no longer runs a private
//  `loadStatus` query — it asks THE pipeline to re-derive (`refreshMigrationSnapshot`), and the
//  fresh value arrives on the screen's one snapshot subscription like every other update. The
//  channel's value-equality dedupe keeps quiet ticks off the screen. These tests pin the CADENCE
//  and LIFECYCLE (fires every 30s while up, stops on disappear, never before appear, survives the
//  tick loop's off switch); the spy counts `refreshMigrationSnapshot` — the pulse's only remaining
//  effect, also called exactly once by `onAppear`'s own R3 re-verify kick, which is the `== 1`
//  baseline every test starts from.
//

import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationStatusRefreshPulseTests {
    private static func store(
        refreshCount: LockIsolated<Int>,
        testClock: TestClock<Swift.Duration>
    ) -> TestStoreOf<MigrationStatus> {
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.continuousClock = testClock

            var client = MigrationManagerClient.noOp
            client.refreshMigrationSnapshot = { _ in
                refreshCount.withValue { $0 += 1 }
            }
            client.currentMigrationSnapshot = { _ in nil }
            client.migrationSnapshotEvents = { _ in Empty().eraseToAnyPublisher() }
            $0.migrationManager = client

            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off
        return store
    }

    /// Bounded real-time polling for a condition driven by the store's own in-flight effects —
    /// advancing a `TestClock` resumes suspended sleepers but does not itself guarantee the
    /// resulting action has propagated by the time `advance(by:)` returns. Same helper shape as
    /// `RootMigrationTickLoopTests`.
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// THE requirement (Michal, 2026-08-02): an OPEN progress screen re-derives on the pulse —
    /// never only on events, and never only on reopen. First pulse a full 30s after `onAppear`
    /// (whose own re-verify kick just ran; an immediate pulse would only race it), then every 30s
    /// for as long as the screen stays up.
    @Test func anOpenScreenReDerivesEveryThirtySeconds() async {
        let refreshCount = LockIsolated(0)
        let testClock = TestClock()
        let store = Self.store(refreshCount: refreshCount, testClock: testClock)

        await store.send(.onAppear)
        await waitUntil { refreshCount.value == 1 }
        #expect(refreshCount.value == 1, "onAppear's own re-verify kick, exactly once")

        await testClock.advance(by: .seconds(29))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(refreshCount.value == 1, "no pulse before a full 30s has elapsed")

        await testClock.advance(by: .seconds(1))
        await waitUntil { refreshCount.value == 2 }
        #expect(refreshCount.value == 2, "the first pulse fires at 30s")

        await testClock.advance(by: .seconds(30))
        await waitUntil { refreshCount.value == 3 }
        #expect(refreshCount.value == 3, "and keeps firing every 30s while the screen is open")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// The other end of the lifecycle (field-caught 2026-08-03): after the screen pops, the pulse
    /// must STOP. Until `.onDisappear` existed, the timer kept firing into a path whose element
    /// was gone — hundreds of TCA missing-element warnings per session, and a busy-loop of loads
    /// for a screen nobody could see.
    @Test func onDisappearStopsThePulse() async {
        let refreshCount = LockIsolated(0)
        let testClock = TestClock()
        let store = Self.store(refreshCount: refreshCount, testClock: testClock)

        await store.send(.onAppear)
        await waitUntil { refreshCount.value == 1 }

        await testClock.advance(by: .seconds(30))
        await waitUntil { refreshCount.value == 2 }
        #expect(refreshCount.value == 2, "the pulse runs while the screen is up")

        await store.send(.onDisappear)

        await testClock.advance(by: .seconds(120))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(refreshCount.value == 2, "no pulse may fire after the screen has gone")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// The pulse belongs to the screen's lifecycle: before `onAppear`, no clock movement may ask
    /// for anything.
    @Test func noPulseBeforeTheScreenAppears() async {
        let refreshCount = LockIsolated(0)
        let testClock = TestClock()
        let store = Self.store(refreshCount: refreshCount, testClock: testClock)

        await testClock.advance(by: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(refreshCount.value == 0, "no screen, no pulse")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Design pin, green by construction (Michal's scope decision, 2026-08-02): the tick loop's
    /// OFF switch (`migrationTickInterval == .zero`) must NOT silence this screen's pulse — ETA
    /// captions age with the wall clock whether or not the automatic loop exists. If someone later
    /// wires the pulse to the switch, this is the test that names the decision they are reversing.
    @Test func thePulseStillFiresWithTheTickLoopSwitchedOff() async {
        let refreshCount = LockIsolated(0)
        let testClock = TestClock()
        let store = TestStore(initialState: MigrationStatus.State(presentation: .resume)) {
            MigrationStatus()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.continuousClock = testClock
            $0.migrationTickInterval = Swift.Duration.zero

            var client = MigrationManagerClient.noOp
            client.refreshMigrationSnapshot = { _ in
                refreshCount.withValue { $0 += 1 }
            }
            client.currentMigrationSnapshot = { _ in nil }
            client.migrationSnapshotEvents = { _ in Empty().eraseToAnyPublisher() }
            $0.migrationManager = client

            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await waitUntil { refreshCount.value == 1 }

        await testClock.advance(by: .seconds(30))
        await waitUntil { refreshCount.value == 2 }
        #expect(refreshCount.value == 2, "the pulse is not the tick loop and must survive its off switch")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }
}
