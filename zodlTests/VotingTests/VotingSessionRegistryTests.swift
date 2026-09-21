#if VOTING_ENABLED
import Foundation
import os
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// The registry's bookkeeping, and what it does while a session is closing.
///
/// A `VotingRoundSession` can only be made by the SDK — the backend call that
/// builds one is internal to it — so the registry is generic over
/// `VotingRegistrySession`, the few members it actually uses, and takes its
/// factory as an injected closure. Tests that need nothing in the maps give it
/// the app's own factory, which refuses: that covers the empty registry, a
/// refused open, and the two teardown calls. Tests about a close that is still
/// running give it `FakeSession`, whose `close()` stops where the test wants it
/// — the only way to ask what a second closer does while a first one is still
/// joining the calls a session has in flight.
@Suite struct VotingSessionRegistryTests {
    private let roundId = "a1b2c3"

    @Test func sessionForAnUnopenedRoundThrowsNotOpen() async throws {
        let registry = makeRegistry()

        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func aRefusedOpenSurfacesTheFactoryErrorAndLeavesTheRegistryEmpty() async throws {
        let registry = makeRegistry()

        let error = await #expect(throws: VotingError.self) {
            _ = try await registry.open(
                inputs: VotingSessionRegistryTests.inputs(roundId: roundId),
                binding: VotingSessionBinding(roster: []),
                route: .direct,
                epoch: 0
            )
        }

        #expect(error?.kind == .internal)
        #expect(await registry.openRoundIds.isEmpty)
        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func closingARoundThatWasNeverOpenedLeavesItUnopened() async throws {
        let registry = makeRegistry()

        await registry.close(roundId)

        #expect(await registry.openRoundIds.isEmpty)
        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    @Test func closeAllEmptiesTheRegistryAndMovesTheGenerationOn() async throws {
        let registry = makeRegistry()
        let before = await registry.generation

        await registry.closeAll()

        #expect(await registry.openRoundIds.isEmpty)
        #expect(await registry.generation == before + 1)
    }

    /// A refreshed service configuration is pushed into whatever the registry
    /// actually has open. The factory this test uses refuses -- a
    /// ``VotingRoundSession`` can only be made by the SDK, see the file
    /// comment -- so an attempted open never lands a session here, the same
    /// "nothing open" shape as a registry nothing was ever opened on. Either
    /// way the push must be silent: it must not throw, and it must not touch
    /// `openRoundIds`, which is the registry's bookkeeping, not the session's.
    @Test func updateHostConfigurationWithNoOpenSessionIsANoOp() async {
        let registry = makeRegistry()

        _ = try? await registry.open(
            inputs: VotingSessionRegistryTests.inputs(roundId: roundId),
            binding: VotingSessionBinding(roster: []),
            route: .direct,
            epoch: 0
        )
        #expect(await registry.openRoundIds.isEmpty)

        await registry.updateHostConfiguration(VotingHostOverrides(helperUrls: ["https://h.example/"]))

        #expect(await registry.openRoundIds.isEmpty)
    }

    /// Staged rather than timed. The overlap this is about is the window
    /// between an open registering its attempt and its session arriving, and
    /// the factory holds that window open until the second caller is on its way
    /// in — where a sleep would close it early under load and fail the
    /// assertion on correct behaviour.
    @Test func twoConcurrentOpensForOneRoundBuildOneSessionAndShareItsOutcome() async throws {
        let factory = SlowFactory()
        let registry = VotingSessionRegistry { inputs, binding, route, epoch in
            try await factory.make(inputs, binding, route, epoch)
        }
        let inputs = VotingSessionRegistryTests.inputs(roundId: roundId)

        let first = Task {
            try await registry.open(
                inputs: inputs,
                binding: VotingSessionBinding(roster: []),
                route: .direct,
                epoch: 0
            )
        }
        // The first open is inside the factory and staying there, so its
        // attempt is registered and cannot finish before the second arrives.
        await wait(for: factory.entered, "the first open to reach the factory")

        let second = Task {
            // Released from here, as this caller's last act before entering the
            // registry: the attempt it has to join is provably still in flight
            // when it gets there.
            await factory.released.open()
            return try await registry.open(
                inputs: inputs,
                binding: VotingSessionBinding(roster: []),
                route: .direct,
                epoch: 0
            )
        }

        let outcomes = [await first.result, await second.result]

        // One attempt, and both callers saw it — not two sessions, one of which
        // nothing would ever close.
        #expect(await factory.calls == 1)
        for outcome in outcomes {
            guard case .failure(let error) = outcome else {
                Issue.record("an open backed by a refusing factory must fail")
                continue
            }
            #expect(error is SlowFactory.Refusal)
        }
        #expect(await registry.openRoundIds.isEmpty)
    }

    @Test func closeAllDuringAnInFlightOpenLeavesTheRegistryEmpty() async throws {
        let factory = SlowFactory()
        let registry = VotingSessionRegistry { inputs, binding, route, epoch in
            try await factory.make(inputs, binding, route, epoch)
        }
        let generationBefore = await registry.generation

        let opening = Task {
            try await registry.open(
                inputs: VotingSessionRegistryTests.inputs(roundId: roundId),
                binding: VotingSessionBinding(roster: []),
                route: .direct,
                epoch: 0
            )
        }
        // The open has registered its attempt and is held inside the factory.
        await wait(for: factory.entered, "the open to reach the factory")

        // Returns only once the open it interrupted has finished, so nothing
        // can register a session behind it. The factory is still holding, and
        // it is `closeAll`'s own cancellation that lets it go — which is the
        // thing being asserted, not a release this test hands out.
        await registry.closeAll()

        #expect(await registry.openRoundIds.isEmpty)
        #expect(await registry.generation == generationBefore + 1)
        if case .success = await opening.result {
            Issue.record("an open interrupted by closeAll must not hand back a session")
        }
        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
    }

    // MARK: - Closers that overlap a session that is still closing

    /// The reset's drain and the flow's own close run at the same time by
    /// design, so the second of them has to mean what it says. Returning from
    /// `closeAll` is the licence to close the store and delete its file, and a
    /// closer that only checked whether the maps were empty would hand that
    /// licence out while the first closer was still joining the calls the
    /// session has in flight.
    @Test func twoOverlappingCloseAllsBothWaitForTheSessionStillClosing() async throws {
        let events = SignalledRecords<String>()
        let hold = ResumableGate()
        let session = FakeSession(roundId: roundId, events: events, closeHold: hold)
        let factory = FakeSessionFactory(sessions: [session], events: events)
        let registry = makeFakeRegistry(factory)
        try await VotingSessionRegistryTests.open(registry, roundId)
        let generationBefore = await registry.generation

        let roundId = self.roundId
        let first = Task {
            await registry.closeAll()
            events.record("firstCloseAllReturned")
        }
        // The first closer is provably inside the session's `close()`, so the
        // registry's own books are already empty when the second one arrives --
        // which is exactly the state that used to let it walk straight out.
        await settle("the first closer to reach the session's close") { session.isClosing }

        let second = Task {
            await registry.closeAll()
            events.record("secondCloseAllReturned")
        }
        // `closeAll` moves the generation in its synchronous prologue, before it
        // can suspend, so a second bump is the second closer's own proof that it
        // is inside. Nothing here waits on the clock for it.
        await settle("the second closer to enter the registry") {
            await registry.generation == generationBefore + 2
        }

        #expect(
            !events.values.contains("secondCloseAllReturned"),
            "a closer that found nothing left to remove must not return while a session is still closing"
        )
        #expect(await registry.pendingDrainCount == 1, "the close still running must be visible to every closer")

        hold.open()
        await first.value
        await second.value

        let recorded = events.values
        let closed = try #require(recorded.firstIndex(of: "closed(\(roundId))"))
        let firstReturned = try #require(recorded.firstIndex(of: "firstCloseAllReturned"))
        let secondReturned = try #require(recorded.firstIndex(of: "secondCloseAllReturned"))
        #expect(closed < firstReturned, "the closer that started the close must wait for it")
        #expect(closed < secondReturned, "the closer that joined it must wait for it too")
        #expect(session.recorded.closesStarted == 1, "joining must not close the session twice")
        #expect(await registry.pendingDrainCount == 0)
        #expect(await registry.openRoundIds.isEmpty)
    }

    /// The two closers are not the same call: the flow closes one round at a
    /// time and the reset closes everything. A drain the per-round close started
    /// still has to hold the wholesale one.
    @Test func aCloseAllJoinsACloseOfOneRoundAlreadyInProgress() async throws {
        let events = SignalledRecords<String>()
        let hold = ResumableGate()
        let session = FakeSession(roundId: roundId, events: events, closeHold: hold)
        let factory = FakeSessionFactory(sessions: [session], events: events)
        let registry = makeFakeRegistry(factory)
        try await VotingSessionRegistryTests.open(registry, roundId)
        let generationBefore = await registry.generation

        let roundId = self.roundId
        let closing = Task {
            await registry.close(roundId)
            events.record("closeReturned")
        }
        await settle("the round's close to reach its session") { session.isClosing }

        let draining = Task {
            await registry.closeAll()
            events.record("closeAllReturned")
        }
        await settle("the drain to enter the registry") {
            await registry.generation == generationBefore + 1
        }

        #expect(
            !events.values.contains("closeAllReturned"),
            "a wholesale close must not return while a per-round close is still running"
        )

        hold.open()
        await closing.value
        await draining.value

        let recorded = events.values
        let closed = try #require(recorded.firstIndex(of: "closed(\(roundId))"))
        let closeReturned = try #require(recorded.firstIndex(of: "closeReturned"))
        let closeAllReturned = try #require(recorded.firstIndex(of: "closeAllReturned"))
        #expect(closed < closeReturned)
        #expect(closed < closeAllReturned)
        #expect(await registry.pendingDrainCount == 0)
        #expect(await registry.openRoundIds.isEmpty)
    }

