#if VOTING_ENABLED
@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import os
@preconcurrency import ZcashLightClientKit

// MARK: - Live key

extension VotingCryptoClient: DependencyKey {
    static var liveValue: Self {
        let dbActor = DatabaseActor()
        let stateSubject = CurrentValueSubject<VotingDbState, Never>(.initial)

        // Sessions are made by the synchronizer rather than by the backend: a
        // `.tor` session borrows the Tor runtime the synchronizer owns, and the
        // backend call that would build one directly is internal to the SDK.
        // Resolved inside the closure so the registry follows the dependency
        // context it is used from rather than the one `liveValue` was built in.
        let registry = VotingSessionRegistry { inputs, binding, route, epoch in
            @Dependency(\.sdkSynchronizer)
            var sdkSynchronizer
            let backend = try await dbActor.backend()

            return try await sdkSynchronizer.makeVotingRoundSession(backend, inputs, binding, route, epoch)
        }

        return Self(
            stateStream: {
                stateSubject
                    .dropFirst() // Skip initial empty state
                    .eraseToAnyPublisher()
            },
            refreshState: { _ in
                stateSubject.send(stateSubject.value)
            },
            configureProving: { policy in
                // `false` means a different policy is already in force for this
                // process, which the crate will not replace. Worth a line,
                // never worth failing the flow the voter is in.
                let applied = try VotingRustBackend.configureProving(policy)
                if !applied {
                    LoggerProxy.debug("voting: proving pool already configured with a different policy")
                }
            },
            warmProvingCaches: {
                // The crate's keygen threads inherit this task's QoS; background
                // priority pinned them to efficiency cores and the first proof
                // convoyed behind that keygen while the user watched "Authorizing...".
                try await Task.detached(priority: .userInitiated) {
                    try VotingRustBackend.warmProvingCaches()
                }.value
            },
            openDatabase: { path, networkId in
                try await dbActor.open(path: path, networkId: networkId)
            },
            setWalletId: { walletId in
                let backend = try await dbActor.backend()
                try backend.setWalletId(walletId)
            },
            closeDatabase: {
                // Sessions hold their own reference to the sidecar, so they go
                // first: closing the store under a live session would leave the
                // round driving a database nothing owns.
                await registry.closeAll()
                await dbActor.close()
            },
            listRounds: {
                let backend = try await dbActor.backend()
                return try backend.listRounds()
            },
            roundPlan: { roundId, proposalIds in
                let backend = try await dbActor.backend()
                return try backend.roundPlan(roundId: roundId, proposalIds: proposalIds)
            },
            pendingShareRounds: {
                let backend = try await dbActor.backend()
                return try backend.pendingShareRounds()
            },
            syncVoteTree: { roundId, nodeUrl in
                let backend = try await dbActor.backend()
                return try await backend.syncVoteTree(roundId: roundId, nodeUrl: nodeUrl)
            },
            resetVoteTree: { roundId in
                let backend = try await dbActor.backend()
                try backend.resetVoteTree(roundId: roundId)
            },
            resetSessionState: { roundId in
                let backend = try await dbActor.backend()
                try backend.resetSessionState(roundId: roundId)
            },
            deleteRound: { roundId, discardingRecovery in
                let backend = try await dbActor.backend()
                try backend.deleteRound(roundId: roundId, discardingRecovery: discardingRecovery)
            },
            deleteSkippedBundles: { roundId, keepCount in
                let backend = try await dbActor.backend()
                _ = try backend.deleteSkippedBundles(roundId: roundId, keepCount: keepCount)
            },
            retryBlockedCombinedCast: { roundId, bundleIndex in
                let backend = try await dbActor.backend()
                return try backend.retryBlockedCombinedCast(roundId: roundId, bundleIndex: bundleIndex)
            },
            clearBallotIntents: { roundId, proposalIds in
                let backend = try await dbActor.backend()
                try backend.clearBallotIntents(roundId: roundId, proposalIds: proposalIds)
            },
            keystoneSignatures: { roundId in
                let backend = try await dbActor.backend()
                return try backend.keystoneSignatures(roundId: roundId)
            },
            openRoundSession: { inputs, binding, route, epoch in
                _ = try await registry.open(inputs: inputs, binding: binding, route: route, epoch: epoch)
            },
            closeRoundSession: { roundId in
                await registry.close(roundId)
            },
            closeAllRoundSessions: {
                await registry.closeAll()
            },
            cancelRoundSession: { roundId in
                await registry.cancel(roundId)
            },
            setOperationEpoch: { roundId, epoch in
                await registry.setEpoch(roundId, epoch)
            },
            sessionPlan: { roundId in
                try await registry.session(for: roundId).plan()
            },
            setBallotIntents: { roundId, intents in
                try await registry.session(for: roundId).setBallotIntents(intents)
            },
            setupBundles: { roundId in
                try await registry.session(for: roundId).setupBundles()
            },
            eligibility: { roundId in
                try await registry.session(for: roundId).eligibility()
            },
            precomputePir: { roundId, bundleIndex in
                try await registry.session(for: roundId).precomputePir(bundleIndex: bundleIndex)
            },
            precomputeDelegationProof: { roundId, bundleIndex in
                // No cancellation hook: `cancel()` finishes a session for good
                // and would not interrupt a proof already running anyway, so an
                // abandoned precompute stops being listened to and the proof it
                // started is persisted for the run that follows.
                VotingCryptoClient.sessionStream(
                    cancelling: {},
                    call: { progress in
                        try await registry.session(for: roundId)
                            .precomputeDelegationProof(bundleIndex: bundleIndex, progress: progress)
                    },
                    event: VotingDelegationProofEvent.progress,
                    report: VotingDelegationProofEvent.finished
                )
            },
            keystoneSigningRequests: { roundId, bundleIndices in
                try await registry.session(for: roundId).keystoneSigningRequests(bundleIndices: bundleIndices)
            },
            storeKeystoneSignatures: { roundId, signed in
                try await registry.session(for: roundId).storeKeystoneSignatures(signed)
            },
            runRound: { roundId, signer, policy in
                VotingCryptoClient.sessionStream(
                    cancelling: { await registry.cancel(roundId) },
                    call: { events in
                        try await registry.session(for: roundId)
                            .run(signer: signer, policy: policy, events: events)
                    },
                    event: VotingRoundRunEvent.event,
                    report: VotingRoundRunEvent.finished
                )
            },
            trackShares: { roundId, policy in
                VotingCryptoClient.sessionStream(
                    cancelling: { await registry.cancel(roundId) },
                    call: { events in
                        try await registry.session(for: roundId)
                            .trackShares(policy: policy, events: events)
                    },
                    event: VotingShareTrackingRunEvent.event,
                    report: VotingShareTrackingRunEvent.finished
                )
            },
            generateHotkey: { networkId in
                let hotkey = try VotingRustBackend.generateHotkey(networkId: networkId)
                return VotingHotkey(
                    storedSecret: Data(hotkey.storedSecret),
                    rawOrchardAddress: Data(hotkey.rawOrchardAddress),
                    addressIndex: hotkey.addressIndex
                )
            },
            extractOrchardFvkFromUfvk: { ufvkStr, networkId in
                Data(try VotingRustBackend.extractOrchardFvk(ufvk: ufvkStr, networkId: networkId))
            },
            extractNcRoot: { treeStateBytes in
                Data(try VotingRustBackend.extractNcRoot(treeState: [UInt8](treeStateBytes)))
            }
        )
    }
}

