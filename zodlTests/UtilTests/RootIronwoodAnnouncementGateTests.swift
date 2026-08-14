//
//  RootIronwoodAnnouncementGateTests.swift
//  zodlTests
//
//  Covers the Root-reducer wiring for the one-time Ironwood announcement screen: the
//  presentation predicate (`Root.presentIronwoodAnnouncementIfNeeded`), its two call sites
//  (`.synchronizerStateChanged` and `.initialization(.appDelegate(.willEnterForeground))`), the
//  `.ironwoodAnnouncement(.continueTapped)` navigation back to Home, and the debug reset arm
//  (Features/Root/RootStore.swift, RootInitialization.swift, RootCoordinator.swift).
//
//  `extension Root.State: @retroactive Equatable` already exists, module-wide, at
//  RootInitializeSDKHealTests.swift. Declaring a second one anywhere in this target is a
//  duplicate-conformance compile error, so this file does NOT use `TestStore` for `Root`.
//  Instead it drives a plain `Store` and reads state directly after sending actions — the same
//  approach used by AddKeystoneHWWalletTests/AddKeystoneHWWalletCoordFlowTests.swift (see its
//  header comment) and ScanTests/ScanCoordFlowZip321Tests.swift, and already applied to a plain
//  `Root` store specifically by FlexaTests/FlexaSecurityTests.swift.
//

@preconcurrency import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: drives a plain `Root` store touching process-global `@Shared(.inMemory(...))`
// state (`selectedWalletAccount`, `featureFlags`, ...). Each test additionally scopes a fresh
// `InMemoryStorage()` via `withDependencies` so parallel suites can't clobber that shared state
// either — the same belt-and-suspenders approach used by FlexaSecurityTests/ScanCoordFlowZip321Tests.
@Suite(.serialized) @MainActor struct RootIronwoodAnnouncementGateTests {
    // MARK: - Fixtures

    /// A `Root.State` sitting on `.home` with every safety-gate term satisfied, so
    /// `canPresentIronwoodAnnouncement` reads `true` unless a test deliberately flips one term.
    private func makeState() -> Root.State {
        var state = Root.State.initial
        state.destinationState.destination = .home
        state.splashAppeared = true
        return state
    }

    private func fixtureSyncState(tip: BlockHeight) -> RedactableSynchronizerState {
        var syncState = SynchronizerState.zero
        syncState.syncStatus = .upToDate
        syncState.latestBlockHeight = tip
        return syncState.redacted
    }

