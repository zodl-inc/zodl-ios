#if VOTING_ENABLED
//
//  VotingBatchSubmissionFixture.swift
//  zodlTests
//
//  One scaffold for every suite that drives the coinholder batch-submission effect end to end:
//  a `VotingCoordFlow.State` whose delegation is already proven, and a set of recording fakes
//  for the crypto and API clients the effect calls. Nothing here is round-specific — the
//  proposal count, bundle count and every failure or pause is a knob, so a test states only the
//  interleaving it cares about.
//
//  The recorded event vocabulary, in the order one bundle produces it:
//
//      commit:<bundle>:<proposal>      `commitVote` built the vote commitment
//      submit:<proposal>               the commitment was broadcast
//      confirm:<bundle>:<proposal>     the confirmed transaction was written back
//      deliver:<proposal>              helper-share delivery reached `delegateShares`
//      record:<bundle>:<proposal>:<s>  share `s`'s delegation was recorded locally
//
//  Plus one event that only a cancelled run produces:
//
//      deliver-cancelled:<proposal>    a gated delivery was cancelled rather than opened
//
//  Pauses are `ResumableGate`s and waits are `SignalledRecords`-backed (see TestSignals.swift):
//  no polling inside a mock, no wall-clock deadline, so a starved runner slows a test down
//  instead of failing it.
//

import ComposableArchitecture
import Foundation
import os
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

/// Ordered record of what the fixture's fakes were asked to do, with event-driven waits.
final class VotingBatchEventRecorder: @unchecked Sendable {
    private let records = SignalledRecords<String>()

    func record(_ event: String) {
        records.record(event)
    }

    func events() -> [String] {
        records.values
    }

    /// Suspends until `event` has been recorded.
    func awaitEvent(_ event: String) async {
        await records.recorded { $0.contains(event) }
    }

    /// Suspends until the recorded history satisfies `predicate`.
    func awaitEvents(where predicate: @escaping @Sendable ([String]) -> Bool) async {
        await records.recorded(where: predicate)
    }
}

/// Shared state + dependency scaffold for the batch-submission suites.
final class VotingBatchSubmissionFixture: @unchecked Sendable {
    /// Errors the fixture's fakes raise on demand. Distinct cases so a test can assert which
    /// lane failed rather than matching on a message.
    enum FixtureError: Error, Equatable {
        case deliveryRejected
        case proofFailed
    }

    /// How a hooked `delegateShares` call fails.
    enum DeliveryFailure: Equatable, Sendable {
        /// A plain delivery error: fails only its own proposal and leaves the server pool alone.
        case rejected
        /// Every helper server is unreachable — the error that empties the pool and stops the batch.
        case serversExhausted

        var thrown: any Error {
            switch self {
            case .rejected:
                return VotingBatchSubmissionFixture.FixtureError.deliveryRejected
            case .serversExhausted:
                return ShareDelegationError.noReachableVoteServers
            }
        }
    }

    /// Identifies one (bundle, proposal) pair — the granularity of the proof and confirmation knobs.
    struct BundleProposal: Hashable, Sendable {
        let bundleIndex: UInt32
        let proposalId: UInt32

        init(bundle bundleIndex: UInt32, proposal proposalId: UInt32) {
            self.bundleIndex = bundleIndex
            self.proposalId = proposalId
        }
    }

    private struct Knobs {
        var deliveryGates: [UInt32: ResumableGate] = [:]
        var confirmationGates: [BundleProposal: ResumableGate] = [:]
        var commitGates: [BundleProposal: ResumableGate] = [:]
        var deliveryFailures: [UInt32: DeliveryFailure] = [:]
        var commitFailures: Set<BundleProposal> = []
    }

    static let roundId = String(repeating: "aa", count: 32)
    /// Every built bundle carries the full 16 tally shares — the count the crate produces once a
    /// vote is not single-share (finding #9: never derive it from the option count).
    static let shareCount: UInt32 = 16
    static let voteServerURLs = ["https://vote-a.example.com", "https://vote-b.example.com"]

    let recorder = VotingBatchEventRecorder()
    let proposalCount: UInt32
    let bundleCount: UInt32

    private let knobs = OSAllocatedUnfairLock(uncheckedState: Knobs())

    init(proposalCount: UInt32 = 3, bundleCount: UInt32 = 1) {
        self.proposalCount = proposalCount
        self.bundleCount = bundleCount
    }

    // MARK: - Knobs