// MARK: - Session streams

extension VotingCryptoClient {
    /// Runs one narrating session call as a stream.
    ///
    /// The session calls that drive a round report through a closure and answer
    /// with a report; a reducer wants one ordered channel instead. So every
    /// reported value becomes an element, the answer becomes the last element,
    /// and a throw finishes the stream with that error. The report is the
    /// authoritative account — events are a best-effort narration the SDK drops
    /// under load — so a consumer that reads only the last element still sees
    /// everything that happened.
    ///
    /// `cancelling` runs only when the CONSUMER went away (its task was
    /// cancelled, or it dropped the stream), never on normal completion: the
    /// SDK's cancellation finishes a session for good, and finishing a session
    /// because its own run ended would take the round down with it.
    ///
    /// Factored out of `liveValue` so a test can drive the cancellation
    /// behaviour with a stub call.
    static func sessionStream<Element: Sendable, Event: Sendable, Report: Sendable>(
        cancelling cancel: @escaping @Sendable () async -> Void,
        call: @escaping @Sendable (@escaping @Sendable (Event) -> Void) async throws -> Report,
        event: @escaping @Sendable (Event) -> Element,
        report: @escaping @Sendable (Report) -> Element
    ) -> AsyncThrowingStream<Element, Error> {
        // The handler is installed BEFORE the work starts, which is why the
        // stream is built by hand rather than with the closure initializer.
        // `onTermination` assigned to a continuation that has already finished
        // is invoked at once, and with `.cancelled` — so installing it after
        // the task would report a run that completed normally as a
        // cancellation, and the cancellation this hands out is permanent.
        let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream()
        let termination = VotingStreamTermination(cancelling: cancel)

        continuation.onTermination = { reason in
            guard case .cancelled = reason else { return }
            termination.consumerWentAway()
        }

        termination.attach(
            Task {
                do {
                    let answer = try await call { value in
                        continuation.yield(event(value))
                    }
                    continuation.yield(report(answer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        )

        return stream
    }
}

/// Holds a session stream's work so its termination handler can reach it.
///
/// The handler has to be installed before the task exists — see
/// ``VotingCryptoClient/sessionStream(cancelling:call:event:report:)`` — so the
/// two find each other here instead. A consumer that goes away before the task
/// has been attached is remembered, and the attach cancels straight away; the
/// cancellation runs once however the two are ordered.
private final class VotingStreamTermination: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var consumerWentAway = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cancel: @Sendable () async -> Void

    init(cancelling cancel: @escaping @Sendable () async -> Void) {
        self.cancel = cancel
    }

    func attach(_ task: Task<Void, Never>) {
        let tooLate = state.withLock { state in
            state.task = task
            return state.consumerWentAway
        }

        if tooLate {
            task.cancel()
        }
    }

    func consumerWentAway() {
        let (task, isFirst) = state.withLock { state -> (Task<Void, Never>?, Bool) in
            let isFirst = !state.consumerWentAway
            state.consumerWentAway = true
            return (state.task, isFirst)
        }

        guard isFirst else { return }

        task?.cancel()
        Task { [cancel] in
            await cancel()
        }
    }
}

// MARK: - DatabaseActor

/// Thread-safe holder for the VotingRustBackend instance.
private actor DatabaseActor {
    private var openBackend: VotingRustBackend?

    func open(path: String, networkId: UInt32) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        close()

        let backend = VotingRustBackend()
        try backend.open(path: path, networkId: networkId)
        openBackend = backend
    }

    func backend() throws -> VotingRustBackend {
        guard let openBackend else {
            throw VotingCryptoError.databaseNotOpen
        }
        return openBackend
    }

    func close() {
        openBackend?.close()
        openBackend = nil
    }
}

// MARK: - Helpers

enum VotingCryptoError: LocalizedError {
    case databaseNotOpen

    var errorDescription: String? {
        switch self {
        case .databaseNotOpen:
            return "Voting database is not open."
        }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
