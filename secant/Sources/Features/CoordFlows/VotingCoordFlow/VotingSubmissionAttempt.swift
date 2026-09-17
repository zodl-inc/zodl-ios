#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import os

/// Ephemeral diagnostics shared by the effects of one automated attempt. Effect captures refer
/// to this identity, never to whatever attempt later occupies the same round's cache entry.
final class VotingSubmissionAttempt: Sendable, Equatable {
    enum Phase: String, CaseIterable, Sendable {
        case preparation, delegation, votes, sharesJoin
    }

    enum Outcome: String, Sendable {
        case completed, partial, failed, cancelled
    }

    enum Path: String, Sendable {
        case software, keystone
    }

    enum Scope: String, Sendable {
        case submission = "automatedSubmission"
        case delegation = "automatedDelegation"
    }

    struct Snapshot: Equatable, Sendable {
        var preparationMs: Int64 = 0
        var delegationMs: Int64 = 0
        var votesMs: Int64 = 0
        var sharesJoinMs: Int64 = 0
        var totalMs: Int64 = 0
        var outcome: Outcome?
    }

    private struct TimingState: Sendable {
        let started: ContinuousClock.Instant
        var phaseStarted: ContinuousClock.Instant
        var phase: Phase = .preparation
        var elapsed: [Phase: Duration] = [:]
        var terminal: Snapshot?
    }

    let id = UUID()
    let scope: Scope
    private let client: VotingSubmissionTimingClient
    private let context: String
    private let state: OSAllocatedUnfairLock<TimingState>

    var isFinished: Bool { state.withLock { $0.terminal != nil } }

    init(roundId: String, path: Path, scope: Scope = .submission, prepared: Bool, client: VotingSubmissionTimingClient) {
        self.scope = scope
        self.client = client
        context = "\(VotingSubmissionTrace.context(roundId: roundId)) path=\(path.rawValue) preparedAtStart=\(prepared)"
        let started = client.now()
        state = OSAllocatedUnfairLock(initialState: TimingState(started: started, phaseStarted: started))
    }

    func enter(_ phase: Phase) {
        state.withLock {
            guard $0.terminal == nil, $0.phase != phase else { return }
            let now = client.now()
            $0.elapsed[$0.phase, default: .zero] += now - $0.phaseStarted
            $0.phaseStarted = now
            $0.phase = phase
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { $0.terminal ?? Self.snapshot($0, at: client.now()) }
    }

    private static func snapshot(_ state: TimingState, at now: ContinuousClock.Instant) -> Snapshot {
        var elapsed = state.elapsed
        elapsed[state.phase, default: .zero] += now - state.phaseStarted
        func milliseconds(_ phase: Phase) -> Int64 {
            let duration = elapsed[phase, default: .zero]
            return duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
        return Snapshot(
            preparationMs: milliseconds(.preparation),
            delegationMs: milliseconds(.delegation),
            votesMs: milliseconds(.votes),
            sharesJoinMs: milliseconds(.sharesJoin),
            totalMs: VotingSubmissionTrace.milliseconds(since: state.started, until: now)
        )
    }

    func finish(error: Error) {
        finish(error is CancellationError || Task.isCancelled ? .cancelled : .failed)
    }

    func finishIfCancelled() {
        if Task.isCancelled { finish(.cancelled) }
    }

    func finishStandaloneDelegation() {
        if scope == .delegation { finish(.completed) }
    }

    func finish(_ outcome: Outcome) {
        let terminal = state.withLock { state -> Snapshot? in
            guard state.terminal == nil else { return nil }
            var snapshot = Self.snapshot(state, at: client.now())
            snapshot.outcome = outcome
            state.terminal = snapshot
            return snapshot
        }
        guard let terminal else { return }
        client.sink(
            """
            Voting automated attempt summary \(context) attempt=\(id.uuidString) scope=\(scope.rawValue) \
            outcome=\(outcome.rawValue) preparationMs=\(terminal.preparationMs) delegationMs=\(terminal.delegationMs) \
            votesMs=\(terminal.votesMs) sharesJoinMs=\(terminal.sharesJoinMs) totalMs=\(terminal.totalMs)
            """
        )
    }

    static func == (lhs: VotingSubmissionAttempt, rhs: VotingSubmissionAttempt) -> Bool {
        lhs.id == rhs.id
    }
}

struct VotingSubmissionTimingClient: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sink: VotingSubmissionTrace.Sink
}

extension VotingSubmissionTimingClient: DependencyKey {
    static let liveValue = VotingSubmissionTimingClient(now: { ContinuousClock().now }, sink: VotingSubmissionTrace.info)
    static let testValue = VotingSubmissionTimingClient(now: { ContinuousClock().now }, sink: { _ in })
}

extension DependencyValues {
    var votingSubmissionTiming: VotingSubmissionTimingClient {
        get { self[VotingSubmissionTimingClient.self] }
        set { self[VotingSubmissionTimingClient.self] = newValue }
    }
}
#endif