    /// Registers (and so closes) the gate `delegateShares` parks on for `proposalId`, or returns
    /// the one already registered. Call before running to hold that proposal's delivery open;
    /// `open()` releases it.
    @discardableResult
    func gate(forProposal proposalId: UInt32) -> ResumableGate {
        knobs.withLockUnchecked { state in
            if let existing = state.deliveryGates[proposalId] {
                return existing
            }
            let gate = ResumableGate()
            state.deliveryGates[proposalId] = gate
            return gate
        }
    }

    /// Registers (and so closes) the gate `confirmVoteSubmission` parks on for one (bundle,
    /// proposal) — the last pause before that bundle's shares are handed to the delivery lane.
    @discardableResult
    func confirmationGate(forBundle bundleIndex: UInt32, proposal proposalId: UInt32) -> ResumableGate {
        let key = BundleProposal(bundle: bundleIndex, proposal: proposalId)
        return knobs.withLockUnchecked { state in
            if let existing = state.confirmationGates[key] {
                return existing
            }
            let gate = ResumableGate()
            state.confirmationGates[key] = gate
            return gate
        }
    }

    /// Registers (and so closes) the gate `commitVote` parks on for one (bundle, proposal),
    /// before it records its `commit:` event. Pins where a proof starts relative to another
    /// proposal's in-flight delivery.
    @discardableResult
    func commitGate(forBundle bundleIndex: UInt32, proposal proposalId: UInt32) -> ResumableGate {
        let key = BundleProposal(bundle: bundleIndex, proposal: proposalId)
        return knobs.withLockUnchecked { state in
            if let existing = state.commitGates[key] {
                return existing
            }
            let gate = ResumableGate()
            state.commitGates[key] = gate
            return gate
        }
    }

    /// Makes `delegateShares` throw for `proposalId` — after it has recorded `deliver:<proposal>`
    /// and passed any gate, so the call is observably reached.
    func failDelivery(forProposal proposalId: UInt32, with failure: DeliveryFailure = .rejected) {
        knobs.withLockUnchecked { $0.deliveryFailures[proposalId] = failure }
    }

    /// Makes `commitVote` throw for one (bundle, proposal) instead of recording its event.
    func failCommit(forBundle bundleIndex: UInt32, proposal proposalId: UInt32) {
        knobs.withLockUnchecked { $0.commitFailures.insert(BundleProposal(bundle: bundleIndex, proposal: proposalId)) }
    }

    // MARK: - State

    var proposalIds: [UInt32] {
        Array(1...proposalCount)
    }

    /// A software-wallet round whose delegation proof is already complete and whose drafts are
    /// one `.option(0)` per proposal — the state `.authenticationSucceeded` starts the batch from.
    func makeState() -> VotingCoordFlow.State {
        var session = RoundSession(roundId: Self.roundId)
        session.bundleCount = bundleCount
        session.eligibleBundleCount = bundleCount
        session.walletNotes = Self.notes(count: Int(bundleCount) * 5, value: 10_000_000)
        session.votingWeight = 50_000_000
        session.eligibleVotingWeight = 50_000_000
        session.hotkeyAddress = "hotkey"
        session.delegationProofStatus = .complete
        session.batchSubmissionStatus = .requested
        session.draftVotes = proposalIds.reduce(into: [UInt32: VoteChoice]()) { drafts, proposalId in
            drafts[proposalId] = .option(0)
        }

        var state = VotingCoordFlow.State()
        state.roundCache[Self.roundId] = session
        state.allRounds = [RoundListItem(roundNumber: 1, session: makeVotingSession())]
        state.serviceConfig = Self.makeServiceConfig()
        state.$selectedWalletAccount.withLock { $0 = Self.zashiWalletAccount() }
        return state
    }

