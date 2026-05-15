import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

// MARK: - Batch Voting Submission

extension Voting {
    func reduceSubmission(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {

        case let .setDraftVote(proposalId, choice):
            guard state.votes[proposalId] == nil else { return .none }
            state.draftVotes[proposalId] = choice
            Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
            // Pop back to the list so the user can continue drafting other proposals
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            }
            return .none

        case let .clearDraftVote(proposalId):
            state.draftVotes.removeValue(forKey: proposalId)
            Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
            return .none

        case .submitAllDrafts:
            guard state.canSubmitBatch else { return .none }
            guard state.activeSession != nil else { return .none }

            // Non-Keystone: require device authentication (FaceID/TouchID/Passcode)
            // before proceeding. Keystone users authenticate via their hardware device.
            // Skip auth when resuming after delegation (pendingBatchSubmission flow).
            if !state.isKeystoneUser && !state.pendingBatchSubmission {
                return .run { [localAuthentication] send in
                    guard await localAuthentication.authenticate() else { return }
                    await send(.authenticationSucceeded)
                }
            }
            return .send(.authenticationSucceeded)

        case .authenticationSucceeded:
            guard state.canSubmitBatch || state.isBatchSubmitting else { return .none }
            guard state.activeSession != nil else { return .none }

            // Keystone: delegation requires QR signing UI, so route through
            // the delegation signing screen before batch submission.
            if state.isKeystoneUser && !state.isDelegationReady {
                state.pendingBatchSubmission = true
                state.screenStack.append(.delegationSigning)
                return .send(.startDelegationProof)
            }

            if !state.isKeystoneUser && !state.isDelegationReady && state.isDelegationPrecomputeInFlight {
                state.pendingBatchSubmission = true
                state.batchSubmissionStatus = .authorizing
                state.voteSubmissionStep = .authorizingVote
                state.delegationProofStatus = .generating(progress: 0)
                return .none
            }

            let drafts = state.draftVotes.sorted { $0.key < $1.key }
            let totalCount = drafts.count
            let delegationDone = state.isDelegationReady
            let delegationPrepared = state.isDelegationPrecomputeReady
            state.batchSubmissionStatus = delegationDone
                ? .submitting(currentIndex: 0, totalCount: totalCount, currentProposalId: drafts[0].key)
                : .authorizing
            state.voteSubmissionStep = delegationDone ? nil : .authorizingVote
            if !delegationDone {
                state.delegationProofStatus = .generating(progress: 0)
            }
            state.batchVoteErrors = [:]

            let roundId = state.roundId
            let network = zcashSDKEnvironment.network
            let networkId: UInt32 = network.networkType.votingRustNetworkId
            let accountIndex = votingAccountIndex(for: state.selectedWalletAccount)
            let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount)
            guard
                let chainNodeUrl = state.serviceConfig?.voteServers.first?.url,
                let voteServerURLs = state.serviceConfig?.voteServers.map(\.url),
                !voteServerURLs.isEmpty,
                let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
                !pirEndpoints.isEmpty,
                let expectedSnapshotHeight = state.activeSession?.snapshotHeight
            else {
                votingLogger.error("serviceConfig/activeSession unexpectedly nil during vote submission; aborting")
                return .none
            }
            let bundleCount = state.bundleCount
            let singleShare = state.activeSession?.isLastMoment ?? false
            let proposals = state.votingRound.proposals
            let cachedNotes = state.walletNotes
            let roundName = state.votingRound.title

            let submitAtDeadline: Double?
            if singleShare {
                submitAtDeadline = nil
            } else if let session = state.activeSession, let buffer = session.lastMomentBuffer {
                submitAtDeadline = session.voteEndTime.timeIntervalSince1970 - buffer
            } else {
                submitAtDeadline = nil
            }