    /// Two sessions on one round would contend for its rows in the sidecar, so
    /// the replacement is not built until the previous one has finished closing
    /// -- and, while it waits, the close it is waiting for is a drain like any
    /// other, so a closer arriving meanwhile can see it.
    @Test func aReplacementOpenWaitsForThePreviousSessionToFinishClosing() async throws {
        let events = SignalledRecords<String>()
        let hold = ResumableGate()
        let previous = FakeSession(roundId: roundId, events: events, closeHold: hold)
        let replacement = FakeSession(roundId: roundId, events: events)
        let factory = FakeSessionFactory(sessions: [previous, replacement], events: events)
        let registry = makeFakeRegistry(factory)
        try await VotingSessionRegistryTests.open(registry, roundId)

        let roundId = self.roundId
        let reopening = Task {
            try await VotingSessionRegistryTests.open(registry, roundId)
        }
        await settle("the replacement open to start closing the previous session") { previous.isClosing }

        #expect(
            await registry.pendingDrainCount == 1,
            "the close a replacement open is waiting for must be owned by the registry, not just by that open"
        )
        #expect(
            await factory.calls == 1,
            "a replacement must not be built while the round's previous session is still closing"
        )

        hold.open()
        let reopened = try await reopening.value

        #expect(reopened === replacement)
        #expect(await factory.calls == 2)
        #expect(await registry.openRoundIds == [roundId], "exactly one live session for the round")
        #expect(await registry.pendingDrainCount == 0)

        let recorded = events.values
        let closed = try #require(recorded.firstIndex(of: "closed(\(roundId))"))
        let replacementBuilt = try #require(recorded.lastIndex(of: "building(\(roundId))"))
        #expect(closed < replacementBuilt, "the replacement must be built only after the previous close returned")
    }

    /// An open the SDK is still inside cannot be cancelled out of it -- the
    /// build is an FFI call that answers when it answers -- so a close abandons
    /// the attempt and waits for it. That wait belongs to the registry too: a
    /// drain that starts later has to see it, and has to see the session the
    /// abandoned attempt hands back on its way out.
    @Test func aPendingOpenCancelledByACloseIsSeenByALaterDrainAndNeverRegisters() async throws {
        let events = SignalledRecords<String>()
        let factoryHold = ResumableGate()
        let late = FakeSession(roundId: roundId, events: events)
        let factory = FakeSessionFactory(sessions: [late], hold: factoryHold, events: events)
        let registry = makeFakeRegistry(factory)
        let generationBefore = await registry.generation

        let roundId = self.roundId
        let opening = Task {
            try await VotingSessionRegistryTests.open(registry, roundId)
        }
        await settle("the open to reach the factory") { await factory.calls == 1 }

        let closing = Task { await registry.close(roundId) }
        let draining = Task {
            await registry.closeAll()
            events.record("closeAllReturned")
        }
        await settle("the drain to enter the registry") {
            await registry.generation == generationBefore + 1
        }

        #expect(
            !events.values.contains("closeAllReturned"),
            "a drain must not return while an abandoned open is still inside the SDK"
        )

        factoryHold.open()
        await closing.value
        await draining.value

        if case .success = await opening.result {
            Issue.record("an open abandoned by a close must not hand back a session")
        }
        #expect(await registry.openRoundIds.isEmpty, "the late result must never register")
        #expect(late.recorded.closesStarted == 1, "the session the factory answered with late must be closed")
        #expect(late.recorded.cancels >= 1)

        let recorded = events.values
        let closed = try #require(recorded.firstIndex(of: "closed(\(roundId))"))
        let closeAllReturned = try #require(recorded.firstIndex(of: "closeAllReturned"))
        #expect(
            closed < closeAllReturned,
            "the drain must outlast the close of the session the abandoned attempt produced"
        )
        #expect(await registry.pendingDrainCount == 0)
    }

    /// An open that never produced a session leaves nothing to wait for, and
    /// neither does one whose session was closed on its way out. Both have to
    /// settle back to a registry the next open can use, or the drain count would
    /// creep up and every later closer would wait on teardown that has finished.
    @Test func aRefusedOrCancelledOpenLeavesNoBookkeepingBehind() async throws {
        let events = SignalledRecords<String>()
        let afterRefusal = FakeSession(roundId: roundId, events: events)
        let refusing = FakeSessionFactory(sessions: [afterRefusal], refusals: 1, events: events)
        let refusingRegistry = makeFakeRegistry(refusing)
        let roundId = self.roundId

        await #expect(throws: FakeSessionFactory.Refusal.self) {
            _ = try await VotingSessionRegistryTests.open(refusingRegistry, roundId)
        }
        #expect(await refusingRegistry.pendingDrainCount == 0, "a refusal has nothing to wait for")
        #expect(await refusingRegistry.openRoundIds.isEmpty)

        let afterwards = try await VotingSessionRegistryTests.open(refusingRegistry, roundId)
        #expect(afterwards === afterRefusal, "the refusal must leave the round openable")

        // And the other way an open ends with nothing registered: the session
        // arrives after a teardown, so the attempt closes it instead of
        // registering it. That close is a drain, and `closeAll` is what waits
        // for it -- after which the registry is clean again.
        let hold = ResumableGate()
        let stranded = FakeSession(roundId: roundId, events: events)
        let later = FakeSession(roundId: roundId, events: events)
        let holding = FakeSessionFactory(sessions: [stranded, later], hold: hold, events: events)
        let holdingRegistry = makeFakeRegistry(holding)
        let generationBefore = await holdingRegistry.generation

        let cancelled = Task {
            try await VotingSessionRegistryTests.open(holdingRegistry, roundId)
        }
        await settle("the open to reach the factory") { await holding.calls == 1 }

        let draining = Task { await holdingRegistry.closeAll() }
        await settle("the drain to enter the registry") {
            await holdingRegistry.generation == generationBefore + 1
        }
        hold.open()
        await draining.value

        if case .success = await cancelled.result {
            Issue.record("an open that lost the teardown fence must not hand back a session")
        }
        #expect(stranded.recorded.closesStarted == 1, "the session it built anyway must be closed")
        #expect(await holdingRegistry.pendingDrainCount == 0)
        #expect(await holdingRegistry.openRoundIds.isEmpty)

        let reopened = try await VotingSessionRegistryTests.open(holdingRegistry, roundId)
        #expect(reopened === later, "the round must be openable once the teardown has finished")
    }

    /// Rounds are independent: the flow closes one when the voter leaves it
    /// while another is still running. Waiting for a close is per round, so a
    /// round that is quiet must not be held behind a round that is not.
    @Test func closingOneRoundDoesNotWaitForAnother() async throws {
        let events = SignalledRecords<String>()
        let hold = ResumableGate()
        let sessionA = FakeSession(roundId: "aaaa", events: events, closeHold: hold)
        let sessionB = FakeSession(roundId: "bbbb", events: events)
        let replacementB = FakeSession(roundId: "bbbb", events: events)
        let factory = FakeSessionFactory(sessions: [sessionA, sessionB, replacementB], events: events)
        let registry = makeFakeRegistry(factory)
        try await VotingSessionRegistryTests.open(registry, "aaaa")
        try await VotingSessionRegistryTests.open(registry, "bbbb")

        let closingA = Task { await registry.close("aaaa") }
        await settle("A's close to reach its session") { sessionA.isClosing }

        let closingB = Task {
            await registry.close("bbbb")
            events.record("closeBReturned")
        }
        await settle("B's close to finish while A is still closing") {
            events.values.contains("closeBReturned")
        }
        #expect(sessionA.isClosing, "A must still be closing -- that is what makes this a question")

        let reopenedB = try await VotingSessionRegistryTests.open(registry, "bbbb")
        #expect(reopenedB === replacementB, "B must be reopenable while A is still closing")
        #expect(await registry.openRoundIds == ["bbbb"])
        #expect(await registry.pendingDrainCount == 1, "only A's close is still running")

        hold.open()
        await closingA.value
        await closingB.value
        #expect(await registry.pendingDrainCount == 0)
    }

    /// The moment a close starts, the round is gone as far as callers are
    /// concerned: handing the session out afterwards would let a round-scoped
    /// call reach a session whose handle is being freed.
    @Test func aSessionThatIsClosingIsNoLongerHandedOut() async throws {
        let events = SignalledRecords<String>()
        let hold = ResumableGate()
        let session = FakeSession(roundId: roundId, events: events, closeHold: hold)
        let factory = FakeSessionFactory(sessions: [session], events: events)
        let registry = makeFakeRegistry(factory)
        try await VotingSessionRegistryTests.open(registry, roundId)

        let roundId = self.roundId
        let closing = Task { await registry.close(roundId) }
        await settle("the close to reach the session") { session.isClosing }

        await #expect(throws: VotingSessionError.notOpen(roundId: roundId)) {
            _ = try await registry.session(for: roundId)
        }
        #expect(await registry.openRoundIds.isEmpty)
        #expect(await registry.pendingDrainCount == 1)

        hold.open()
        await closing.value
        #expect(await registry.pendingDrainCount == 0)
    }

    /// Waits until `condition` holds, asking again whenever another task has had
    /// a turn.
    ///
    /// Not a sleep: the condition is read straight off the thing under test, so
    /// this returns the instant another task has made the progress being waited
    /// for, however long a loaded machine takes to get there. The race against
    /// the clock is only so a condition that never comes names itself instead of
    /// hanging the suite.
    private func settle(
        _ what: String,
        until condition: @escaping @Sendable () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let held = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await condition() {
                        return true
                    }
                    await Task.yield()
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !held {
            Issue.record("gave up waiting for \(what)", sourceLocation: sourceLocation)
        }
    }

    private func makeFakeRegistry(_ factory: FakeSessionFactory) -> VotingSessionRegistryCore<FakeSession> {
        VotingSessionRegistryCore<FakeSession> { inputs, binding, route, epoch in
            try await factory.make(inputs, binding, route, epoch)
        }
    }

    @discardableResult
    private static func open(
        _ registry: VotingSessionRegistryCore<FakeSession>,
        _ roundId: String
    ) async throws -> FakeSession {
        try await registry.open(
            inputs: VotingSessionRegistryTests.inputs(roundId: roundId),
            binding: VotingSessionBinding(roster: []),
            route: .direct,
            epoch: 0
        )
    }

    /// A registry whose factory is the app's own wiring — the synchronizer
    /// dependency's session factory — backed by the no-op client, which refuses
    /// rather than reaching the SDK.
    /// Waits for a staged handshake, bounded: a gate that never opens should
    /// name what it was waiting for rather than hang the suite until the runner
    /// gives up on it.
    private func wait(
        for gate: Gate,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let opened = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await gate.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !opened {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
        }
    }

    private func makeRegistry() -> VotingSessionRegistry {
        let synchronizer = SDKSynchronizerClient.noOp
        let backend = VotingRustBackend()

        return VotingSessionRegistry { inputs, binding, route, epoch in
            try await synchronizer.makeVotingRoundSession(backend, inputs, binding, route, epoch)
        }
    }

    private static func inputs(roundId: String) -> VotingSessionInputs {
        VotingSessionInputs(
            accountUUID: "11111111-1111-1111-1111-111111111111",
            walletDbPath: "/dev/null",
            roundParams: VotingRoundParameters(
                voteRoundId: roundId,
                snapshotHeight: 4_200_000,
                eaPk: Data(repeating: 0x01, count: 32),
                ncRoot: Data(repeating: 0x02, count: 32),
                nullifierImtRoot: Data(repeating: 0x03, count: 32)
            ),
            roundName: "registry test round",
            anchorTreeState: Data(),
            chainEndpoints: [],
            voteTreeNodeUrls: [],
            helperUrls: [],
            pirEndpoints: [],
            pirLayout: VotingPirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 2048)
        )
    }
}