    /// The round the drafts belong to: `proposalCount` proposals, three options each, and a
    /// voting window wide enough that `isLastMoment` is false (so every bundle delegates all
    /// 16 shares rather than the single-share prefix).
    func makeVotingSession(status: SessionStatus = .active) -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 123,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: Date().addingTimeInterval(3600),
            ceremonyStart: Date().addingTimeInterval(-3600),
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            description: "Round description",
            proposals: proposalIds.map { proposalId in
                VotingProposal(
                    id: proposalId,
                    title: "Proposal \(proposalId)",
                    description: "Description \(proposalId)",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose"),
                        VoteOption(index: 2, label: "Abstain")
                    ]
                )
            },
            status: status,
            createdAtHeight: 123,
            title: "Round"
        )
    }

    // MARK: - Dependencies

    // swiftlint:disable:next function_body_length
    func dependencies(_ values: inout DependencyValues) {
        values.backgroundTask = .noOp
        values.mnemonic = .noOp
        values.walletStorage = .noOp
        values.walletStorage.exportVotingHotkey = { _ in
            StoredVotingHotkey(storedSecret: VotingHotkeySecret(Data(repeating: 0x11, count: 32)), version: 0)
        }
        values.localAuthentication.authenticate = { true }
        values.votingMetadata = Self.metadataClient(VotingMetadataStore())

        values.votingCrypto.getVotes = { _ in [] }
        values.votingCrypto.getBundleCount = { _ in 0 }
        values.votingCrypto.getShareDelegations = { _ in [] }
        values.votingCrypto.getUnconfirmedDelegations = { _ in [] }
        values.votingCrypto.getVoteTxHash = { _, _, _ in .notFound }
        values.votingCrypto.syncVoteTree = { _, _ in 100 }
        values.votingCrypto.generateVanWitness = { _, _, anchorHeight in
            VanWitness(
                authPath: (0..<24).map { Data(repeating: UInt8($0), count: 32) },
                position: 0,
                anchorHeight: anchorHeight
            )
        }
        values.votingCrypto.commitVote = { [self] _, bundleIndex, _, proposalId, _, _, _, _, _, _, _ in
            await commitGateIfRegistered(bundle: bundleIndex, proposal: proposalId)?.wait()
            if commitShouldFail(bundle: bundleIndex, proposal: proposalId) {
                throw FixtureError.proofFailed
            }
            recorder.record("commit:\(bundleIndex):\(proposalId)")
            return (bundle: Self.makeBundle(proposalId: proposalId), signature: CastVoteSignature(voteAuthSig: Data(repeating: 0xAA, count: 64)))
        }
        values.votingCrypto.storeVoteTxHash = { _, _, _, _ in }
        values.votingCrypto.markVoteSubmitted = { _, _, _, _ in }
        values.votingCrypto.confirmVoteSubmission = { [self] _, bundleIndex, proposalId, txHash, _ in
            await confirmationGateIfRegistered(bundle: bundleIndex, proposal: proposalId)?.wait()
            recorder.record("confirm:\(bundleIndex):\(proposalId)")
            return VoteConfirmationInfo(txHash: txHash, vanLeafPosition: 0, voteCommitmentTreePosition: 7)
        }
        values.votingCrypto.getCommitmentBundleJson = { _, bundleIndex, proposalId in
            (bundleJson: "bundle-\(bundleIndex)-\(proposalId)", vcTreePosition: 7)
        }
        values.votingCrypto.recoverableShareIndices = { _ in Array(0..<Self.shareCount) }
        values.votingCrypto.recoverWireJson = { _, _, _, _, _ in "{}" }
        values.votingCrypto.recordShareDelegation = { [self] _, bundleIndex, proposalId, shareIndex, _, _ in
            recorder.record("record:\(bundleIndex):\(proposalId):\(shareIndex)")
        }

        values.votingAPI.startHealthProbeSweep = { }
        values.votingAPI.submitVoteCommitment = { [self] bundle, _ in
            recorder.record("submit:\(bundle.proposalId)")
            return TxResult(txHash: "tx-\(bundle.proposalId)", code: 0)
        }
        values.votingAPI.fetchTxConfirmation = { _ in TxConfirmation(height: 100, code: 0) }
        values.votingAPI.delegateShares = { [self] payloads, proposalId, serverURLs in
            recorder.record("deliver:\(proposalId)")
            if let gate = gateIfRegistered(proposal: proposalId) {
                // Cancelling this delivery releases the park just as opening the gate does — the
                // idiom `VotingHelperDeliveryWindowTests` uses — so a test can prove the window
                // really reached this task rather than waiting on a gate nobody will open.
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    gate.open()
                }
                if Task.isCancelled {
                    recorder.record("deliver-cancelled:\(proposalId)")
                    throw CancellationError()
                }
            }
            if let failure = deliveryFailure(proposal: proposalId) {
                throw failure.thrown
            }
            return ShareDelegationResult(
                delegatedShares: payloads.map { payload in
                    DelegatedShareInfo(
                        shareIndex: payload.shareIndex,
                        proposalId: proposalId,
                        acceptedByServers: serverURLs
                    )
                },
                remainingServerURLs: serverURLs
            )
        }
    }

    // MARK: - Waits

    /// The 10 ms store poll the voting suites share: exits the moment `predicate` holds, and
    /// records a failure rather than hanging forever if it never does.
    @MainActor
    func waitForStoreState(
        _ store: StoreOf<VotingCoordFlow>,
        timeoutNanoseconds: UInt64 = 60_000_000_000,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ predicate: @MainActor (VotingCoordFlow.State) -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !predicate(store.state), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(predicate(store.state), "Timed out waiting for store state", sourceLocation: sourceLocation)
    }

    // MARK: - Knob reads

    private func gateIfRegistered(proposal proposalId: UInt32) -> ResumableGate? {
        knobs.withLockUnchecked { $0.deliveryGates[proposalId] }
    }

    private func confirmationGateIfRegistered(bundle bundleIndex: UInt32, proposal proposalId: UInt32) -> ResumableGate? {
        knobs.withLockUnchecked { $0.confirmationGates[BundleProposal(bundle: bundleIndex, proposal: proposalId)] }
    }

    private func commitGateIfRegistered(bundle bundleIndex: UInt32, proposal proposalId: UInt32) -> ResumableGate? {
        knobs.withLockUnchecked { $0.commitGates[BundleProposal(bundle: bundleIndex, proposal: proposalId)] }
    }

    private func deliveryFailure(proposal proposalId: UInt32) -> DeliveryFailure? {
        knobs.withLockUnchecked { $0.deliveryFailures[proposalId] }
    }

    private func commitShouldFail(bundle bundleIndex: UInt32, proposal proposalId: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.commitFailures.contains(BundleProposal(bundle: bundleIndex, proposal: proposalId)) }
    }

    // MARK: - Builders

    private static func makeBundle(proposalId: UInt32) -> VoteCommitmentBundle {
        VoteCommitmentBundle(
            vanNullifier: Data(repeating: 0x01, count: 32),
            voteAuthorityNoteNew: Data(repeating: 0x02, count: 32),
            voteCommitment: Data(repeating: 0x03, count: 32),
            proposalId: proposalId,
            proof: Data(repeating: 0x04, count: 32),
            encShares: (0..<shareCount).map { shareIndex in
                EncryptedShare(
                    c1: Data(repeating: 0x05, count: 32),
                    c2: Data(repeating: 0x06, count: 32),
                    shareIndex: shareIndex
                )
            },
            anchorHeight: 100,
            voteRoundId: roundId,
            sharesHash: Data(repeating: 0x07, count: 32)
        )
    }

    static func makeServiceConfig() -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: voteServerURLs.enumerated().map { index, url in
                VotingServiceConfig.ServiceEndpoint(url: url, label: "vote-\(index)")
            },
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 4096)
        )
    }

    private static func note(value: UInt64, position: UInt64) -> NoteInfo {
        let byte = UInt8(position % UInt64(UInt8.max))
        return NoteInfo(
            commitment: Data(repeating: byte, count: 32),
            nullifier: Data(repeating: byte, count: 32),
            value: value,
            position: position,
            diversifier: Data(repeating: byte, count: 11),
            rho: Data(repeating: byte, count: 32),
            rseed: Data(repeating: byte, count: 32),
            scope: 0,
            ufvkStr: "ufvk-\(position)"
        )
    }

    private static func notes(count: Int, value: UInt64) -> [NoteInfo] {
        (0..<count).map { note(value: value, position: UInt64($0)) }
    }

    static func zashiWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x03, count: 16)),
            name: "Zashi",
            keySource: nil,
            seedFingerprint: [UInt8](repeating: 0x04, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    /// In-memory voting metadata: the batch's completion path persists drafts, submitted votes
    /// and the completion record, and an unimplemented client would fail every test through it.
    final class VotingMetadataStore: @unchecked Sendable {
        var drafts: [String: [String: UInt32]] = [:]
        var submittedVotes: [String: [String: UInt32]] = [:]
        var records: [String: PersistedVotingRecord] = [:]
    }

    static func metadataClient(_ store: VotingMetadataStore) -> VotingMetadataProviderClient {
        var client = VotingMetadataProviderClient()
        client.load = { _ in }
        client.store = { _ in }
        client.resetAccount = { _ in }
        client.reset = {}
        client.loadDrafts = { store.drafts[$0] ?? [:] }
        client.setDrafts = { drafts, roundId in store.drafts[roundId] = drafts }
        client.clearDrafts = { roundId in store.drafts[roundId] = [:] }
        client.loadSubmittedVotes = { store.submittedVotes[$0] ?? [:] }
        client.setSubmittedVotes = { votes, roundId in store.submittedVotes[roundId] = votes }
        client.clearSubmittedVotes = { roundId in store.submittedVotes[roundId] = [:] }
        client.record = { store.records[$0] }
        client.allRecords = { store.records }
        client.setRecord = { record, roundId in store.records[roundId] = record }
        client.clearRecord = { roundId in store.records.removeValue(forKey: roundId) }
        return client
    }
}
#endif
