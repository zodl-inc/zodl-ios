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
//      sync                            the vote tree was synced (the call carries no bundle)
//      witness:<bundle>                the bundle's VAN witness was generated from that sync
//      commit:<bundle>:<proposal>      `commitVote` built the vote commitment
//      submit:<proposal>               the commitment was broadcast
//      confirm:<bundle>:<proposal>     the confirmed transaction was written back
//      deliver:<proposal>              helper-share delivery reached `delegateShares`
//      record:<bundle>:<proposal>:<s>  share `s`'s delegation was recorded locally
//
//  `sync` and `witness:` are a pair: the witness has to be anchored at the height its own sync
//  returned, so a run in which a second `sync` lands between a `sync` and its `witness:` is a bug,
//  not an interleaving.
//
//  Plus one event that only a cancelled run produces:
//
//      deliver-cancelled:<proposal>    a gated delivery was cancelled rather than opened
//
//  A fixture built with `delegationProven: false` starts before authorization, so the
//  delegation lane is exercised too. Its vocabulary, in the order one bundle produces it:
//
//      pczt:<bundle>                   `buildVotingPczt` stored the bundle's PCZT setup
//      pir:<bundle>                    `precomputeDelegationPir` warmed the PIR cache
//      specprove:<bundle>              the speculative (pre-Confirm) ZKP #1 started
//      promote                         `promoteDelegationProving` raised the proving pool
//      reset-promotion                 `resetDelegationProvingPromotion` cleared it again
//      seed-export                     the wallet seed phrase left the keychain
//      prove:<bundle>                  `buildAndProveDelegation` — the interactive ZKP #1
//      sign:<bundle>                   `signDelegationRequest` signed the delegation
//      registration:<bundle>           `getDelegationSubmission` assembled the payload
//      deleg-submit:<bundle>           the registration was broadcast
//      deleg-tx:<bundle>               the delegation TX hash was stored locally
//      van:<bundle>                    the bundle's VAN position was stored
//
//  A bundle's `registration:` only assembles once a proof — speculative or interactive — has
//  completed for it, and `sign:` only once its PCZT setup exists: that is what makes "the
//  stored proof was reused" and "this bundle fell back to the interactive proof" observable.
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
        /// A speculative delegation proof was asked to fail for its bundle.
        case speculativeProofFailed
        /// `signDelegationRequest` before this bundle's `buildVotingPczt` — the crate's
        /// "no persisted setup" refusal.
        case missingSetup
        /// `getDelegationSubmission` before a proof for this bundle finished — the probe the
        /// delegation pipeline uses to decide whether it still has to prove.
        case missingProof
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
        /// `syncVoteTree` carries no bundle index, so the only gate it can offer is "the first call
        /// of the run"; `firstSyncGateClaimed` is what makes it fire once rather than on every sync.
        var firstSyncGate: ResumableGate?
        var firstSyncGateClaimed = false
        var poolEmptyingProposals: Set<UInt32> = []
        var deliveryFailures: [UInt32: DeliveryFailure] = [:]
        var commitFailures: Set<BundleProposal> = []
        var speculativeProofGates: [UInt32: ResumableGate] = [:]
        var speculativeProofFinishGates: [UInt32: ResumableGate] = [:]
        var speculativeProofFailures: Set<UInt32> = []
        var delegationSubmitGates: [UInt32: ResumableGate] = [:]
        /// Bundles whose `buildVotingPczt` has run, and whose proof has completed — the two
        /// pieces of persisted state the delegation pipeline probes for.
        var storedSetups: Set<UInt32> = []
        var storedProofs: Set<UInt32> = []
        var storedDelegationTxHashes: [UInt32: String] = [:]
    }

    static let roundId = String(repeating: "aa", count: 32)
    /// Every built bundle carries the full 16 tally shares — the count the crate produces once a
    /// vote is not single-share (finding #9: never derive it from the option count).
    static let shareCount: UInt32 = 16
    static let voteServerURLs = ["https://vote-a.example.com", "https://vote-b.example.com"]

    let recorder = VotingBatchEventRecorder()
    let proposalCount: UInt32
    let bundleCount: UInt32
    /// `true` (the default) starts the round with its authorization already on chain, i.e. at
    /// the point `.authenticationSucceeded` hands straight to the vote loop. `false` starts it
    /// one step earlier — nothing proved, nothing precomputed, the CTA idle — which is where
    /// the Confirm tap and the background precompute both begin.
    let delegationProven: Bool

    private let knobs = OSAllocatedUnfairLock(uncheckedState: Knobs())

    init(proposalCount: UInt32 = 3, bundleCount: UInt32 = 1, delegationProven: Bool = true) {
        self.proposalCount = proposalCount
        self.bundleCount = bundleCount
        self.delegationProven = delegationProven
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

    /// Registers (and so closes) the gate `submitDelegation` parks on for one bundle, after its
    /// registration was assembled and before its `deleg-submit:` event. Pins the state the
    /// Confirm screen shows while a reused proof waits on the chain.
    @discardableResult
    func delegationSubmitGate(forBundle bundleIndex: UInt32) -> ResumableGate {
        knobs.withLockUnchecked { state in
            if let existing = state.delegationSubmitGates[bundleIndex] {
                return existing
            }
            let gate = ResumableGate()
            state.delegationSubmitGates[bundleIndex] = gate
            return gate
        }
    }

    /// Registers (and so closes) the gate the **first** `syncVoteTree` of the run parks on, after
    /// it records its `sync` event. The call carries no bundle index, so "first" is the only thing
    /// the fixture can single out — which is all a test needs to hold one bundle's sync-and-witness
    /// pair open and watch whether another bundle's sync slips into the middle of it.
    @discardableResult
    func firstTreeSyncGate() -> ResumableGate {
        knobs.withLockUnchecked { state in
            if let existing = state.firstSyncGate {
                return existing
            }
            let gate = ResumableGate()
            state.firstSyncGate = gate
            return gate
        }
    }

    /// Makes `proposalId`'s delivery succeed — every share accepted and recorded — but come back
    /// with no helper servers left in the working set.
    ///
    /// That is a real shape, not a contrivance: `delegateSharePayloads` prunes a server from the
    /// set the moment a POST to it fails, and a share that already has one acceptance still counts
    /// as delivered, so a commitment can land in full while the last server drops out behind it.
    /// `deliverShares` prunes the pool *before* it writes the share records, which makes
    /// `record:<b>:<p>:<last>` the point at which the batch provably has nowhere left to send.
    func emptyServerPool(afterProposal proposalId: UInt32) {
        knobs.withLockUnchecked { _ = $0.poolEmptyingProposals.insert(proposalId) }
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

    /// Registers (and so closes) the gate the speculative proof for `bundleIndex` parks on
    /// after it records `specprove:<bundle>` and before it reports any progress. Holding it
    /// pins a Confirm tap to the middle of that bundle's proof.
    @discardableResult
    func speculativeProofGate(forBundle bundleIndex: UInt32) -> ResumableGate {
        knobs.withLockUnchecked { state in
            if let existing = state.speculativeProofGates[bundleIndex] {
                return existing
            }
            let gate = ResumableGate()
            state.speculativeProofGates[bundleIndex] = gate
            return gate
        }
    }

    /// Registers (and so closes) the gate the speculative proof for `bundleIndex` parks on
    /// after its progress event and before completing — the window in which a progress value
    /// the precompute produced is observable on a screen that is waiting for it.
    @discardableResult
    func speculativeProofFinishGate(forBundle bundleIndex: UInt32) -> ResumableGate {
        knobs.withLockUnchecked { state in
            if let existing = state.speculativeProofFinishGates[bundleIndex] {
                return existing
            }
            let gate = ResumableGate()
            state.speculativeProofFinishGates[bundleIndex] = gate
            return gate
        }
    }

    /// Makes the speculative proof for `bundleIndex` fail — after it has recorded
    /// `specprove:<bundle>` and passed any gate, so the attempt is observably reached, and
    /// before it stores a proof, so the bundle falls back to the interactive lane.
    func failSpeculativeProof(forBundle bundleIndex: UInt32) {
        knobs.withLockUnchecked { _ = $0.speculativeProofFailures.insert(bundleIndex) }
    }

    // MARK: - State

    var proposalIds: [UInt32] {
        Array(1...proposalCount)
    }

    /// A software-wallet round whose drafts are one `.option(0)` per proposal. With
    /// `delegationProven` (the default) the authorization is already complete and the CTA is
    /// `.requested` — the state `.authenticationSucceeded` starts the batch from. Without it
    /// nothing is proved or precomputed and the CTA is `.idle`, so `.submitAllDraftsTapped`
    /// and `.maybeStartDelegationPrecompute` both apply.
    func makeState() -> VotingCoordFlow.State {
        var session = RoundSession(roundId: Self.roundId)
        session.bundleCount = bundleCount
        session.eligibleBundleCount = bundleCount
        session.walletNotes = Self.notes(count: Int(bundleCount) * 5, value: 10_000_000)
        session.votingWeight = 50_000_000
        session.eligibleVotingWeight = 50_000_000
        session.hotkeyAddress = "hotkey"
        session.delegationProofStatus = delegationProven ? .complete : .notStarted
        session.delegationPrecomputeStatus = .notStarted
        session.batchSubmissionStatus = delegationProven ? .requested : .idle
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
        values.walletStorage.exportWallet = { [self] in
            // The one call in either lane that needs the wallet seed. A speculative proof that
            // records this has read material it was never allowed to touch.
            recorder.record("seed-export")
            return .placeholder
        }
        values.localAuthentication.authenticate = { true }
        values.votingMetadata = Self.metadataClient(VotingMetadataStore())

        values.votingCrypto.getVotes = { _ in [] }
        values.votingCrypto.getBundleCount = { _ in 0 }
        values.votingCrypto.getShareDelegations = { _ in [] }
        values.votingCrypto.getUnconfirmedDelegations = { _ in [] }
        values.votingCrypto.getVoteTxHash = { _, _, _ in .notFound }
        values.votingCrypto.syncVoteTree = { [self] _, _ in
            recorder.record("sync")
            await claimFirstSyncGate()?.wait()
            return 100
        }
        values.votingCrypto.generateVanWitness = { [self] _, bundleIndex, anchorHeight in
            recorder.record("witness:\(bundleIndex)")
            return VanWitness(
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
                remainingServerURLs: shouldEmptyPool(proposal: proposalId) ? [] : serverURLs
            )
        }

        delegationDependencies(&values)
    }

    /// The authorization (ZKP #1) lane: the background precompute, the promotion pair, the
    /// interactive fallback, and the chain round-trip that ends in a stored VAN position.
    /// Untouched by a `delegationProven` fixture — that state skips the whole lane.
    // swiftlint:disable:next function_body_length
    func delegationDependencies(_ values: inout DependencyValues) {
        values.votingCrypto.getDelegationTxHash = { [self] _, bundleIndex in
            storedDelegationTxHash(bundle: bundleIndex).map { VotingTxHashLookup.present($0) } ?? .notFound
        }
        values.votingCrypto.extractOrchardFvkFromUfvk = { _, _ in Data(repeating: 0x0E, count: 96) }
        values.votingCrypto.buildVotingPczt = { [self] _, bundleIndex, _, _, _, _, _, _, _, _ in
            knobs.withLockUnchecked { _ = $0.storedSetups.insert(bundleIndex) }
            recorder.record("pczt:\(bundleIndex)")
            return Self.makeVotingPcztResult(bundleIndex: bundleIndex)
        }
        values.votingCrypto.precomputeDelegationPir = { [self] _, bundleIndex, _, _, _, _, _, _, _, _ in
            recorder.record("pir:\(bundleIndex)")
            return DelegationPirPrecomputeResult(cachedCount: 1, fetchedCount: 2)
        }
        values.votingCrypto.precomputeDelegationProof = { [self] _, bundleIndex, _, _, _, _, _, _, _, _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                let task = Task { await runSpeculativeProof(bundleIndex: bundleIndex, into: continuation) }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        values.votingCrypto.promoteDelegationProving = { [self] in recorder.record("promote") }
        values.votingCrypto.resetDelegationProvingPromotion = { [self] in recorder.record("reset-promotion") }
        values.votingCrypto.buildAndProveDelegation = { [self] _, bundleIndex, _, _, _, _, _, _, _, _, _, _, _, _ in
            AsyncThrowingStream { continuation in
                knobs.withLockUnchecked { _ = $0.storedProofs.insert(bundleIndex) }
                recorder.record("prove:\(bundleIndex)")
                continuation.yield(.progress(0.5))
                continuation.yield(.completed(Self.proofBytes))
                continuation.finish()
            }
        }
        values.votingCrypto.signDelegationRequest = { [self] _, bundleIndex, _, _, _, _, _ in
            guard hasStoredSetup(bundle: bundleIndex) else { throw FixtureError.missingSetup }
            recorder.record("sign:\(bundleIndex)")
            return (signature: Data(repeating: 0x5A, count: 64), sighash: Self.sighash(bundleIndex: bundleIndex))
        }
        values.votingCrypto.getDelegationSubmission = { [self] _, bundleIndex, _, _ in
            guard hasStoredProof(bundle: bundleIndex) else { throw FixtureError.missingProof }
            recorder.record("registration:\(bundleIndex)")
            return Self.makeDelegationRegistration(bundleIndex: bundleIndex)
        }
        values.votingCrypto.storeDelegationTxHash = { [self] _, bundleIndex, txHash in
            knobs.withLockUnchecked { $0.storedDelegationTxHashes[bundleIndex] = txHash }
            recorder.record("deleg-tx:\(bundleIndex)")
        }
        values.votingCrypto.storeVanPosition = { [self] _, bundleIndex, _ in
            recorder.record("van:\(bundleIndex)")
        }
        values.votingAPI.submitDelegation = { [self] registration in
            let bundleIndex = UInt32(registration.sighash.first ?? 0)
            if let gate = knobs.withLockUnchecked({ $0.delegationSubmitGates[bundleIndex] }) {
                await gate.wait()
            }
            recorder.record("deleg-submit:\(bundleIndex)")
            return TxResult(txHash: "\(Self.delegationTxPrefix)\(bundleIndex)", code: 0)
        }
        // Only a delegation TX carries the `delegate_vote` leaf index the pipeline needs; a
        // vote's confirmation stays exactly what the pre-delegation suites already see.
        values.votingAPI.fetchTxConfirmation = { txHash in
            guard txHash.hasPrefix(Self.delegationTxPrefix) else {
                return TxConfirmation(height: 100, code: 0)
            }
            return TxConfirmation(
                height: 100,
                code: 0,
                events: [
                    TxEvent(
                        type: "delegate_vote",
                        attributes: [TxEventAttribute(key: "leaf_index", value: "9")]
                    )
                ]
            )
        }
    }

    /// Body of the speculative proof stream: announce the attempt, honour the gates, then
    /// either fail this bundle or store its proof and complete.
    private func runSpeculativeProof(
        bundleIndex: UInt32,
        into continuation: AsyncThrowingStream<ProofEvent, Error>.Continuation
    ) async {
        recorder.record("specprove:\(bundleIndex)")
        await speculativeProofGateIfRegistered(bundle: bundleIndex)?.wait()
        if speculativeProofShouldFail(bundle: bundleIndex) {
            continuation.finish(throwing: FixtureError.speculativeProofFailed)
            return
        }
        continuation.yield(.progress(0.5))
        await speculativeProofFinishGateIfRegistered(bundle: bundleIndex)?.wait()
        knobs.withLockUnchecked { _ = $0.storedProofs.insert(bundleIndex) }
        continuation.yield(.completed(Self.proofBytes))
        continuation.finish()
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

    /// Hands out the first-sync gate exactly once, so only the opening `syncVoteTree` of a run
    /// parks on it and every later sync runs straight through.
    private func claimFirstSyncGate() -> ResumableGate? {
        knobs.withLockUnchecked { state in
            guard let gate = state.firstSyncGate, !state.firstSyncGateClaimed else { return nil }
            state.firstSyncGateClaimed = true
            return gate
        }
    }

    private func shouldEmptyPool(proposal proposalId: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.poolEmptyingProposals.contains(proposalId) }
    }

    private func deliveryFailure(proposal proposalId: UInt32) -> DeliveryFailure? {
        knobs.withLockUnchecked { $0.deliveryFailures[proposalId] }
    }

    private func commitShouldFail(bundle bundleIndex: UInt32, proposal proposalId: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.commitFailures.contains(BundleProposal(bundle: bundleIndex, proposal: proposalId)) }
    }

    private func speculativeProofGateIfRegistered(bundle bundleIndex: UInt32) -> ResumableGate? {
        knobs.withLockUnchecked { $0.speculativeProofGates[bundleIndex] }
    }

    private func speculativeProofFinishGateIfRegistered(bundle bundleIndex: UInt32) -> ResumableGate? {
        knobs.withLockUnchecked { $0.speculativeProofFinishGates[bundleIndex] }
    }

    private func speculativeProofShouldFail(bundle bundleIndex: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.speculativeProofFailures.contains(bundleIndex) }
    }

    private func hasStoredSetup(bundle bundleIndex: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.storedSetups.contains(bundleIndex) }
    }

    private func hasStoredProof(bundle bundleIndex: UInt32) -> Bool {
        knobs.withLockUnchecked { $0.storedProofs.contains(bundleIndex) }
    }

    private func storedDelegationTxHash(bundle bundleIndex: UInt32) -> String? {
        knobs.withLockUnchecked { $0.storedDelegationTxHashes[bundleIndex] }
    }

    // MARK: - Builders

    /// Prefix that tells a delegation TX hash apart from a vote's, so one `fetchTxConfirmation`
    /// fake can serve both.
    static let delegationTxPrefix = "deleg-tx-"
    static let proofBytes = Data([0x2A])

    /// The bundle index, round-tripped through the one field that survives
    /// `signDelegationRequest` → `getDelegationSubmission` → `submitDelegation` untouched.
    static func sighash(bundleIndex: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: bundleIndex)])
    }

    static func makeDelegationRegistration(bundleIndex: UInt32) -> DelegationRegistration {
        DelegationRegistration(
            rk: Data(repeating: 0x01, count: 32),
            spendAuthSig: Data(repeating: 0x02, count: 64),
            tx1Effects: Data(repeating: 0x03, count: 64).base64EncodedString(),
            signedNoteNullifier: Data(repeating: 0x04, count: 32).base64EncodedString(),
            cmxNew: Data(repeating: 0x05, count: 32).base64EncodedString(),
            vanCmx: Data(repeating: 0x06, count: 32).base64EncodedString(),
            govNullifiers: [Data(repeating: 0x07, count: 32).base64EncodedString()],
            proof: proofBytes.base64EncodedString(),
            voteRoundId: Data(repeating: 0xAA, count: 32).base64EncodedString(),
            sighash: sighash(bundleIndex: bundleIndex)
        )
    }

    static func makeVotingPcztResult(bundleIndex: UInt32) -> VotingPcztResult {
        VotingPcztResult(
            pcztBytes: Data([0x01]),
            pcztSighash: Data(repeating: UInt8(truncatingIfNeeded: bundleIndex &+ 0x20), count: 32),
            rk: Data(repeating: 0x01, count: 32),
            alpha: Data(repeating: 0x02, count: 32),
            nfSigned: Data(repeating: 0x03, count: 32),
            cmxNew: Data(repeating: 0x04, count: 32),
            govNullifiers: [Data(repeating: 0x05, count: 32)],
            van: Data(repeating: 0x06, count: 32),
            vanCommRand: Data(repeating: 0x07, count: 32),
            dummyNullifiers: [],
            rhoSigned: Data(repeating: 0x08, count: 32),
            paddedCmx: [],
            rseedSigned: Data(repeating: 0x09, count: 32),
            rseedOutput: Data(repeating: 0x0A, count: 32),
            actionBytes: Data([0x0B]),
            actionIndex: 0
        )
    }

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
