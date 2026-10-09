#if VOTING_ENABLED
import Foundation
import os
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

/// A session these tests own.
///
/// A ``VotingRoundSession`` can only be made by the SDK, which is why the
/// registry is generic over ``VotingRegistrySession``: this is the other
/// conformer. Its ``close()`` parks on a gate the test opens, so "what does the
/// registry do while this session is still closing?" can be asked at all, and
/// every call it takes goes into a shared log so the order things happened in
/// can be read back afterwards.
///
/// Shared rather than private to the registry's own tests, because the question
/// the registry answers -- which of two overlapping opens a round ends up on --
/// is also a question about what the voting flow is left holding, and the suite
/// that drives the flow has to build the same registry over the same sessions
/// to ask it.
final class FakeSession: VotingRegistrySession, @unchecked Sendable {
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
    /// closing" handshake waits for.
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
actor FakeSessionFactory {
    struct Refusal: Error, Equatable {}
    struct Exhausted: Error, Equatable {}

    private var queued: [String: [FakeSession]]
    private var refusals: Int
    private let hold: ResumableGate?
    private let events: SignalledRecords<String>

    private(set) var calls = 0

    /// Which kind of session a binding asks for. Share recovery binds no
    /// hotkey and the voter's own entry does, and a session built for one
    /// cannot do the other's work -- so this is the difference a test staging
    /// two overlapping opens has to be able to read back.
    static func kind(of binding: VotingSessionBinding) -> String {
        binding.hotkeySecret == nil ? "sharesOnly" : "voting"
    }

    /// What one build asked for, as a single event, so the recorded history
    /// says which open a build belongs to rather than only which round.
    static func building(_ roundId: String, _ kind: String, epoch: UInt64) -> String {
        "building(\(roundId)|\(kind)|\(epoch))"
    }

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
        events.record(Self.building(key, Self.kind(of: binding), epoch: epoch))
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