/// A one-shot gate two tasks meet at.
///
/// ``open()`` resumes everything waiting and makes every later ``wait()``
/// return at once. A waiter whose task is cancelled stops waiting instead of
/// hanging on a gate nothing is going to open — which is how a held call
/// finishes when the thing that cancels it is the subject of the test.
private actor Gate {
    private var isOpen = false
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterId: UInt64 = 0

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for continuation in resuming.values {
            continuation.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        nextWaiterId &+= 1
        let waiterId = nextWaiterId
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isOpen, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[waiterId] = continuation
            }
        } onCancel: {
            Task { await self.giveUp(waiterId) }
        }
    }

    private func giveUp(_ waiterId: UInt64) {
        waiters.removeValue(forKey: waiterId)?.resume()
    }
}

/// A factory that stops inside the open and then refuses.
///
/// The races these tests are about only exist across the suspension between an
/// open being registered and its session arriving, so the factory holds that
/// suspension open on an explicit handshake rather than on a sleep: `entered`
/// opens once a call is inside, and the call returns only once `released` is
/// opened or the open is cancelled. It refuses because a real
/// ``VotingRoundSession`` can only be made by the SDK.
private actor SlowFactory {
    struct Refusal: Error, Equatable {}

    /// Opened by the factory when a call is inside it.
    let entered = Gate()
    /// Opened by the test to let the calls inside the factory finish.
    let released = Gate()

    private(set) var calls = 0

    func make(
        _ inputs: VotingSessionInputs,
        _ binding: VotingSessionBinding,
        _ route: VotingTransportRoute,
        _ epoch: UInt64
    ) async throws -> VotingRoundSession {
        calls += 1
        await entered.open()
        await released.wait()
        throw Refusal()
    }
}

