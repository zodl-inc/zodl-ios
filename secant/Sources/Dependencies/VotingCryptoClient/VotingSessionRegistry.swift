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
/// call against it. This actor is where that one lives, which makes two
/// guarantees the call sites would otherwise each have to make: a round never
/// has two sessions at once, and a session is always closed before it is
/// dropped.
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

    private let makeSession: Factory
    private var sessions: [String: VotingRoundSession] = [:]

    /// How many times the registry has been invalidated wholesale.
    ///
    /// A caller that started work against the sessions this registry held can
    /// compare the generation it captured with this one and drop an answer that
    /// arrives after everything was torn down — a wallet switch, say, or the
    /// flow being left.
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
    @discardableResult
    func open(
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        route: VotingTransportRoute,
        epoch: UInt64
    ) async throws -> VotingRoundSession {
        let roundId = VotingSessionRegistry.key(inputs.roundParams.voteRoundId)
        await close(roundId)

        let session = try await makeSession(inputs, binding, route, epoch)
        sessions[VotingSessionRegistry.key(session.roundId)] = session

        return session
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
    /// driver reached quiescence on its own. Closing a round that has no session
    /// does nothing.
    func close(_ roundId: String) async {
        guard let session = sessions.removeValue(forKey: VotingSessionRegistry.key(roundId)) else { return }

        session.cancel()
        await session.close()
    }

    /// Close every open session and move the generation on.
    func closeAll() async {
        let open = sessions
        sessions.removeAll()
        invalidate()

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
    /// session does nothing.
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

    /// Round ids are canonical lowercase hex on the SDK side, so lookups are
    /// normalised the same way rather than trusting every call site to have the
    /// case the session was opened with.
    private static func key(_ roundId: String) -> String {
        roundId.lowercased()
    }
}
#endif
