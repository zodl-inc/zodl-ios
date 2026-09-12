#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// The registry's bookkeeping, exercised without a live session.
///
/// A `VotingRoundSession` can only be made by the SDK — the backend call that
/// builds one is internal to it — so the registry takes its factory as an
/// injected closure and these tests give it one that refuses. That covers every
/// path that does not need a session in hand: the empty registry, a refused
/// open, and the two teardown calls.
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
#endif