/// A session these tests own.
///
/// A ``VotingRoundSession`` can only be made by the SDK (see the file comment),
/// which is why the registry is generic over ``VotingRegistrySession``: this is
/// the other conformer. Its ``close()`` parks on a gate the test opens, so
/// "what does the registry do while this session is still closing?" can be
/// asked at all, and every call it takes goes into a shared log so the order
/// things happened in can be read back afterwards.
private final class FakeSession: VotingRegistrySession, @unchecked Sendable {
    struct Counts: Sendable {
        var cancels = 0
        var closesStarted = 0
        var closesFinished = 0
    }

    let roundId: String

    /// Held shut until a test opens it; `nil` closes straight through.
    private let closeHold: ResumableGate?
    private let events: SignalledRecords<String>
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    /// Inside ``close()`` and not out of it yet — what every "while it is still
    /// closing" handshake in this file waits for.
    var isClosing: Bool {
        counts.withLock { $0.closesStarted > $0.closesFinished }
    }

    var recorded: Counts {
        counts.withLock { $0 }
    }

    init(roundId: String, events: SignalledRecords<String>, closeHold: ResumableGate? = nil) {
        self.roundId = roundId
        self.events = events
        self.closeHold = closeHold
    }

    func cancel() {
        counts.withLock { $0.cancels += 1 }
        events.record("cancelled(\(roundId))")
    }