    /// Builds a `Root` store wired for driving the announcement gate through
    /// `.synchronizerStateChanged` / `.ironwoodAnnouncement` / the debug reset action. Only the
    /// two dependencies the gate itself reads (`zcashSDKEnvironment.ironwoodActivationHeight`,
    /// `walletStorage.exportIronwoodAnnouncementFlag`) are stubbed to fixture values; a
    /// `.synchronizerStateChanged` tick with no selected account (the default, `Root.State`'s
    /// `@Shared` `selectedWalletAccount`) short-circuits everything else in that case body as a
    /// pure, side-effect-free early return, so nothing further needs stubbing.
    private func makeGateStore(
        state: Root.State? = nil,
        activationHeight: BlockHeight,
        announcementFlag: Bool?,
        exportCallCount: LockIsolated<Int>? = nil
    ) -> StoreOf<Root> {
        Store(initialState: state ?? makeState()) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { activationHeight }
            $0.walletStorage = .noOp
            $0.walletStorage.exportIronwoodAnnouncementFlag = {
                exportCallCount?.withValue { $0 += 1 }
                return announcementFlag
            }
        }
    }

    // MARK: - Case 1: tip boundary, flag absent, gate open

    @Test func tipBoundaryWithFlagAbsentPresentsAtAndAboveActivation() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            // `@MainActor` is required: `withDependencies`' `operation:` closure is nonisolated,
            // so a local function declared inside it does not inherit the suite's isolation and
            // could not otherwise call the main-actor-isolated fixtures below.
            @MainActor func presented(forTip tip: BlockHeight) -> Bool {
                let store = makeGateStore(activationHeight: activation, announcementFlag: nil)
                store.send(.synchronizerStateChanged(fixtureSyncState(tip: tip)))
                return store.state.destinationState.destination == .ironwoodAnnouncement
            }

            #expect(!presented(forTip: 0), "tip 0 is the in-memory-only sentinel and must never present")
            #expect(!presented(forTip: activation - 1), "below activation must not present")
            #expect(presented(forTip: activation), "exactly at activation must present")
            #expect(presented(forTip: activation + 1), "above activation must present")
        }
    }

    // MARK: - Case 2: flag `true` is a latch; keychain read at most once per session

    @Test func acknowledgedFlagNeverPresentsAndReadsKeychainAtMostOnce() async throws {
        let activation: BlockHeight = 1_000_000
        let exportCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeGateStore(activationHeight: activation, announcementFlag: true, exportCallCount: exportCalls)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))
            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation + 1)))
            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation + 2)))
            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)

            #expect(exportCalls.value == 1, "the keychain must be read at most once per session once acknowledged")
        }
    }

    // MARK: - Case 3: flag `false` is NOT acknowledged

    @Test func unacknowledgedFalseFlagPresents() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeGateStore(activationHeight: activation, announcementFlag: false)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination == .ironwoodAnnouncement, "only `true` counts as acknowledged")
        }
    }

    // MARK: - Case 4: presents exactly once across repeated above-activation ticks

    @Test func twoConsecutiveAboveActivationTicksPresentExactlyOnce() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeGateStore(activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))
            #expect(store.state.destinationState.destination == .ironwoodAnnouncement)
            #expect(store.state.destinationState.previousDestination == .home)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation + 5)))
            #expect(store.state.destinationState.destination == .ironwoodAnnouncement)
            // `previousDestination` only moves when the destination-assignment line actually
            // runs. If the second tick presented again, it would flip to `.ironwoodAnnouncement`
            // (what `internalDestination` held going into that erroneous second assignment)
            // instead of staying `.home` — proving the second tick was a no-op.
            #expect(store.state.destinationState.previousDestination == .home)
        }
    }

    // MARK: - Case 5: runs above the `selectedWalletAccount` early return

    @Test func presentsWithNoSelectedWalletAccount() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.$selectedWalletAccount.withLock { $0 = nil }
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination == .ironwoodAnnouncement)
        }
    }

    // MARK: - Case 6: safety gate, one term at a time
    //
    // `bgTask == nil` is deliberately NOT covered below: `BGProcessingTask` has no public
    // initializer, so it cannot be constructed in tests. `RootAutoServerGatingTests`
    // (AutoServerSelectionClientTests.swift) documents the identical gap for the sibling
    // `canApplyAutoServerSwitch` gate, which has the same `bgTask == nil` term.

    @Test func safetyGateBlocksWhilePathIsActive() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.path = .receive
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    @Test func safetyGateBlocksWhenDestinationIsNotHome() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.destinationState.destination = .onboarding
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    @Test func safetyGateBlocksWhileSigningWithKeystone() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.signWithKeystoneCoordFlowBinding = true
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    @Test func safetyGateBlocksWhileServerSetupIsVisible() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.serverSetupViewBinding = true
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    @Test func safetyGateBlocksWhileAnAlertIsPresented() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.alert = AlertState.cantLoadSeedPhrase()
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    @Test func safetyGateBlocksBeforeSplashHasAppeared() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.splashAppeared = false
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))

            #expect(store.state.destinationState.destination != .ironwoodAnnouncement)
        }
    }

    // MARK: - Case 7: a blocked attempt does not consume the latch

    @Test func blockedAttemptRetriesOnceTheGateReopens() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.path = .receive
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))
            #expect(store.state.destinationState.destination != .ironwoodAnnouncement, "blocked while `path` is active")

            store.send(.receive(.backToHomeTapped))
            #expect(store.state.path == nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation + 1)))
            #expect(
                store.state.destinationState.destination == .ironwoodAnnouncement,
                "the earlier blocked tick must not have consumed the latch"
            )
        }
    }

    // MARK: - Case 8: foreground call site

    @Test func foregroundCallSitePresentsAnnouncementForAboveActivationTip() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            // Keeps the foreground biometric re-auth block (which may clear `splashAppeared`)
            // from fighting this test's own control of `splashAppeared`.
            state.$featureFlags.withLock { $0 = FeatureFlags(appLaunchBiometric: false) }

            // Built as a `let` via an immediately-invoked closure: the `@Sendable` dependency
            // closure below captures it, and a captured `var` is not allowed there.
            let latest: SynchronizerState = {
                var syncState = SynchronizerState.zero
                syncState.syncStatus = .upToDate
                syncState.latestBlockHeight = activation
                return syncState
            }()

            let store = Store(initialState: state) {
                Root()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.zcashSDKEnvironment.ironwoodActivationHeight = { activation }
                $0.walletStorage = .noOp
                $0.walletStorage.exportIronwoodAnnouncementFlag = { nil }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                // `latestState` is a `let` on `SDKSynchronizerClient`, so it cannot be assigned
                // after the fact — the `.mocked(...)` factory is the only way to inject a tip.
                // Everything else is pinned inert (empty state stream, no transactions) so this
                // case exercises only the announcement gate.
                //
                // `isPrepared: true` (from `.upToDate` above) routes `.willEnterForeground` to
                // `.retryStart`, which unconditionally tries `sdkSynchronizer.start` in a `.run`
                // effect after this case returns. Throwing routes that deferred effect to the
                // harmless `.synchronizerStartFailed -> .none` dead end instead of the full
                // sync-start cascade. Either way this test's assertion is unaffected: it reads
                // state synchronously, before that effect's `Task` ever gets a chance to run.
                $0.sdkSynchronizer = .mocked(
                    stateStream: { Empty().eraseToAnyPublisher() },
                    latestState: { latest },
                    start: { _ in throw GateTestStubError() },
                    getAllTransactions: { _ in [] }
                )
            }

            store.send(.initialization(.appDelegate(.willEnterForeground)))

            #expect(store.state.destinationState.destination == .ironwoodAnnouncement)
        }
    }

    // MARK: - Case 9: `.continueTapped` navigates Root to Home

    @Test func continueTappedNavigatesRootToHome() async throws {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.destinationState.destination = .ironwoodAnnouncement
            let store = makeGateStore(state: state, activationHeight: 1, announcementFlag: nil)

            store.send(.ironwoodAnnouncement(.continueTapped))

            #expect(store.state.destinationState.destination == .home)
        }
    }

    // MARK: - Case 10: debug reset clears the session latch

    @Test func debugResetClearsTheSessionLatchSoTheGateCanReopen() async throws {
        let activation: BlockHeight = 1_000_000

        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.ironwoodAnnouncementResolved = true
            state.settingsState.path.append(.advancedSettings(AdvancedSettings.State.initial))
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: false)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))
            #expect(
                store.state.destinationState.destination != .ironwoodAnnouncement,
                "the session latch must block presentation before the debug reset"
            )

            let pathId = try #require(store.state.settingsState.path.ids.first)
            let debugResetAction = Root.Action.settings(
                .path(.element(id: pathId, action: .advancedSettings(.debugResetIronwoodAnnouncementTapped)))
            )
            store.send(debugResetAction)
            #expect(!store.state.ironwoodAnnouncementResolved)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation + 1)))
            #expect(
                store.state.destinationState.destination == .ironwoodAnnouncement,
                "clearing the latch must let the gate re-evaluate and present"
            )
        }
    }

    // MARK: - Case 11: stale-wallet-healed ordering

    @Test func staleWalletHealedNoticeWaitsBehindTheAnnouncementThenDeliversOnContinue() async throws {
        let activation: BlockHeight = 1_000_000

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = makeState()
            state.isStaleWalletHealedAlertPending = true
            let store = makeGateStore(state: state, activationHeight: activation, announcementFlag: nil)

            store.send(.synchronizerStateChanged(fixtureSyncState(tip: activation)))
            #expect(store.state.destinationState.destination == .ironwoodAnnouncement)
            #expect(store.state.alert == nil, "the heal notice must not appear over the announcement")

            store.send(.ironwoodAnnouncement(.continueTapped))
            #expect(store.state.destinationState.destination == .home)

            await waitForGateStore { store.state.alert != nil }

            #expect(store.state.alert?.title == AlertState.staleWalletDatabaseHealed().title)
            #expect(!store.state.isStaleWalletHealedAlertPending)
        }
    }
}

private struct GateTestStubError: Error { }

@MainActor
private func waitForGateStore(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for Root store state", sourceLocation: sourceLocation)
}
