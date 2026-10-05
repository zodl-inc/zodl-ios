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

/// What the registry needs from a round session: enough to stop it, close it
/// and keep it current.
///
/// The SDK's ``VotingRoundSession`` is the only production conformer, and the
/// only thing that could be one — the call that builds a session is internal to
/// the SDK, so nothing here can make another. The registry is generic over this
/// protocol rather than over that class so its close ordering can be exercised
/// against a session whose `close()` is held open, which is the only way to ask
/// what a second closer does while a first one is still joining the calls a
/// session has in flight.
protocol VotingRegistrySession: AnyObject, Sendable {
    var roundId: String { get }

    func cancel()
    func close() async
    func setOperationEpoch(_ epoch: UInt64)
    func updateHostConfiguration(_ overrides: VotingHostOverrides) throws
}

extension VotingRoundSession: VotingRegistrySession {}

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
/// Opening is single-flight per round, for the opens that want the same
/// session. Building a session suspends twice — closing the round's previous
/// session, then the SDK call itself — and an actor lets other work run across
/// a suspension, so two concurrent opens for one round would otherwise each
/// find nothing, each build a session, and the second would overwrite the
/// first: two drivers contending for the round's rows, one of them unreachable
/// and never closed. So the first open registers its attempt before it
/// suspends, and a later opener awaits that attempt instead of starting its
/// own — as long as it is asking for the same session. One that asks for a
/// different binding, route or epoch supersedes the attempt instead of joining
/// it, because the session being built is not the one it could use, and then
/// waits for whatever that attempt still comes back with to be closed before it
/// builds — which is how a round stays on one session across a supersede too;
/// see ``open(inputs:binding:route:epoch:)``.
///
/// Teardown is owned rather than awaited in place. Closing takes the session
/// off the books at once and leaves a *drain* behind — the task cancelling and
/// closing it — which stays here until it has finished. Closers overlap by
/// design: the flow gives its sessions back while the wallet reset is closing
/// the store, rather than making the reset wait for the flow to notice. So a
/// closer that finds nothing left to remove still waits for the drains that are
/// running, and an open replacing a session waits for that round's drains
/// before it builds. That is what keeps the last two guarantees honest under an
/// overlap: returning from a close means the session is closed, not merely
/// forgotten, so the store can be closed and its file removed behind it.
///
/// An actor rather than a lock because closing a session suspends (it waits for
/// the calls still in flight), and because nothing here is on a hot path.
///
/// The factory is injected rather than reached for. The SDK builds a session
/// through the synchronizer, which owns the Tor runtime a `.tor` route needs;
/// taking that as a closure keeps this type free of the dependency graph and
/// lets a test drive the bookkeeping without a live sidecar.
actor VotingSessionRegistryCore<Session: VotingRegistrySession> {
    typealias Factory = @Sendable (
        _ inputs: VotingSessionInputs,
        _ binding: VotingSessionBinding,
        _ route: VotingTransportRoute,
        _ epoch: UInt64
    ) async throws -> Session

    /// One open in flight, with what it was asked for. A second caller joins
    /// it only when it asks for the same session; the id tells an attempt
    /// apart from the one that replaced it, so a finishing open only ever
    /// clears its own entry.
    private struct OpenAttempt {
        let id: UInt64
        let binding: VotingSessionBinding
        let route: VotingTransportRoute
        let epoch: UInt64
        let task: Task<Session, Error>

        func isCompatible(binding: VotingSessionBinding, route: VotingTransportRoute, epoch: UInt64) -> Bool {
            self.binding == binding && self.route == route && self.epoch == epoch
        }
    }

    /// One piece of teardown still running: a session being closed, or an
    /// abandoned open being waited out.
    ///
    /// It stays here until it has finished, so every closer can see it and wait
    /// for it, not only the one that started it.
    private struct Drain {
        let key: String
        let task: Task<Void, Never>
    }

    private let makeSession: Factory
    private var sessions: [String: Session] = [:]
    private var opening: [String: OpenAttempt] = [:]
    private var drains: [UInt64: Drain] = [:]
    private var nextAttemptId: UInt64 = 0
    private var nextDrainId: UInt64 = 0

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

    /// How many closes and abandoned opens have not finished yet, for tests and
    /// diagnostics. Zero means nothing this registry owns is still winding down.
    var pendingDrainCount: Int {
        drains.count
    }

    /// How many callers are waiting on an attempt another caller started, for
    /// tests and diagnostics. Counted before the wait begins, so a test that
    /// holds an attempt's factory shut can know a second caller has joined it
    /// rather than guess from the order two tasks happened to run in.
    private(set) var joinedOpenCount = 0

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
    /// it when it asks for the same session — the same binding, route and epoch:
    /// both callers get the one session, or both get the one error. Callers for
    /// different rounds do not wait for each other.
    ///
    /// A call that asks for anything else supersedes that attempt rather than
    /// joining it. The two callers do not want the same session: the round's
    /// share recovery opens with a roster-only binding while the voter's own
    /// entry carries the voting hotkey, and a voter handed the recovery session
    /// would have a round that says it can vote and a session that fails every
    /// cast for a key it never had. The same goes for a route, which a session
    /// fixes for its whole life, and for the submission epoch. So the attempt is
    /// abandoned — cancelled, with the wait for it left behind as a drain — and
    /// this open builds what its caller asked for. The abandoned attempt's own
    /// fences close any session it still produces, all the way, before this open
    /// builds: nothing of it registers, and the round is never on two sessions
    /// at once.
    ///
    /// A caller that had joined the abandoned attempt shares its outcome to the
    /// end, so it is told the round is not open rather than handed a session. It
    /// is left holding nothing by that: an open hands its session back, but a
    /// caller here reads the round's session through ``session(for:)`` when it
    /// needs it, so what such a caller loses is its own open — and the session
    /// the round ends up on is the one the superseding caller asked for.
    ///
    /// Nothing waits in a circle across that. ``abandonOpen(_:)`` registers the
    /// drain before this open creates its attempt, so the new attempt inherits
    /// that drain in its snapshot and waits for it, the drain waits for the
    /// abandoned attempt, and the abandoned attempt waits for one thing only:
    /// the close of the session it built anyway, which waits on the session and
    /// never on an open. It waits for nothing else — it took its own snapshot
    /// before the abandoning drain existed, or it never started, in which case
    /// it is already cancelled and leaves at its first fence. The waiting runs
    /// one way.
    @discardableResult
    func open(
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        route: VotingTransportRoute,
        epoch: UInt64
    ) async throws -> Session {
        let roundId = Self.key(inputs.roundParams.voteRoundId)

        if let inFlight = opening[roundId] {
            if inFlight.isCompatible(binding: binding, route: route, epoch: epoch) {
                joinedOpenCount += 1
                defer { joinedOpenCount -= 1 }
                return try await inFlight.task.value
            }

            abandonOpen(roundId)
        }

        // Registered before the first suspension below, so a concurrent open
        // for this round finds it rather than starting a second one.
        nextAttemptId &+= 1
        let attempt = OpenAttempt(
            id: nextAttemptId,
            binding: binding,
            route: route,
            epoch: epoch,
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
    func session(for roundId: String) throws -> Session {
        guard let session = sessions[Self.key(roundId)] else {
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
    /// register behind the close. Closing a round that has neither does nothing
    /// — except wait for a close of this round somebody else started, which is
    /// still a close this caller is entitled to see through.
    ///
    /// Only this round: a round quiet enough to close is not held behind one
    /// that is not.
    func close(_ roundId: String) async {
        let key = Self.key(roundId)
        abandonOpen(key)
        closeSession(key)

        await awaitDrains(of: key)
    }

    /// Close every open session and move the generation on.
    ///
    /// The generation moves before anything is awaited, so an open already in
    /// flight sees it when the SDK answers and closes its own session rather
    /// than registering it here. The same is true of the removals: this takes
    /// everything off the books before it suspends, and only then waits.
    ///
    /// Returning means every session is closed, not merely that the books are
    /// empty — including the ones another caller was already closing and the one
    /// an open in flight hands back on its way out. That is what the sidecar's
    /// store relies on before it closes and its file is removed. Every session
    /// of the generation this ends, that is: an open that *starts* after the
    /// prologue below captures the new generation, so it is neither abandoned
    /// here nor waited for, and it registers a session of its own. Keeping that
    /// from happening is the teardown window's job rather than this one's.
    func closeAll() async {
        invalidate()

        for key in Array(opening.keys) {
            abandonOpen(key)
        }
        for key in Array(sessions.keys) {
            closeSession(key)
        }

        await awaitDrains(of: nil)
    }

    /// Stop the bounded passes the round's session is driving, keeping the
    /// session itself.
    ///
    /// Permanent for that session — the SDK's cancellation is not a pause — so a
    /// round cancelled here is reopened rather than resumed. A round with no
    /// session does nothing; an open still in flight is left alone, because a
    /// session that does not exist yet has nothing to stop.
    func cancel(_ roundId: String) {
        sessions[Self.key(roundId)]?.cancel()
    }

    /// Move the round's submission epoch, invalidating passes that captured an
    /// older one. A round with no session does nothing.
    func setEpoch(_ roundId: String, _ epoch: UInt64) {
        sessions[Self.key(roundId)]?.setOperationEpoch(epoch)
    }

    /// Push a refreshed service configuration into every open session. A
    /// session that closed meanwhile refuses it, which is fine: the next open
    /// builds its inputs from the refreshed configuration anyway.
    func updateHostConfiguration(_ overrides: VotingHostOverrides) {
        for session in sessions.values {
            do {
                try session.updateHostConfiguration(overrides)
            } catch {
                LoggerProxy.debug("Voting: a round session refused a host configuration update: \(error)")
            }
        }
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
    ) async throws -> Session {
        let generationAtStart = generation

        // An attempt abandoned before it ever ran is cancelled by the time it
        // gets here, and the drain that abandoned it is waiting for exactly this
        // task. Leaving now is what lets that drain finish.
        guard !Task.isCancelled else {
            throw VotingSessionError.notOpen(roundId: roundId)
        }

        closeSession(roundId)

        // Only the drains of this round that exist right now, and deliberately
        // no second look for later ones: a drain registered after this point may
        // be the one abandoning this very attempt — it cancels the attempt and
        // then waits for it — and an attempt waiting for its own abandonment
        // would never finish. The cancellation such a drain delivers is what
        // stops this attempt instead, at the fences below.
        let inherited = drains.values.filter { $0.key == roundId }.map(\.task)
        for task in inherited {
            await task.value
        }

        guard generation == generationAtStart, !Task.isCancelled else {
            throw VotingSessionError.notOpen(roundId: roundId)
        }

        let session = try await makeSession(inputs, binding, route, epoch)

        // The registry may have been torn down, or this round closed, while the
        // SDK was building. Registering now would leave a live session behind a
        // closed store, so the session this attempt made is closed and the
        // caller told the round is not open. That close is a drain of its own,
        // so a teardown still waiting sees it rather than returning in front of
        // a session it never knew about.
        //
        // And this attempt waits for it before it leaves. An open that
        // superseded this one is waiting for this task, through the drain that
        // gave this one up, and the session it is about to build is for the same
        // round: finishing here while this one is still closing would leave two
        // sessions on the round, contending for its rows in the sidecar. The
        // wait cannot close a cycle — this drain waits on the session's own
        // close and on nothing else, never on an open — so the chain runs one
        // way: the superseding attempt, the drain that gave this one up, this
        // attempt, this close, done.
        guard generation == generationAtStart, !Task.isCancelled else {
            let closing = startDrain(roundId) {
                session.cancel()
                await session.close()
            }
            await closing.value
            throw VotingSessionError.notOpen(roundId: roundId)
        }

        sessions[Self.key(session.roundId)] = session
        return session
    }

    /// Cancel an open still building a session for `key` and leave the wait for
    /// it behind as a drain, so nothing registers after the caller has decided
    /// the round is closed — or that the session being built is not the one the
    /// round should have — and so a closer that arrives later waits for the
    /// attempt too.
    ///
    /// Removing and cancelling happen here, before the drain is registered and
    /// before anything suspends: an attempt that has not started yet would
    /// otherwise find this drain in its own snapshot and wait for a drain that
    /// is waiting for it. It is also what lets the open that supersedes an
    /// attempt inherit this drain — the entry is gone and the drain is there by
    /// the time that open registers an attempt of its own.
    private func abandonOpen(_ key: String) {
        guard let attempt = opening.removeValue(forKey: key) else { return }

        let task = attempt.task
        task.cancel()
        startDrain(key) {
            _ = try? await task.value
        }
    }

    /// Take the round's registered session off the books and leave its close
    /// running as a drain. Does not touch an open in flight — the attempt that
    /// calls this is the open in flight.
    private func closeSession(_ key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }

        startDrain(key) {
            session.cancel()
            await session.close()
        }
    }

    /// Registers `work` as a drain of `key` before anything suspends, so the
    /// very next caller into the actor already sees it, and hands back the task
    /// running it — for the one caller that has to wait for this piece of
    /// teardown by itself rather than through ``awaitDrains(of:)``.
    @discardableResult
    private func startDrain(_ key: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        nextDrainId &+= 1
        let id = nextDrainId
        let task = Task { [weak self] in
            await work()
            await self?.finishDrain(id)
        }
        drains[id] = Drain(key: key, task: task)

        return task
    }

    private func finishDrain(_ id: UInt64) {
        drains[id] = nil
    }

    /// Waits until no drain of `key` — every round when `nil` — is left,
    /// including ones registered while this was waiting.
    ///
    /// The re-read is the point: a drain can hand off to another (an abandoned
    /// open produces a session that then has to be closed), and a closer that
    /// stopped at the first batch would return in front of the second.
    private func awaitDrains(of key: String?) async {
        while true {
            let pending = drains.values.filter { key == nil || $0.key == key }
            guard !pending.isEmpty else { return }

            for drain in pending {
                await drain.task.value
            }
        }
    }

    /// Round ids are canonical lowercase hex on the SDK side, so lookups are
    /// normalised the same way rather than trusting every call site to have the
    /// case the session was opened with.
    private static func key(_ roundId: String) -> String {
        roundId.lowercased()
    }
}

/// The registry the app runs on: the one over the SDK's session.
typealias VotingSessionRegistry = VotingSessionRegistryCore<VotingRoundSession>
#endif