            return .run { [backgroundTask, votingAPI, votingCrypto, mnemonic, walletStorage] send in
                let bgTaskId = await backgroundTask.beginTask("Batch vote submission")
                let _ = await backgroundTask.beginContinuedProcessing(
                    "co.zodl.voting.*",
                    String(localizable: .coinVoteSubmissionContinuedProcessingTitle),
                    totalCount == 1
                        ? String(localizable: .coinVoteSubmissionContinuedProcessingMessageSingle(String(totalCount)))
                        : String(localizable: .coinVoteSubmissionContinuedProcessingMessageMultiple(String(totalCount)))
                )
                defer {
                    Task {
                        await backgroundTask.endContinuedProcessing()
                        await backgroundTask.endTask(bgTaskId)
                    }
                }

                let hotkeyPhrase = try walletStorage.exportVotingHotkey("").seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)

                // --- Delegation (ZKP #1) — run inline if not already done ---
                // Failures here are surfaced as authorization errors so the UI
                // can show the dedicated "Authorization Failed" sheet and
                // distinguish them from per-proposal submission failures below.
                if !delegationDone {
                    do {
                        let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                        let senderSeed = try mnemonic.toSeed(senderPhrase)
                        try await Self.runDelegationPipeline(
                            roundId: roundId,
                            cachedNotes: cachedNotes,
                            senderSeed: senderSeed,
                            hotkeySeed: hotkeySeed,
                            networkId: networkId,
                            accountIndex: accountIndex,
                            roundName: roundName,
                            pirEndpoints: pirEndpoints,
                            expectedSnapshotHeight: expectedSnapshotHeight,
                            delegationPrepared: delegationPrepared,
                            seedFingerprint: seedFingerprint,
                            votingCrypto: votingCrypto,
                            votingAPI: votingAPI,
                            send: send
                        )
                    } catch {
                        votingLogger.error("Delegation pipeline failed (raw): \(error.localizedDescription)")
                        await send(.batchAuthorizationFailed(
                            error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription)
                        ))
                        return
                    }
                }

                // Transition from .authorizing to .submitting now that delegation is done.
                await send(.batchSubmissionProgress(
                    currentIndex: 0, totalCount: totalCount, proposalId: drafts[0].key
                ))

                var successCount = 0
                var failCount = 0
                var shareServerURLs = voteServerURLs

                draftLoop: for (draftIndex, draft) in drafts.enumerated() {
                    let proposalId = draft.key
                    let choice = draft.value
                    let proposal = proposals.first { $0.id == proposalId }
                    let numOptions = UInt32(proposal?.options.count ?? 3)

                    await send(.batchSubmissionProgress(currentIndex: draftIndex, totalCount: totalCount, proposalId: proposalId))

                    // Synthetic abstain: when proposal data doesn't declare an
                    // Abstain option, the UI synthesizes one at max(index) + 1.
                    // There's no on-chain option to submit for that fallback, so
                    // count it as done for UX/progress and skip ZKP #2/cast-vote.
                    if Self.isSyntheticAbstain(choice: choice, proposal: proposal) {
                        successCount += 1
                        await send(.batchVoteSubmitted(proposalId: proposalId, choice: choice))
                        continue
                    }

                    do {
                        let existingVotes = try await votingCrypto.getVotes(roundId)
                        let submittedBundles = Set(
                            existingVotes
                                .filter { $0.proposalId == proposalId && $0.submitted }
                                .map(\.bundleIndex)
                        )

                        for bundleIndex: UInt32 in 0..<bundleCount {
                            if submittedBundles.contains(bundleIndex) {
                                votingLogger.debug("Batch: bundle \(bundleIndex + 1)/\(bundleCount) already submitted for proposal \(proposalId)")
                                continue
                            }

                            await send(.voteSubmissionBundleStarted(bundleIndex))
                            await send(.voteSubmissionStepUpdated(.preparingProof))

                            // Crash recovery: check if TX landed on-chain but wasn't marked
                            if case let .present(cachedTxHash)? = try? await votingCrypto.getVoteTxHash(roundId, bundleIndex, proposalId) {
                                if let confirmation = try? await votingAPI.fetchTxConfirmation(cachedTxHash),
                                   confirmation.code == 0,
                                   let leafPair = confirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index") {
                                    let leafParts = leafPair.split(separator: ",")
                                    if leafParts.count == 2,
                                       let vanIdx = UInt32(leafParts[0]),
                                       let vcIdx = UInt64(leafParts[1]) {
                                        try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)
                                        if let savedBundle = try? await votingCrypto.getVoteCommitmentBundle(roundId, bundleIndex, proposalId) {
                                            try await votingCrypto.storeVoteCommitmentBundle(
                                                roundId, bundleIndex, proposalId, savedBundle, vcIdx
                                            )
                                            await send(.voteSubmissionStepUpdated(.sendingShares))
                                            var payloads = try await votingCrypto.buildSharePayloads(
                                                savedBundle.encShares, savedBundle, choice, numOptions, vcIdx, singleShare
                                            )
                                            let now = Date().timeIntervalSince1970
                                            for i in payloads.indices {
                                                if let deadline = submitAtDeadline, deadline > now {
                                                    payloads[i].submitAt = UInt64(now + Double.random(in: 0..<(deadline - now)))
                                                } else {
                                                    payloads[i].submitAt = 0
                                                }
                                            }
                                            let recoveryResult = try await Self.delegateSharesWithFallback(
                                                payloads,
                                                roundId: roundId,
                                                votingAPI: votingAPI,
                                                serverURLs: shareServerURLs
                                            )
                                            shareServerURLs = recoveryResult.remainingServerURLs
                                            for info in recoveryResult.delegatedShares {
                                                guard let payload = payloads.first(where: {
                                                    $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
                                                }) else { continue }
                                                let blindIdx = Int(info.shareIndex)
                                                guard blindIdx < savedBundle.shareBlindFactors.count else { continue }
                                                do {
                                                    let nfHex = try votingCrypto.computeShareNullifier(
                                                        [UInt8](savedBundle.voteCommitment),
                                                        info.shareIndex,
                                                        [UInt8](savedBundle.shareBlindFactors[blindIdx])
                                                    )
                                                    try await votingCrypto.recordShareDelegation(
                                                        roundId, bundleIndex, info.proposalId,
                                                        info.shareIndex, info.acceptedByServers,
                                                        [UInt8](votingDataFromHex(nfHex)), payload.submitAt
                                                    )
                                                } catch {
                                                    votingLogger.warning("Batch recovery: failed to record share delegation for share \(info.shareIndex): \(error)")
                                                }
                                            }
                                        }
                                        try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
                                        continue
                                    }
                                }
                            }

                            let anchorHeight = try await votingCrypto.syncVoteTree(roundId, chainNodeUrl)
                            let vanWitness = try await votingCrypto.generateVanWitness(roundId, bundleIndex, anchorHeight)

                            var builtBundle: VoteCommitmentBundle?
                            for try await event in votingCrypto.buildVoteCommitment(
                                roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice,
                                numOptions, vanWitness.authPath, vanWitness.position, vanWitness.anchorHeight, singleShare
                            ) {
                                if case .completed(let bundle) = event {
                                    builtBundle = bundle
                                }
                            }
                            guard let builtBundle else {
                                throw VotingFlowError.missingVoteCommitmentBundle
                            }

                            try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, 0)

                            let castVoteSig = try await votingCrypto.signCastVote(hotkeySeed, networkId, builtBundle)

                            await send(.voteSubmissionStepUpdated(.confirming))
                            let txResult = try await votingAPI.submitVoteCommitment(builtBundle, castVoteSig)
                            try await votingCrypto.storeVoteTxHash(roundId, bundleIndex, proposalId, txResult.txHash)

                            let voteDeadline = Date().addingTimeInterval(90)
                            var voteConfirmation: TxConfirmation?
                            repeat {
                                voteConfirmation = try? await votingAPI.fetchTxConfirmation(txResult.txHash)
                                if voteConfirmation != nil { break }
                                try await Task.sleep(for: .seconds(2))
                            } while Date() < voteDeadline

                            guard let voteConfirmation, voteConfirmation.code == 0,
                                  let leafPair = voteConfirmation.event(ofType: "cast_vote")?.attribute(forKey: "leaf_index")
                            else {
                                throw VotingFlowError.voteCommitmentTxFailed(
                                    code: voteConfirmation?.code ?? 0,
                                    log: voteConfirmation?.log ?? ""
                                )
                            }
                            let leafParts = leafPair.split(separator: ",")
                            guard leafParts.count == 2,
                                  let vanIdx = UInt32(leafParts[0]),
                                  let vcIdx = UInt64(leafParts[1])
                            else {
                                throw VotingFlowError.voteCommitmentTxFailed(
                                    code: 0,
                                    log: "malformed cast_vote leaf_index: \(leafPair)"
                                )
                            }

                            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanIdx)

                            await send(.voteSubmissionStepUpdated(.sendingShares))
                            var payloads = try await votingCrypto.buildSharePayloads(
                                builtBundle.encShares, builtBundle, choice, numOptions, vcIdx, singleShare
                            )
                            let nowSec = Date().timeIntervalSince1970
                            for i in payloads.indices {
                                if let deadline = submitAtDeadline, deadline > nowSec {
                                    payloads[i].submitAt = UInt64(nowSec + Double.random(in: 0..<(deadline - nowSec)))
                                } else {
                                    payloads[i].submitAt = 0
                                }
                            }
                            try await votingCrypto.storeVoteCommitmentBundle(roundId, bundleIndex, proposalId, builtBundle, vcIdx)
                            let batchDelegationResult = try await Self.delegateSharesWithFallback(
                                payloads,
                                roundId: roundId,
                                votingAPI: votingAPI,
                                serverURLs: shareServerURLs
                            )
                            shareServerURLs = batchDelegationResult.remainingServerURLs
                            for info in batchDelegationResult.delegatedShares {
                                guard let payload = payloads.first(where: {
                                    $0.encShare.shareIndex == info.shareIndex && $0.proposalId == info.proposalId
                                }) else { continue }
                                let blindIndex = Int(info.shareIndex)
                                guard blindIndex < builtBundle.shareBlindFactors.count else { continue }
                                do {
                                    let nullifierHex = try votingCrypto.computeShareNullifier(
                                        [UInt8](builtBundle.voteCommitment),
                                        info.shareIndex,
                                        [UInt8](builtBundle.shareBlindFactors[blindIndex])
                                    )
                                    try await votingCrypto.recordShareDelegation(
                                        roundId, bundleIndex, info.proposalId,
                                        info.shareIndex, info.acceptedByServers,
                                        [UInt8](votingDataFromHex(nullifierHex)), payload.submitAt
                                    )
                                } catch {
                                    votingLogger.warning("Batch: failed to record share delegation for share \(info.shareIndex): \(error)")
                                }
                            }
                            try await votingCrypto.markVoteSubmitted(roundId, bundleIndex, proposalId)
                        }

                        successCount += 1
                        await send(.batchVoteSubmitted(proposalId: proposalId, choice: choice))
                    } catch {
                        failCount += 1
                        votingLogger.error("Batch vote failed for proposal \(proposalId): \(error)")
                        let shouldStopBatch = error as? ShareDelegationError == .noReachableVoteServers
                        if shouldStopBatch {
                            shareServerURLs = []
                        }
                        await send(.batchVoteFailed(
                            proposalId: proposalId,
                            error: VotingErrorMapper.userFriendlyMessage(from: error)
                        ))
                        if shouldStopBatch {
                            break draftLoop
                        }
                    }
                }

                await send(.batchSubmissionCompleted(successCount: successCount, failCount: failCount))
            } catch: { error, send in
                votingLogger.error("Batch submission failed at top level: \(error)")
                await send(.batchSubmissionFailed(
                    error: VotingErrorMapper.userFriendlyMessage(from: error.localizedDescription),
                    submittedCount: 0,
                    totalCount: totalCount
                ))
            }

        case let .batchSubmissionProgress(currentIndex, totalCount, proposalId):
            state.batchSubmissionStatus = .submitting(
                currentIndex: currentIndex,
                totalCount: totalCount,
                currentProposalId: proposalId
            )
            state.submittingProposalId = proposalId
            state.isSubmittingVote = true
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            return .none

        case let .batchVoteSubmitted(proposalId, choice):
            state.votes[proposalId] = choice
            state.draftVotes.removeValue(forKey: proposalId)
            Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
            return .none

        case let .batchVoteFailed(proposalId, error):
            state.batchVoteErrors[proposalId] = error
            return .none

        case let .batchSubmissionCompleted(successCount, failCount):
            state.isSubmittingVote = false
            state.submittingProposalId = nil
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            if failCount > 0 {
                // Keep persisted drafts: failed proposals are still in draftVotes
                // (only successful ones were removed on .batchVoteSubmitted) so
                // retrying the batch naturally resubmits only what failed.
                let error = state.batchVoteErrors.values.first ?? String(localizable: .coinVoteSubmissionGenericBatchFailure)
                state.batchSubmissionStatus = .submissionFailed(
                    error: error,
                    submittedCount: successCount,
                    totalCount: successCount + failCount
                )
            } else {
                // Persist the round-level submission marker only after every
                // proposal in the batch has completed. Until then, the user
                // must still be able to re-enter the round and edit/retry any
                // outstanding drafts.
                if state.voteRecord == nil {
                    let record = VoteRecord(
                        votedAt: Date(),
                        votingWeight: state.votingWeight,
                        proposalCount: state.totalProposals
                    )
                    state.voteRecord = record
                    Self.persistVoteRecord(record, walletId: state.walletId, roundId: state.roundId)
                    state.voteRecords[state.roundId] = record
                }
                state.batchSubmissionStatus = .completed(successCount: successCount)
                Self.clearPersistedDrafts(walletId: state.walletId, roundId: state.roundId)
            }
            return .none

        case let .batchAuthorizationFailed(error):
            state.isSubmittingVote = false
            state.submittingProposalId = nil
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            state.batchSubmissionStatus = .authorizationFailed(error: error)
            return .none

        case let .batchSubmissionFailed(error, submittedCount, totalCount):
            state.isSubmittingVote = false
            state.submittingProposalId = nil
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            state.batchSubmissionStatus = .submissionFailed(
                error: error,
                submittedCount: submittedCount,
                totalCount: totalCount
            )
            return .none

        case .retryBatchSubmission:
            // Reset transient status and per-proposal errors, then re-run the
            // submission pipeline. Successful proposals were already cleared
            // from draftVotes on .batchVoteSubmitted, so this resumes with
            // only the proposals that are still outstanding.
            state.batchSubmissionStatus = .idle
            state.batchVoteErrors = [:]
            return .send(.submitAllDrafts)

        case .dismissBatchResults:
            state.batchSubmissionStatus = .idle
            state.batchVoteErrors = [:]
            return .none

        default:
            return .none
        }
    }

    static func isSyntheticAbstain(choice: VoteChoice, proposal: VotingProposal?) -> Bool {
        guard let proposal else { return false }

        if proposal.options.contains(where: { $0.index == choice.index }) {
            return false
        }

        // Synthesized Abstain is the one fallback index the UI creates when a
        // proposal has no native Abstain option. Other out-of-range choices
        // should not be silently treated as abstains.
        guard !proposal.options.contains(where: { $0.label.localizedCaseInsensitiveContains("abstain") }) else {
            return false
        }
        let synthesizedAbstainIndex = (proposal.options.map(\.index).max() ?? 0) + 1
        return choice.index == synthesizedAbstainIndex
    }
}