    func close() async {
        counts.withLock { $0.closesStarted += 1 }
        events.record("closing(\(roundId))")
        if let closeHold {
            await closeHold.wait()
        }
        counts.withLock { $0.closesFinished += 1 }
        events.record("closed(\(roundId))")
    }

    func setOperationEpoch(_ epoch: UInt64) {
        events.record("epoch(\(roundId))")
    }

    func updateHostConfiguration(_ overrides: VotingHostOverrides) throws {
        events.record("hostConfiguration(\(roundId))")
    }
}

/// A factory that answers with the sessions a test made.
///
/// Sessions are queued per round, so a replacement open gets a new one and a
/// test can tell them apart. `hold` stops a call inside the factory the way the
/// SDK's own build stops inside an FFI call: it does not answer cancellation,
/// which is what makes "the result that arrives late is closed and never
/// registers" a real question rather than something cancellation shortcuts.
private actor FakeSessionFactory {
    struct Refusal: Error, Equatable {}
    struct Exhausted: Error, Equatable {}

    private var queued: [String: [FakeSession]]
    private var refusals: Int
    private let hold: ResumableGate?
    private let events: SignalledRecords<String>

    private(set) var calls = 0

    init(
        sessions: [FakeSession] = [],
        refusals: Int = 0,
        hold: ResumableGate? = nil,
        events: SignalledRecords<String>
    ) {
        var queued: [String: [FakeSession]] = [:]
        for session in sessions {
            queued[session.roundId.lowercased(), default: []].append(session)
        }
        self.queued = queued
        self.refusals = refusals
        self.hold = hold
        self.events = events
    }

    func make(
        _ inputs: VotingSessionInputs,
        _ binding: VotingSessionBinding,
        _ route: VotingTransportRoute,
        _ epoch: UInt64
    ) async throws -> FakeSession {
        calls += 1
        let key = inputs.roundParams.voteRoundId.lowercased()
        events.record("building(\(key))")
        if let hold {
            await hold.wait()
        }
        events.record("built(\(key))")

        if refusals > 0 {
            refusals -= 1
            throw Refusal()
        }

        guard var waiting = queued[key], !waiting.isEmpty else {
            throw Exhausted()
        }
        let session = waiting.removeFirst()
        queued[key] = waiting

        return session
    }
}
#endif
