//
//  SplashManagerTests.swift
//  zodlTests
//
//  MOB-1909 — `SplashModifier` builds a `SplashManager` on every body evaluation and `@StateObject`
//  keeps only the first. Anything the initializer does therefore runs once per re-render of the
//  root view while the splash is up: it used to request Face ID and start a 60 Hz timer per orphan,
//  and `finished()` never invalidated the timer whose block retained the manager. These tests pin
//  the repaired contract: `init` is inert, `start()` does the work exactly once, a failed
//  authentication shows the retry state without spinning, and `finished()` invalidates and
//  completes once.
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SplashManagerTests {
    @MainActor private struct Harness {
        let authenticationCalls = LockIsolated(0)
        let completions = LockIsolated(0)

        func manager(isHidden: Bool = false) -> SplashManager {
            SplashManager(isHidden) { completions.withValue { $0 += 1 } }
        }

        /// Runs `body` with `localAuthentication.authenticate` answering `succeeds`, counting calls.
        func withAuthentication<R>(succeeding succeeds: Bool, _ body: () throws -> R) rethrows -> R {
            try withDependencies(
                {
                    $0.localAuthentication.authenticate = {
                        authenticationCalls.withValue { $0 += 1 }
                        return succeeds
                    }
                },
                operation: body
            )
        }
    }

    private func setBiometricFlag(_ isOn: Bool) {
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        $featureFlags.withLock { $0 = FeatureFlags(appLaunchBiometric: isOn) }
    }

    @Test func initHasNoSideEffects() {
        let harness = Harness()
        setBiometricFlag(true)

        let manager = harness.withAuthentication(succeeding: true) { harness.manager() }

        #expect(harness.authenticationCalls.value == 0)
        #expect(manager.timer == nil)
        #expect(manager.points.isEmpty)
    }

    @Test func startRequestsAuthenticationOnceAndThenSpins() async {
        let harness = Harness()
        setBiometricFlag(true)
        let manager = harness.manager()

        harness.withAuthentication(succeeding: true) {
            manager.start()
            manager.start()
        }
        await manager.task?.value

        #expect(harness.authenticationCalls.value == 1)
        #expect(!manager.points.isEmpty)
        #expect(manager.timer != nil)
        manager.finished()
    }

    @Test func startSpinsWithoutAuthenticationWhenTheFlagIsOff() {
        let harness = Harness()
        setBiometricFlag(false)
        let manager = harness.manager()

        harness.withAuthentication(succeeding: true) { manager.start() }

        #expect(harness.authenticationCalls.value == 0)
        #expect(manager.timer != nil)
        manager.finished()
    }

    @Test func aFailedAuthenticationShowsTheRetryStateWithoutSpinning() async {
        let harness = Harness()
        setBiometricFlag(true)
        let manager = harness.manager()

        harness.withAuthentication(succeeding: false) { manager.start() }
        await manager.task?.value

        #expect(manager.authenticationDidntSucceed)
        #expect(manager.timer == nil)
        #expect(harness.completions.value == 0)
    }

    @Test func finishedInvalidatesTheTimerAndCompletesOnce() {
        let harness = Harness()
        setBiometricFlag(false)
        let manager = harness.manager()
        harness.withAuthentication(succeeding: true) { manager.start() }
        let timer = manager.timer

        manager.finished()
        manager.finished()

        #expect(timer?.isValid == false)
        #expect(manager.timer == nil)
        #expect(!manager.isOn)
        #expect(harness.completions.value == 1)
    }

    @Test func aHiddenManagerNeverStarts() {
        let harness = Harness()
        setBiometricFlag(true)
        let manager = harness.manager(isHidden: true)

        harness.withAuthentication(succeeding: true) { manager.start() }

        #expect(harness.authenticationCalls.value == 0)
        #expect(manager.timer == nil)
        #expect(manager.points.isEmpty)
    }
}
