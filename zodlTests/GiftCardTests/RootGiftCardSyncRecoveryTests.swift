import Combine
import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor struct RootGiftCardSyncRecoveryTests {
    private enum UnacceptedCard: String, CaseIterable, Sendable {
        case wrongNetwork
        case openFailed
    }

    private enum UnacceptedRetirement: String, CaseIterable, Sendable {
        case continueAfterWarning
        case dismiss
        case replace
    }

    private final class Engine: @unchecked Sendable {
        let starts = LockIsolated(0)
        let stops = LockIsolated(0)
        let advances = LockIsolated<[MigrationOpenPhase]>([])
        let subscriptions = LockIsolated(0)
        let gateObservations = LockIsolated(0)
        let delayedObservation = LockIsolated(false)
        let observationEntered = GiftCardTestGate()
        let observationRelease = GiftCardTestGate()
        var holdObservation = false
        let blocked = LockIsolated(false)
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let preparationEntered = GiftCardTestGate()
        let preparationRelease = GiftCardTestGate()
        let beforeSyncEntered = GiftCardTestGate()
        let beforeSyncRelease = GiftCardTestGate()
        var heldAdvanceCall: Int?
        let resetDocuments = FileManager.default.temporaryDirectory.appendingPathComponent("gift-card-reset-\(UUID().uuidString)")
        var holdPreparation = false
        var visit: MigrationVisit = .sync
        var cancelled = false
        var failures = 1
        var migrationFailure = false
        var suspended = false

        func start() async throws {
            let attempt = starts.withValue {
                $0 += 1
                return $0
            }
            if suspended {
                await entered.open()
                await release.wait()
            }
            if cancelled { throw CancellationError() }
            if attempt <= failures {
                if migrationFailure { throw ZcashError.migrationSyncBlocked }
                throw ZcashError.synchronizerDisconnected
            }
        }
    }

    private func makeStore(
        _ engine: Engine, clock: TestClock<Swift.Duration>, pending: Bool = true, cardPresented: Bool = false,
        keysMissing: Bool = false, unacceptedCard: UnacceptedCard? = nil, configure: (inout Root.State) -> Void = { _ in }
    ) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.destinationState.destination = .home
            state.splashAppeared = true
            if keysMissing { state.appInitializationState = .keysMissing }
            state.giftCardSyncResumePending = pending
            if cardPresented {
                state.path = .giftCardCoordFlow
                state.giftCardCoordFlowState = GiftCardCoordFlow.State(link: "https://gift.zodl.com/#fixture".redacted)
            }
            state.giftCardSyncIsPaused = pending
            state.$featureFlags.withLock { $0 = FeatureFlags(appLaunchBiometric: false) }
            configure(&state)
            let store = TestStore(initialState: state) {
                Reduce<Root.State, Root.Action> { state, action in
                    if engine.holdObservation, let generation = Self.observationGeneration(action),
                       engine.delayedObservation.withValue({ delayed in
                           guard !delayed else { return false }
                           delayed = true
                           return true
                       }) {
                        let migrationRestore: Bool
                        if case .giftCardSyncRestoreMigrationObservation = action {
                            migrationRestore = true
                        } else {
                            migrationRestore = false
                        }
                        // Suspend effect delivery before Root admits it, reproducing queued navigation races.
                        return .run { send in
                            await engine.observationEntered.open()
                            await engine.observationRelease.wait()
                            if migrationRestore {
                                await send(.giftCardSyncRestoreMigrationObservation(generation))
                            } else {
                                await send(.giftCardSyncObserve(generation))
                            }
                        }
                    }
                    return Root()._reduce(into: &state, action: action)
                }
            } withDependencies: {
                $0.giftCard = GiftCardClient.mock(unacceptedCard == .wrongNetwork ? .testnet : .ready)
                if unacceptedCard != nil {
                    $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
                }
                if unacceptedCard == .openFailed {
                    $0.giftCard.open = { _ in throw GiftCardClientError.checkFailed }
                }
                $0.mainQueue = .immediate
                $0.continuousClock = clock
                $0.migrationTickInterval = .zero
                $0.exchangeRate = .noOp
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.walletStorage = .noOp
                $0.databaseFiles = .noOp
                $0.databaseFiles.documentsDirectory = { engine.resetDocuments }
                $0.userDefaults = .noOp
                $0.flexaHandler = .noOp
                $0.userStoredPreferences.removeAll = { }
                $0.readTransactionsStorage = .noOp
                $0.userMetadataProvider.reset = { }
                $0.votingMetadata.reset = { }
                $0.votingCrypto.beginWalletTeardown = { }
                $0.votingCrypto.endWalletTeardown = { }
                $0.votingCrypto.closeDatabase = { }
                $0.migrationManager.wipeAllMigrationState = { }
                $0.migrationManager.visitKind = {
                    if engine.holdPreparation {
                        await engine.preparationEntered.open()
                        await engine.preparationRelease.wait()
                    }
                    return engine.visit
                }
                $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
                $0.autoServerSelection.findBestServer = { nil }
                $0.migrationManager.advance = { phase in
                    let call = engine.advances.withValue {
                        $0.append(phase)
                        return $0.filter { $0 == .beforeSync }.count
                    }
                    if phase == .beforeSync, engine.heldAdvanceCall == call {
                        await engine.beforeSyncEntered.open()
                        await engine.beforeSyncRelease.wait()
                    }
                    return .broadcast(id: 1)
                }
                $0.sdkSynchronizer = .mocked(
                    stateStream: {
                        engine.subscriptions.withValue { $0 += 1 }
                        return Empty().eraseToAnyPublisher()
                    },
                    latestState: {
                        var state = SynchronizerState.zero
                        state.syncStatus = .stopped
                        return state
                    },
                    start: { _ in try await engine.start() },
                    stopAndWait: { engine.stops.withValue { $0 += 1 } },
                    isMigrationSyncBlocked: {
                        engine.gateObservations.withValue { $0 += 1 }
                        return engine.blocked.value
                    }
                )
            }
            store.exhaustivity = .off
            return store
        }
    }

    private func drain(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    private func presentUnacceptedCard(
        _ card: UnacceptedCard, in store: TestStore<Root.State, Root.Action>
    ) async throws -> UUID {
        await store.send(.home(.redeemGiftCardTapped))
        await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#unaccepted-fixture".redacted))))
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.onAppear)))
        if card == .openFailed {
            await store.receive({
                if case .giftCardCoordFlow(.redeem(.response(visit, .openFailed(.checkFailed)))) = $0 { return true }
                return false
            })
        }
        #expect(store.state.giftCardCoordFlowState.redeemState?.step == (card == .wrongNetwork ? .wrongNetwork : .checkFailed))
        #expect(store.state.giftCardCoordFlowState.redeemState?.handle == nil)
        #expect(store.state.giftCardSyncPauseOwner == nil)
        return visit
    }

    private func retireUnacceptedCard(
        _ retirement: UnacceptedRetirement, visit: UUID, in store: TestStore<Root.State, Root.Action>
    ) async throws {
        switch retirement {
        case .continueAfterWarning:
            await store.send(.destination(.updateDestination(.deeplinkWarning)))
            await store.send(.deeplinkWarning(.rescanInZashi))
            await store.receive({
                if case .destination(.updateDestination(.home)) = $0 { return true }
                return false
            })
        case .dismiss:
            await store.send(.giftCardCoordFlow(.redeem(.closeTapped)))
            await store.receive({
                if case .giftCardCoordFlow(.redeem(.delegate(.dismiss))) = $0 { return true }
                return false
            })
        case .replace:
            let replacement = "https://gift.zodl.com/#replacement-fixture".redacted
            await store.send(.giftCardCoordFlow(.scan(.foundGiftCard(replacement))))
            let candidate = try #require(store.state.giftCardCoordFlowState.redeemState)
            #expect(candidate.cancelId != visit)
            #expect(candidate.link == replacement)
            #expect(candidate.handle == nil)
        }
        #expect(store.state.giftCardCoordFlowState.redeemState?.cancelId != visit)
        #expect(store.state.giftCardSyncPauseOwner == nil)
        await store.skipReceivedActions(strict: false)
    }

    private static func observationGeneration(_ action: Root.Action) -> UUID? {
        switch action {
        case .giftCardSyncObserve(let generation), .giftCardSyncRestoreMigrationObservation(let generation):
            return generation
        default:
            return nil
        }
    }

    private static func isObservation(_ action: Root.Action) -> Bool {
        switch action {
        case .giftCardSyncObserve, .giftCardSyncRestoreMigrationObservation:
            return true
        default:
            return false
        }
    }

    @Test func homeMigrationCompletionRestoresObservationOnce() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(Self.isObservation)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        })
        #expect(engine.gateObservations.value == 1)
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        for _ in 0..<2 { await store.send(.destination(.updateDestination(.home))) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.gateObservations.value == 1)
        await drain(store)
    }

    @Test(arguments: [false, true])
    func queuedMigrationObservationInterruptedByWarningRestoresOnContinue(continueBeforeCompletion: Bool) async {
        let engine = Engine()
        engine.holdObservation = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock(), configure: {
            $0.giftCardSyncRecovery = .migrationDeferred
            $0.syncDeferredByMigrationGate = true
        })
        await store.send(.splashFinished)
        await store.receive(Self.isObservation)
        await engine.observationEntered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        if continueBeforeCompletion {
            await continueHome(store)
            await store.receive(Self.isObservation)
            await store.receive({
                if case .migrationSyncGateChanged(true) = $0 { return true }
                return false
            })
        }
        await engine.observationRelease.open()
        await store.receive(Self.isObservation)
        if !continueBeforeCompletion {
            #expect(engine.gateObservations.value == 0)
            #expect(store.state.giftCardSyncObservationGeneration == nil)
            await continueHome(store)
            await store.receive(Self.isObservation)
            await store.receive({
                if case .migrationSyncGateChanged(true) = $0 { return true }
                return false
            })
        }
        #expect(engine.gateObservations.value == 1)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        await drain(store)
    }

    @Test func duplicateQueuedMigrationObservationAfterSeedClearanceDoesNotRegisterAgain() async {
        let engine = Engine()
        engine.failures = 0
        engine.visit = .send
        engine.heldAdvanceCall = 1
        let store = makeStore(engine, clock: TestClock(), configure: {
            $0.giftCardSyncRecovery = .migrationDeferred
            $0.syncDeferredByMigrationGate = true
        })
        let generation = store.state.giftCardSyncGeneration
        await store.send(.giftCardSyncRestoreMigrationObservation(generation))
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        await store.receive(\.giftCardSyncVisitReady)
        await engine.beforeSyncEntered.wait()
        #expect(store.state.giftCardSyncRecovery == .none)
        #expect(engine.gateObservations.value == 1)
        await store.send(.giftCardSyncRestoreMigrationObservation(generation))
        await store.send(.giftCardSyncRestoreMigrationObservation(UUID()))
        #expect(engine.gateObservations.value == 1)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        await engine.beforeSyncRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        // Completing beforeSync enters a new hold and needs one fresh seed, independently of
        // the rejected duplicates above. The consumed seed allowance still prevents a restart.
        await store.receive(\.giftCardSyncRestoreMigrationObservation)
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        await store.send(.giftCardSyncRestoreMigrationObservation(generation))
        await store.send(.giftCardSyncRestoreMigrationObservation(UUID()))
        await store.skipReceivedActions(strict: false)
        #expect(engine.gateObservations.value == 2)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 1)
        #expect(engine.starts.value == 0)
        await drain(store)
    }

    private enum NewMigrationHold: String, CaseIterable, Sendable {
        case nativeRefusal
        case sendPreparation

        var startsBeforeRecovery: Int { self == .nativeRefusal ? 2 : 1 }
        var advancesBeforeRecovery: Int { self == .nativeRefusal ? 3 : 2 }
    }

    private enum RefreshedSeedPolicy: String, CaseIterable, Sendable {
        case blocked
        case consumed
    }

    private func observedTransientFailure(
        _ engine: Engine, clock: TestClock<Swift.Duration>, consumedSeed: Bool = false
    ) async -> TestStore<Root.State, Root.Action> {
        engine.failures = 2
        let store = makeStore(engine, clock: clock, configure: {
            $0.giftCardSyncDidRecheckMigrationSeed = consumedSeed
        })
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncObserve)
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        #expect(engine.starts.value == 1)
        #expect(engine.gateObservations.value == 1)
        #expect(store.state.giftCardSyncObservationGeneration == store.state.giftCardSyncGeneration)
        #expect(store.state.giftCardSyncRecovery == .delayedRetry)
        #expect(!store.state.syncDeferredByMigrationGate)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed == consumedSeed)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId != nil)
        return store
    }

    private func completeNewMigrationHold(
        _ hold: NewMigrationHold, underWarning: Bool, engine: Engine,
        clock: TestClock<Swift.Duration>, store: TestStore<Root.State, Root.Action>
    ) async {
        // Delay the first restoration for this new hold, after the earlier false seed.
        engine.holdObservation = true
        engine.migrationFailure = true
        engine.suspended = hold == .nativeRefusal
        engine.visit = hold == .sendPreparation ? .send : .sync
        engine.heldAdvanceCall = hold == .sendPreparation ? 2 : nil
        await clock.advance(by: .seconds(15))
        await store.receive(\.giftCardRetrySync)
        if hold == .nativeRefusal {
            await store.receive(\.giftCardSyncStartReady)
            await engine.entered.wait()
        } else {
            await store.receive(\.giftCardSyncVisitReady)
            await engine.beforeSyncEntered.wait()
        }
        // Only the subsequent recovery visit waits here, so fresh-seed assertions
        // cannot race its native completion or the regular post-start observation.
        engine.holdPreparation = true
        if underWarning { await store.send(.destination(.updateDestination(.deeplinkWarning))) }
        if hold == .nativeRefusal {
            await engine.release.open()
            await store.receive(\.giftCardSyncMigrationRefused)
        } else {
            await engine.beforeSyncRelease.open()
        }
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncStartId == nil)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        #expect(engine.starts.value == hold.startsBeforeRecovery)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == hold.advancesBeforeRecovery)
        // The next admitted visit is sync. No gate edge or synthetic observer event is emitted.
        engine.visit = .sync
        engine.suspended = false
        engine.failures = hold == .sendPreparation ? 1 : 2
    }

    private func releaseNewHoldObservation(_ engine: Engine, store: TestStore<Root.State, Root.Action>) async {
        await store.receive(\.giftCardSyncRestoreMigrationObservation)
        #expect(engine.delayedObservation.value)
        // Opening an existing gate does not wait for a restoration the old code never requests.
        await engine.observationRelease.open()
        await store.receive(\.giftCardSyncRestoreMigrationObservation)
    }

    // A false seed observed before the hold cannot discharge that hold's still-unused allowance.
    @Test(arguments: NewMigrationHold.allCases, [false, true])
    private func newMigrationHoldRefreshesSeedAfterObservedTransientFailure(
        hold: NewMigrationHold, underWarning: Bool
    ) async {
        let engine = Engine()
        let clock = TestClock()
        let store = await observedTransientFailure(engine, clock: clock)
        await completeNewMigrationHold(hold, underWarning: underWarning, engine: engine, clock: clock, store: store)
        #expect(!store.state.giftCardSyncDidRecheckMigrationSeed)
        if underWarning {
            #expect(engine.gateObservations.value == 1)
            #expect(store.state.giftCardSyncObservationGeneration == nil)
            await continueHome(store)
        }
        await releaseNewHoldObservation(engine, store: store)
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        #expect(engine.gateObservations.value == 2)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        #expect(store.state.didScheduleStartFailureRetry)
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == hold.startsBeforeRecovery + 1)
        #expect(!store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncRetryId == nil)
        #expect(store.state.didScheduleStartFailureRetry)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == hold.startsBeforeRecovery + 1)
        await drain(store)
    }

    @Test(arguments: NewMigrationHold.allCases, RefreshedSeedPolicy.allCases)
    private func newMigrationHoldFreshSeedKeepsGateAndSpentAllowances(
        hold: NewMigrationHold, policy: RefreshedSeedPolicy
    ) async {
        let engine = Engine()
        let clock = TestClock()
        let consumed = policy == .consumed
        let store = await observedTransientFailure(engine, clock: clock, consumedSeed: consumed)
        // The publisher remains empty: only the new explicit seed can see this value.
        engine.blocked.setValue(policy == .blocked)
        await completeNewMigrationHold(hold, underWarning: true, engine: engine, clock: clock, store: store)
        #expect(engine.gateObservations.value == 1)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed == consumed)
        await continueHome(store)
        await releaseNewHoldObservation(engine, store: store)
        await store.receive({
            if case .migrationSyncGateChanged(let blocked) = $0 { return blocked == (policy == .blocked) }
            return false
        })
        #expect(engine.gateObservations.value == 2)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed == consumed)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        for _ in 0..<2 {
            await continueHome(store)
            await store.send(.giftCardSyncRestoreMigrationObservation(store.state.giftCardSyncGeneration))
        }
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(60))
        #expect(engine.gateObservations.value == 2)
        #expect(engine.starts.value == hold.startsBeforeRecovery)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == hold.advancesBeforeRecovery)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed == consumed)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        // A genuine edge may begin a new recovery epoch even when the old seed was consumed.
        await store.send(.migrationSyncGateChanged(true))
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == hold.startsBeforeRecovery + 1)
        #expect(!store.state.giftCardSyncResumePending)
        #expect(store.state.didScheduleStartFailureRetry)
        await drain(store)
    }

    @Test func refreshedSeedCannotReplenishSpentTransientRetry() async {
        let engine = Engine()
        let clock = TestClock()
        let store = await observedTransientFailure(engine, clock: clock)
        await completeNewMigrationHold(.nativeRefusal, underWarning: false, engine: engine, clock: clock, store: store)
        engine.failures = 3
        engine.migrationFailure = false
        await releaseNewHoldObservation(engine, store: store)
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        #expect(engine.gateObservations.value == 2)
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 3)
        #expect(store.state.giftCardSyncRecovery == .waitingForExternalTrigger)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 3)
        #expect(store.state.giftCardSyncRetryId == nil)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    private enum PreparationStage: String, CaseIterable, Sendable {
        case visitKind
        case beforeSync

        func hold(_ engine: Engine) {
            engine.holdPreparation = self == .visitKind
            engine.heldAdvanceCall = self == .beforeSync ? 1 : nil
        }

        func wait(_ engine: Engine, store: TestStore<Root.State, Root.Action>) async {
            if self == .visitKind {
                await engine.preparationEntered.wait()
            } else {
                await store.receive(\.giftCardSyncVisitReady)
                await engine.beforeSyncEntered.wait()
            }
        }

        func release(_ engine: Engine) async {
            if self == .visitKind {
                await engine.preparationRelease.open()
            } else {
                await engine.beforeSyncRelease.open()
            }
        }
    }

    private enum Retirement: String, CaseIterable, Sendable {
        case background
        case walletReset
        case acceptedVisit
    }

    private func continueHome(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive({
            if case .destination(.updateDestination(.home)) = $0 { return true }
            return false
        })
    }

    private func retire(_ boundary: Retirement, store: TestStore<Root.State, Root.Action>) async throws {
        switch boundary {
        case .background:
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
        case .walletReset:
            await store.send(.resetZashiSDKSucceeded)
            await store.receive(\.resetZashiKeychainRequest)
        case .acceptedVisit:
            await store.send(.home(.redeemGiftCardTapped))
            await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#retirement-fixture".redacted))))
            let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
            await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        }
    }

    // Hiding Home during preparation must defer admission, whereas native cancellation stays external-trigger-only.
    @Test(arguments: PreparationStage.allCases, [false, true])
    private func preparationNavigationPreservesRestartIntent(stage: PreparationStage, continueFirst: Bool) async throws {
        let engine = Engine()
        engine.failures = 0
        stage.hold(engine)
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await stage.wait(engine, store: store)
        let start = try #require(store.state.giftCardSyncStartId)
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        if continueFirst {
            await continueHome(store)
            #expect(engine.starts.value == 0)
            #expect(store.state.giftCardSyncStartId == start)
        }
        await stage.release(engine)
        await store.receive(\.giftCardSyncStartFinished)
        if !continueFirst {
            #expect(engine.starts.value == 0)
            #expect(store.state.giftCardSyncResumePending)
            #expect(store.state.giftCardSyncRecovery == .none)
            #expect(store.state.giftCardSyncRetryId == nil)
            #expect(!store.state.didScheduleStartFailureRetry)
            #expect(!store.state.giftCardSyncDidRecheckMigrationSeed)
            await continueHome(store)
            await store.receive(\.giftCardSyncStartFinished)
        }
        #expect(engine.starts.value == 1)
        #expect(!store.state.giftCardSyncResumePending)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func realCancellationUnderWarningStillWaitsForExternalTrigger() async {
        let engine = Engine()
        engine.suspended = true
        engine.cancelled = true
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await continueHome(store)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncRecovery == .waitingForExternalTrigger)
        #expect(!store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        await drain(store)
    }

    @Test(arguments: PreparationStage.allCases)
    private func spentRetryBudgetSurvivesPreparationNavigation(stage: PreparationStage) async {
        let engine = Engine()
        stage.hold(engine)
        engine.failures = 100
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, configure: {
            $0.didScheduleStartFailureRetry = true
            $0.giftCardSyncDidRecheckMigrationSeed = true
        })
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await stage.wait(engine, store: store)
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await stage.release(engine)
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        #expect(store.state.giftCardSyncRetryId == nil)
        await continueHome(store)
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncRecovery == .waitingForExternalTrigger)
        #expect(store.state.didScheduleStartFailureRetry)
        #expect(store.state.giftCardSyncRetryId == nil)
        await drain(store)
    }

    @Test(arguments: PreparationStage.allCases, Retirement.allCases)
    private func preparationRetirementDoesNotAdmitOldWork(stage: PreparationStage, boundary: Retirement) async throws {
        let engine = Engine()
        engine.failures = 0
        stage.hold(engine)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await stage.wait(engine, store: store)
        let generation = store.state.giftCardSyncGeneration
        let start = try #require(store.state.giftCardSyncStartId)
        try await retire(boundary, store: store)
        #expect(store.state.giftCardSyncGeneration != generation)
        #expect(store.state.giftCardSyncStartId == start)
        let recovery = store.state.giftCardSyncRecovery
        await stage.release(engine)
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncStartId == nil)
        #expect(store.state.giftCardSyncRecovery == recovery)
        await drain(store)
    }

    @Test func cachedMigrationBlockSurvivesPreparationNavigation() async {
        let engine = Engine()
        engine.failures = 0
        engine.holdPreparation = true
        let store = makeStore(engine, clock: TestClock(), configure: { $0.giftCardSyncDidRecheckMigrationSeed = true })
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.preparationEntered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        engine.blocked.setValue(true)
        await store.send(.migrationSyncGateChanged(true))
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        await continueHome(store)
        await store.receive(Self.isObservation)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        })
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func migrationRefusalUnderWarningDischargesBeforeSync() async throws {
        let engine = Engine()
        engine.suspended = true
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        engine.heldAdvanceCall = 2
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        let start = try #require(store.state.giftCardSyncStartId)
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await engine.release.open()
        await store.receive(\.giftCardSyncMigrationRefused)
        #expect(store.state.giftCardSyncStartId == start)
        // Open without waiting for entry: the old implementation never reaches this advance.
        await engine.beforeSyncRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 2)
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncStartId == nil)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        await continueHome(store)
        await store.receive(Self.isObservation)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        })
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncResumePending)
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func sendPreparationUnderWarningRestoresGateObservation() async {
        let engine = Engine()
        engine.visit = .send
        engine.failures = 0
        engine.heldAdvanceCall = 1
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncVisitReady)
        await engine.beforeSyncEntered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await engine.beforeSyncRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        await continueHome(store)
        await store.receive(Self.isObservation)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        })
        let registrations = engine.gateObservations.value
        #expect(registrations == 1)
        for _ in 0..<2 {
            await continueHome(store)
            await store.send(.migrationSyncGateChanged(true))
        }
        await store.skipReceivedActions(strict: false)
        #expect(engine.gateObservations.value == registrations)
        #expect(engine.starts.value == 0)
        engine.visit = .sync
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 1)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func spentMigrationSeedSurvivesWarningNavigation() async {
        let engine = Engine()
        engine.visit = .send
        engine.failures = 0
        engine.heldAdvanceCall = 1
        let store = makeStore(engine, clock: TestClock(), configure: { $0.giftCardSyncDidRecheckMigrationSeed = true })
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncVisitReady)
        await engine.beforeSyncEntered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await engine.beforeSyncRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        await continueHome(store)
        await store.receive(Self.isObservation)
        await store.receive({
            if case .migrationSyncGateChanged(false) = $0 { return true }
            return false
        })
        for _ in 0..<2 { await continueHome(store) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 0)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 1)
        #expect(store.state.giftCardSyncDidRecheckMigrationSeed)
        #expect(store.state.giftCardSyncRecovery == .migrationDeferred)
        engine.visit = .sync
        engine.blocked.setValue(true)
        await store.send(.migrationSyncGateChanged(true))
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 1)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test(arguments: Retirement.allCases)
    private func retiredMigrationRefusalDoesNotAdvance(boundary: Retirement) async throws {
        let engine = Engine()
        engine.suspended = true
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        try await retire(boundary, store: store)
        let recovery = store.state.giftCardSyncRecovery
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 1)
        #expect(engine.starts.value == 1)
        #expect(store.state.giftCardSyncStartId == nil)
        #expect(store.state.giftCardSyncRecovery == recovery)
        await drain(store)
    }

    @Test func currentMigrationRefusalInBackgroundTaskDoesNotAdvance() async throws {
        let engine = Engine()
        let start = UUID()
        let store = makeStore(engine, clock: TestClock(), configure: {
            $0.giftCardSyncStartId = start
            $0.giftCardSyncStartGeneration = $0.giftCardSyncGeneration
            $0.appStartState = .backgroundTask
        })
        let generation = store.state.giftCardSyncGeneration
        await store.send(.giftCardSyncMigrationRefused(start))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.giftCardSyncGeneration == generation)
        #expect(engine.advances.value.isEmpty)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncStartId == nil)
        #expect(store.state.giftCardSyncRecovery == .waitingForExternalTrigger)
        await drain(store)
    }

    // A card rejected before opening never owns the sync pause. Its retirement must not
    // shorten the original recovery deadline or turn a spent retry into another start.
    @Test(arguments: UnacceptedCard.allCases, UnacceptedRetirement.allCases)
    private func unacceptedCardRetirementKeepsTheOriginalRetryDeadline(
        card: UnacceptedCard, retirement: UnacceptedRetirement
    ) async throws {
        let engine = Engine()
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, unacceptedCard: card)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        let retry = try #require(store.state.giftCardSyncRetryId)
        await clock.advance(by: .seconds(5))
        let visit = try await presentUnacceptedCard(card, in: store)
        try await retireUnacceptedCard(retirement, visit: visit, in: store)
        #expect(store.state.giftCardSyncRetryId == retry)
        await clock.advance(by: .seconds(9))
        #expect(engine.starts.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        await drain(store)
    }

    @Test(arguments: UnacceptedCard.allCases, UnacceptedRetirement.allCases)
    private func unacceptedCardRetirementKeepsTheSpentForegroundRetryBudget(
        card: UnacceptedCard, retirement: UnacceptedRetirement
    ) async throws {
        let engine = Engine()
        engine.failures = 100
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, unacceptedCard: card)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(15))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        let visit = try await presentUnacceptedCard(card, in: store)
        try await retireUnacceptedCard(retirement, visit: visit, in: store)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.didScheduleStartFailureRetry)
        await drain(store)
    }

    @Test(arguments: UnacceptedCard.allCases, UnacceptedRetirement.allCases)
    private func unacceptedCardRetirementCannotReplenishTheMigrationSeedRecheck(
        card: UnacceptedCard, retirement: UnacceptedRetirement
    ) async throws {
        let engine = Engine()
        engine.migrationFailure = true
        engine.failures = 100
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, unacceptedCard: card)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        let visit = try await presentUnacceptedCard(card, in: store)
        try await retireUnacceptedCard(retirement, visit: visit, in: store)
        for _ in 0..<3 { await store.send(.migrationSyncGateChanged(false)) }
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    // Swallowing the first failure strands sync; immediately reconciling pending demand spins.
    @Test(arguments: [1, 2]) func failedStartKeepsDemandAndRetriesOnlyOnceAfterFifteenSeconds(failures: Int) async {
        let engine = Engine()
        engine.failures = failures
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive({
            if case .giftCardSyncStartFinished(_, .transientFailure(.synchronizerDisconnected)) = $0 { return true }
            return false
        }, timeout: .seconds(2))
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.didScheduleStartFailureRetry)
        await clock.advance(by: .seconds(14))
        #expect(engine.starts.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending == (failures == 2))
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        await drain(store)
    }

    @Test(arguments: [0, 1]) func delayedRetryCannotOutliveBackgroundOrAcceptedVisit(boundary: Int) async throws {
        let engine = Engine()
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        let retiredRetry = try #require(store.state.giftCardSyncRetryId)
        #expect(store.state.giftCardSyncResumePending)
        if boundary == 0 {
            await store.send(.initialization(.appDelegate(.didEnterBackground)))
        } else {
            await store.send(.home(.redeemGiftCardTapped))
            await store.send(.giftCardCoordFlow(.scan(.foundGiftCard("https://gift.zodl.com/#fixture".redacted))))
            let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
            await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        }
        await store.send(.giftCardRetrySync(retiredRetry))
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    // Continue replaces the entire Root state, but it is navigation in the same wallet.
    // Losing the timer or restarting its countdown would miss the original 15-second retry.
    @Test(arguments: [false, true])
    func continueBeforeDeadlinePreservesTheOriginalRetryAfterWarning(failureFinishesUnderWarning: Bool) async {
        let engine = Engine()
        engine.suspended = failureFinishesUnderWarning
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        if failureFinishesUnderWarning {
            await engine.entered.wait()
            await store.send(.destination(.updateDestination(.deeplinkWarning)))
            await engine.release.open()
        }
        await store.receive(\.giftCardSyncStartFinished)
        if !failureFinishesUnderWarning {
            await store.send(.destination(.updateDestination(.deeplinkWarning)))
        }
        await clock.advance(by: .seconds(5))
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive({
            if case .destination(.updateDestination(.home)) = $0 { return true }
            return false
        })
        await clock.advance(by: .seconds(9))
        #expect(engine.starts.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func retryDueUnderWarningStartsOnceWhenContinueReturnsHome() async {
        let engine = Engine()
        engine.suspended = true
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(15))
        await store.receive(\.giftCardRetrySync, timeout: .seconds(2))
        #expect(engine.starts.value == 1)
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        await drain(store)
    }

    @Test func continueDuringSuspendedFailureKeepsItsSameWalletRecovery() async {
        let engine = Engine()
        engine.suspended = true
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive({
            if case .destination(.updateDestination(.home)) = $0 { return true }
            return false
        })
        #expect(engine.starts.value == 1)
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(14))
        #expect(engine.starts.value == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        await drain(store)
    }

    @Test(arguments: [false, true])
    func genuineWalletResetRetiresTheOldRetryBeforeReturningHome(keysMissing: Bool) async throws {
        let engine = Engine()
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, keysMissing: keysMissing)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        let retiredRetry = try #require(store.state.giftCardSyncRetryId)
        await store.send(.resetZashiSDKSucceeded)
        await store.receive(\.resetZashiKeychainRequest)
        await store.skipReceivedActions(strict: false)
        await store.send(.destination(.updateDestination(.home)))
        await store.send(.splashFinished)
        await store.send(.giftCardRetrySync(retiredRetry))
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func foregroundStartsANewRetryBudgetWithoutAdmittingTheRetiredTimer() async throws {
        let engine = Engine()
        engine.failures = 2
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        let retiredRetry = try #require(store.state.giftCardSyncRetryId)
        await clock.advance(by: .seconds(5))
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        await store.send(.giftCardRetrySync(retiredRetry))
        await clock.advance(by: .seconds(14))
        #expect(engine.starts.value == 2)
        await clock.advance(by: .seconds(1))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 3)
        await drain(store)
    }

    @Test func continueCannotReplenishTheMigrationSeedRecheck() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.failures = 100
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        for _ in 0..<3 {
            await store.send(.deeplinkWarning(.rescanInZashi))
            await store.receive({
                if case .destination(.updateDestination(.home)) = $0 { return true }
                return false
            })
            await store.send(.migrationSyncGateChanged(false))
        }
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func repeatedContinueDoesNotReplenishTheSpentForegroundRetry() async {
        let engine = Engine()
        engine.failures = 100
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await clock.advance(by: .seconds(5))
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive({
            if case .destination(.updateDestination(.home)) = $0 { return true }
            return false
        })
        await clock.advance(by: .seconds(10))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        for _ in 0..<3 {
            await store.send(.destination(.updateDestination(.deeplinkWarning)))
            await store.send(.deeplinkWarning(.rescanInZashi))
            await store.receive({
                if case .destination(.updateDestination(.home)) = $0 { return true }
                return false
            })
        }
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        #expect(store.state.didScheduleStartFailureRetry)
        await drain(store)
    }

    @Test func dueRetryPreservesTheMigrationBlockAcrossContinueUntilActualClearance() async {
        let engine = Engine()
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        engine.blocked.setValue(true)
        await store.send(.migrationSyncGateChanged(true))
        await store.send(.destination(.updateDestination(.deeplinkWarning)))
        await clock.advance(by: .seconds(15))
        await store.receive(\.giftCardRetrySync, timeout: .seconds(2))
        #expect(engine.starts.value == 1)
        for _ in 0..<3 {
            await store.send(.deeplinkWarning(.rescanInZashi))
            await store.receive({
                if case .destination(.updateDestination(.home)) = $0 { return true }
                return false
            })
            await store.send(.migrationSyncGateChanged(true))
            #expect(store.state.lastMigrationSyncGateBlocked)
            #expect(engine.starts.value == 1)
        }
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    // The real Root migration policy must discharge beforeSync, restore feeds, and hold demand.
    @Test func migrationRefusalRestoresObservationAndWaitsForClearance() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(store.state.syncDeferredByMigrationGate)
        #expect(store.state.giftCardSyncResumePending)
        #expect(engine.advances.value.filter { $0 == .beforeSync }.count == 2)
        #expect(engine.subscriptions.value > 0)
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func ordinaryRetryCannotOverlapAnOwnedNativeStart() async {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.initialization(.retryStart))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func backgroundDuringGiftPreparationDoesNotStartTheEngine() async {
        let engine = Engine()
        engine.failures = 0
        engine.holdPreparation = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.preparationEntered.wait()
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await engine.preparationRelease.open()
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 0)
        #expect(store.state.giftCardSyncStartId == nil)
        await drain(store)
    }

    @Test func successfulRecoveryRestoresForegroundSubscriptions() async {
        let engine = Engine()
        engine.failures = 0
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncObserve, timeout: .seconds(2))
        #expect(engine.subscriptions.value > 0)
        await drain(store)
    }

    @Test func cancelledStartKeepsDemandWithoutAutomaticRetry() async {
        let engine = Engine()
        engine.cancelled = true
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished) { state in
            #expect(state.giftCardSyncResumePending)
        }
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 1)
        #expect(!store.state.didScheduleStartFailureRetry)
        await drain(store)
    }

    @Test func acceptedVisitDuringSuspendedStartWaitsForCompletionBeforeStopping() async throws {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock(), cardPresented: true)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.send(.initialization(.retryStart))
        #expect(engine.stops.value == 0)
        await engine.release.open()
        await store.receive(\.giftCardSyncStopped)
        #expect(engine.starts.value == 1)
        #expect(engine.stops.value == 1)
        #expect(store.state.giftCardSyncPauseOwner == visit)
        await drain(store)
    }

    @Test func persistentMigrationRefusalPermitsOnlyOneFalseSeedRecheck() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.failures = 100
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        for _ in 0..<3 { await store.send(.migrationSyncGateChanged(false)) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func gateClearanceDuringOwnedStartCannotAdmitAnotherStart() async {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await engine.entered.wait()
        await store.send(.migrationGateDeferredSyncStart)
        await store.send(.migrationSyncGateChanged(true))
        await store.send(.migrationSyncGateChanged(false))
        await engine.release.open()
        await store.receive(\.giftCardSyncStartFinished)
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await drain(store)
    }

    @Test func cancelledOrdinaryPreparationReleasesItsCompletionFence() async {
        let engine = Engine()
        engine.holdPreparation = true
        let store = makeStore(engine, clock: TestClock(), pending: false)
        await store.send(.initialization(.retryStart))
        await engine.preparationEntered.wait()
        #expect(store.state.ordinarySyncOperations.count == 1)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await engine.preparationRelease.open()
        await store.receive(\.ordinarySyncFinished)
        #expect(engine.starts.value == 0)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        await drain(store)
    }

    @Test func ordinaryCompletionSurvivesRootResetAndBackground() async throws {
        let engine = Engine()
        engine.failures = 0
        engine.suspended = true
        let store = makeStore(engine, clock: TestClock(), pending: false, cardPresented: true)
        await store.send(.initialization(.retryStart))
        await engine.entered.wait()
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        let operation = try #require(store.state.ordinarySyncOperations.first)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        await store.send(.deeplinkWarning(.rescanInZashi))
        #expect(store.state.ordinarySyncOperations.contains(operation))
        #expect(engine.stops.value == 0)
        await engine.release.open()
        await store.receive(\.ordinarySyncFinished)
        await store.receive(\.giftCardSyncStopped)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        #expect(engine.starts.value == 1)
        #expect(engine.stops.value == 2)
        await drain(store)
    }


    @Test func ordinaryFailureAndGiftFailureShareOneForegroundRetryBudget() async throws {
        let engine = Engine()
        engine.failures = 2
        let clock = TestClock()
        let store = makeStore(engine, clock: clock, pending: false, cardPresented: true)
        await store.send(.initialization(.retryStart))
        await store.receive(\.ordinarySyncFinished)
        #expect(store.state.didScheduleStartFailureRetry)
        let visit = try #require(store.state.giftCardCoordFlowState.redeemState?.cancelId)
        await store.send(.giftCardCoordFlow(.redeem(.response(visit, .opened(GiftCardHandle())))))
        await store.receive(\.giftCardSyncStopped)
        await store.send(.giftCardCoordFlow(.redeem(.delegate(.dismiss))))
        await store.receive(\.giftCardSyncStartFinished)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == 2)
        #expect(store.state.giftCardSyncResumePending)
        await drain(store)
    }

    @Test func broadcastVisitDefersWithoutCallingNativeStartOrSpinningOnFalseSeeds() async {
        let engine = Engine()
        engine.visit = .send
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished)
        for _ in 0..<3 { await store.send(.migrationSyncGateChanged(false)) }
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 0)
        #expect(engine.advances.value == [.beforeSync, .beforeSync])
        #expect(store.state.syncDeferredByMigrationGate)
        await drain(store)
    }

    @Test func immediateOrdinaryCompletionAlwaysReleasesTheAdmissionFence() async {
        let engine = Engine()
        engine.failures = 0
        let store = makeStore(engine, clock: TestClock(), pending: false)
        await store.send(.initialization(.retryStart))
        await store.receive(\.ordinarySyncFinished)
        #expect(engine.starts.value == 1)
        #expect(store.state.ordinarySyncOperations.isEmpty)
        await drain(store)
    }


    @Test func gateClearanceBeforeObservationRestorationGetsOneFreshRecheck() async {
        let engine = Engine()
        engine.migrationFailure = true
        // The native refusal observed a blocked gate, but by the first restored feed it is clear.
        engine.blocked.setValue(false)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        #expect(engine.starts.value == 2)
        #expect(!store.state.giftCardSyncResumePending)
        await drain(store)
    }


    @Test func migrationClearanceInBackgroundWaitsForForeground() async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let store = makeStore(engine, clock: TestClock())
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        engine.blocked.setValue(false)
        await store.send(.migrationSyncGateChanged(false))
        await store.skipReceivedActions(strict: false)
        #expect(engine.starts.value == 1)
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await store.receive(\.giftCardSyncStartFinished)
        #expect(engine.starts.value == 2)
        await drain(store)
    }


    @Test(arguments: [false, true])
    func foregroundRefreshesTheMigrationGateThatWasUnobservedInBackground(gateClears: Bool) async {
        let engine = Engine()
        engine.migrationFailure = true
        engine.blocked.setValue(true)
        let clock = TestClock()
        let store = makeStore(engine, clock: clock)
        await store.send(.giftCardResumeSync(store.state.giftCardSyncGeneration))
        await store.receive(\.giftCardSyncStartFinished)
        await store.receive({
            if case .migrationSyncGateChanged(true) = $0 { return true }
            return false
        }, timeout: .seconds(2))
        #expect(store.state.lastMigrationSyncGateBlocked)
        let subscriptionsBeforeBackground = engine.subscriptions.value
        let retiredGeneration = store.state.giftCardSyncGeneration
        await store.send(.initialization(.appDelegate(.didEnterBackground)))
        // No reducer gate action: the actual SDK gate changes while its observations are cancelled.
        engine.blocked.setValue(!gateClears)
        await store.send(.giftCardSyncObserve(retiredGeneration))
        #expect(engine.subscriptions.value == subscriptionsBeforeBackground)
        await store.send(.initialization(.appDelegate(.willEnterForeground)))
        await store.receive(\.giftCardSyncObserve, timeout: .seconds(2))
        await store.receive({
            if case .migrationSyncGateChanged(let blocked) = $0 { return blocked == !gateClears }
            return false
        }, timeout: .seconds(2))
        #expect(engine.subscriptions.value > subscriptionsBeforeBackground)
        if gateClears {
            await store.receive(\.giftCardSyncStartFinished, timeout: .seconds(2))
        }
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(60))
        #expect(engine.starts.value == (gateClears ? 2 : 1))
        #expect(store.state.giftCardSyncResumePending == !gateClears)
        #expect(store.state.lastMigrationSyncGateBlocked == !gateClears)
        await drain(store)
    }

}
