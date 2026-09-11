#if VOTING_ENABLED
import Foundation
@preconcurrency import ZcashLightClientKit

/// Why a round-scoped call could not find its session.
enum VotingSessionError: Error, Equatable {
    /// No session is open for this round. Open one before calling anything
    /// round-scoped: the session is where a round's plan, bundles, proofs and
    /// driver live, and there is nothing to answer from without it.
    case notOpen(roundId: String)
}

/// The app's open voting round sessions, one per round.
///
/// A ``VotingRoundSession`` is the round's whole working life on the SDK side
/// and is expensive to make — it opens the sidecar and fixes the transport
/// route for good — so the flow opens one and then makes every round-scoped
/// call against it. This actor is where that one lives, which makes three
/// guarantees the call sites would otherwise each have to make: a round never
/// has two sessions at once, a session is always closed before it is dropped,
/// and a session never outlives the store it persists to.
///
/// Opening is single-flight. Building a session suspends twice — closing the
/// round's previous session, then the SDK call itself — and an actor lets other
/// work run across a suspension, so two concurrent opens for one round would
/// otherwise each find nothing, each build a session, and the second would
/// overwrite the first: two drivers contending for the round's rows, one of
/// them unreachable and never closed. So the first open registers its attempt
/// before it suspends and later openers await that attempt instead of starting
/// their own.
///
/// An actor rather than a lock because closing a session suspends (it waits for
/// the calls still in flight), and because nothing here is on a hot path.
///
/// The factory is injected rather than reached for. The SDK builds a session
/// through the synchronizer, which owns the Tor runtime a `.tor` route needs;
/// taking that as a closure keeps this type free of the dependency graph and
/// lets a test drive the bookkeeping without a live sidecar.
actor VotingSessionRegistry {
    typealias Factory = @Sendable (
        _ inputs: VotingSessionInputs,
        _ binding: VotingSessionBinding,
        _ route: VotingTransportRoute,
        _ epoch: UInt64
    ) async throws -> VotingRoundSession

    /// One open in flight. The id tells an attempt apart from the one that
    /// replaced it, so a finishing open only ever clears its own entry.
    private struct OpenAttempt {
        let id: UInt64
        let task: Task<VotingRoundSession, Error>
    }

    private let makeSession: Factory
    private var sessions: [String: VotingRoundSession] = [:]
    private var opening: [String: OpenAttempt] = [:]
    private var nextAttemptId: UInt64 = 0

    /// How many times the registry has been invalidated wholesale.
    ///
    /// A caller that started work against the sessions this registry held can
    /// compare the generation it captured with this one and drop an answer that
    /// arrives after everything was torn down — a wallet switch, say, or the
    /// flow being left. An open in flight across such a teardown compares it
    /// too, and refuses rather than registering a session nobody asked for any
    /// more.
    private(set) var generation: UInt64 = 0

    /// The rounds with an open session, for tests and diagnostics.
    var openRoundIds: [String] {
        Array(sessions.keys)
    }

    init(makeSession: @escaping Factory) {
        self.makeSession = makeSession
    }

    /// Open a session for `inputs`' round, replacing any session it already has.
    ///
    /// The old session is closed first, and closed fully: two sessions on one
    /// round would contend for its rows in the sidecar. A factory that refuses
    /// leaves the registry as it was, with no session for the round, so the
    /// caller sees its own error rather than a half-opened round.
    ///
    /// A second call for the same round while the first is still building joins
    /// it: both callers get the one session, or both get the one error. Callers
    /// for different rounds do not wait for each other.
    @discardableResult
    func open(
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        route: VotingTransportRoute,
        epoch: UInt64
    ) async throws -> VotingRoundSession {
        let roundId = VotingSessionRegistry.key(inputs.roundParams.voteRoundId)

        if let inFlight = opening[roundId] {
            return try await inFlight.task.value
        }

        // Registered before the first suspension below, so a concurrent open
        // for this round finds it rather than starting a second one.
        nextAttemptId &+= 1
        let attempt = OpenAttempt(
            id: nextAttemptId,
            task: Task { [weak self] in
                guard let self else {
                    throw VotingSessionError.notOpen(roundId: roundId)
                }

                return try await self.performOpen(
                    roundId: roundId,
                    inputs: inputs,
                    binding: binding,
                    route: route,
                    epoch: epoch
                )
            }
        )
        opening[roundId] = attempt
        defer {
            if opening[roundId]?.id == attempt.id {
                opening[roundId] = nil
            }
        }

        return try await attempt.task.value
    }

    /// The open session for `roundId`, or ``VotingSessionError/notOpen(roundId:)``.
    func session(for roundId: String) throws -> VotingRoundSession {
        guard let session = sessions[VotingSessionRegistry.key(roundId)] else {
            throw VotingSessionError.notOpen(roundId: roundId)
        }

        return session
    }

    /// Cancel and close the session for `roundId`, and forget it.
    ///
    /// Cancelling first stops a run that is still driving the round before the
    /// close waits on it; without that, closing a live run would block until the
    /// driver reached quiescence on its own. An open still building a session
    /// for this round is cancelled and waited for as well, so nothing can
    /// register behind the close. Closing a round that has neither does nothing.
    func close(_ roundId: String) async {
        await abandonOpen(VotingSessionRegistry.key(roundId))
        await closeSession(VotingSessionRegistry.key(roundId))
    }

    /// Close every open session and move the generation on.
    ///
    /// The generation moves before anything is awaited, so an open already in
    /// flight sees it when the SDK answers and closes its own session rather
    /// than registering it here.
    func closeAll() async {
        let inFlight = opening
        let open = sessions
        opening.removeAll()
        sessions.removeAll()
        invalidate()

        for attempt in inFlight.values {
            attempt.task.cancel()
        }
        for attempt in inFlight.values {
            _ = try? await attempt.task.value
        }
        for session in open.values {
            session.cancel()
            await session.close()
        }
    }

    /// Stop the bounded passes the round's session is driving, keeping the
    /// session itself.
    ///
    /// Permanent for that session — the SDK's cancellation is not a pause — so a
    /// round cancelled here is reopened rather than resumed. A round with no
    /// session does nothing; an open still in flight is left alone, because a
    /// session that does not exist yet has nothing to stop.
    func cancel(_ roundId: String) {
        sessions[VotingSessionRegistry.key(roundId)]?.cancel()
    }

    /// Move the round's submission epoch, invalidating passes that captured an
    /// older one. A round with no session does nothing.
    func setEpoch(_ roundId: String, _ epoch: UInt64) {
        sessions[VotingSessionRegistry.key(roundId)]?.setOperationEpoch(epoch)
    }

    /// Fence everything started against the sessions held so far.
    func invalidate() {
        generation &+= 1
    }

    /// The body of one open attempt, run on that attempt's task.
    private func performOpen(
        roundId: String,
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        route: VotingTransportRoute,
        epoch: UInt64
    ) async throws -> VotingRoundSession {
        await closeSession(roundId)
        let generationAtStart = generation

        let session = try await makeSession(inputs, binding, route, epoch)

        // The registry may have been torn down, or this round closed, while the
        // SDK was building. Registering now would leave a live session behind a
        // closed store, so the session this attempt made is closed and the
        // caller told the round is not open.
        guard generation == generationAtStart, !Task.isCancelled else {
            session.cancel()
            await session.close()
            throw VotingSessionError.notOpen(roundId: roundId)
        }

        sessions[VotingSessionRegistry.key(session.roundId)] = session
        return session
    }

    /// Cancel an open still building a session for `key` and wait for it to
    /// finish, so nothing registers after the caller has decided the round is
    /// closed.
    private func abandonOpen(_ key: String) async {
        guard let attempt = opening.removeValue(forKey: key) else { return }

        attempt.task.cancel()
        _ = try? await attempt.task.value
    }

    /// Close the round's registered session, if it has one. Does not touch an
    /// open in flight — the attempt that calls this is the open in flight.
    private func closeSession(_ key: String) async {
        guard let session = sessions.removeValue(forKey: key) else { return }

        session.cancel()
        await session.close()
    }

    /// Round ids are canonical lowercase hex on the SDK side, so lookups are
    /// normalised the same way rather than trusting every call site to have the
    /// case the session was opened with.
    private static func key(_ roundId: String) -> String {
        roundId.lowercased()
    }
}
#endif
