@preconcurrency import ZcashLightClientKit
import Combine
import Foundation
import ComposableArchitecture
import os

// MARK: - Navigation, VotingProposal List/Detail, Share Info, Share Delegation Tracking

struct ShareDelegationKey: Equatable, Sendable {
    let bundleIndex: UInt32
    let proposalId: UInt32
    let shareIndex: UInt32
}

struct ShareRecoveryPollResult: Equatable, Sendable {
    let confirmedShares: [ShareDelegationKey]
    let resubmissionShares: [VotingShareDelegation]
    let queriedCount: Int
}

func shareRecoveryBaseTime(_ share: VotingShareDelegation) -> UInt64 {
    share.submitAt > 0 ? share.submitAt : share.createdAt
}

func isShareReadyForStatusCheck(
    _ share: VotingShareDelegation,
    now: UInt64,
    checkGrace: UInt64 = 10
) -> Bool {
    now >= shareRecoveryBaseTime(share) + checkGrace
}

func shouldResubmitShare(
    _ share: VotingShareDelegation,
    now: UInt64,
    voteEndTime: UInt64,
    resubmitCutoff: UInt64 = 10
) -> Bool {
    let baseTime = shareRecoveryBaseTime(share)
    let remainingWindow = voteEndTime > baseTime ? voteEndTime - baseTime : 0
    let overdueThreshold: UInt64 = max(30, min(3600, remainingWindow / 4))

    return now >= baseTime + overdueThreshold && voteEndTime > now + resubmitCutoff
}

func pollShareStatusesForRecovery(
    readyShares: [VotingShareDelegation],
    roundId: String,
    now: UInt64,
    voteEndTime: UInt64,
    fetchShareStatus: @escaping @Sendable (
        _ helperBaseURL: String,
        _ roundIdHex: String,
        _ nullifierHex: String
    ) async throws -> ShareConfirmationResult
) async -> ShareRecoveryPollResult {
    var confirmedShares: [ShareDelegationKey] = []
    var resubmissionShares: [VotingShareDelegation] = []
    var queriedCount = 0

    for share in readyShares {
        let nullifierHex = share.nullifier
        var confirmed = false

        for helperURL in share.sentToURLs {
            queriedCount += 1
            do {
                let result = try await fetchShareStatus(helperURL, roundId, nullifierHex)
                if result == .confirmed {
                    confirmedShares.append(ShareDelegationKey(
                        bundleIndex: share.bundleIndex,
                        proposalId: share.proposalId,
                        shareIndex: share.shareIndex
                    ))
                    confirmed = true
                    break
                }
            } catch {
                votingLogger.warning("Share status check failed for helper \(helperURL), share \(share.shareIndex): \(error)")
            }
        }

        if !confirmed && shouldResubmitShare(share, now: now, voteEndTime: voteEndTime) {
            resubmissionShares.append(share)
        }
    }

    return ShareRecoveryPollResult(
        confirmedShares: confirmedShares,
        resubmissionShares: resubmissionShares,
        queriedCount: queriedCount
    )
}

extension Voting {
    func reduceNavigation(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {

        // MARK: - Navigation

        case .dismissFlow:
            state.screenStack = [.loading]
            return .merge(
                .cancel(id: cancelStateStreamId),
                .cancel(id: cancelStatusPollingId),
                .cancel(id: cancelPipelineId),
                .cancel(id: cancelDelegationProofId),
                .cancel(id: cancelDelegationPrecomputeId),
                .cancel(id: cancelNewRoundPollingId),
                .cancel(id: cancelShareTrackingId)
            )

        case .goBack:
            if state.screenStack.count > 1 {
                state.screenStack.removeLast()
            }
            return .none

        case .howToVoteContinueTapped:
            if state.isKeystoneUser {
                state.$hasSeenHowToVoteKeystone.withLock { $0 = true }
            } else {
                state.$hasSeenHowToVote.withLock { $0 = true }
            }
            state.screenStack = [.loading]
            return .send(.initialize)

        case .openConfigSettings:
            state.configSettings = .init()
            return .none

        case .configSettings(.dismiss):
            // Always re-fetch service config + rounds after the sheet closes.
            // Equality on `votingConfigOverrideURL` alone is unreliable: the
            // child's `@Shared(.appStorage(.votingConfigOverrideURL))` write can
            // land before the parent's `State` field observes the new value when
            // this dismiss runs, so we'd skip `.initialize` and stay on stale
            // endpoints / default-unverified behavior until another trigger.
            guard !state.isSubmittingVote else {
                return .none
            }
            return .send(.initialize)

        case .configSettings:
            return .none

        case .viewMyVotesTapped(let roundId):
            // Reuse roundTapped to load the session and navigate into it.
            // The proposal list will show confirmed votes in read-only mode.
            return .send(.roundTapped(roundId))

        case .backToRoundsList:
            // Cancel per-round effects and re-fetch rounds. allRoundsLoaded
            // sees the cleared activeSession and re-renders the polls list.
            state.screenStack = [.loading]
            // Clean up persisted drafts for the current round
            Self.clearPersistedDrafts(walletId: state.walletId, roundId: state.roundId)
            // Reset per-round state
            state.activeSession = nil
            state.votes = [:]
            state.votingWeight = 0
            state.walletNotes = []
            state.noteWitnessResults = []
            state.cachedWitnesses = []
            state.witnessTiming = nil
            state.witnessStatus = .notStarted
            state.delegationProofStatus = .notStarted
            state.isDelegationProofInFlight = false
            state.delegationPrecomputeStatus = .notStarted
            state.isDelegationPrecomputeInFlight = false
            state.pendingBatchSubmission = false
            state.currentKeystoneBundleIndex = 0
            state.keystoneBundleSignatures = []
            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil
            state.keystoneSigningStatus = .idle
            state.hotkeyAddress = nil
            state.isSubmittingVote = false
            state.submittingProposalId = nil
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            state.draftVotes = [:]
            state.batchSubmissionStatus = .idle
            state.batchVoteErrors = [:]
            state.tallyResults = [:]
            state.isLoadingTallyResults = false
            state.ineligibilityReason = nil
            state.showShareInfoSheet = false
            state.shareTrackingStatus = .idle
            state.shareDelegations = []
            state.voteRecord = nil
            // Refresh the rounds list
            return .merge(
                .cancel(id: cancelStateStreamId),
                .cancel(id: cancelStatusPollingId),
                .cancel(id: cancelPipelineId),
                .cancel(id: cancelDelegationProofId),
                .cancel(id: cancelDelegationPrecomputeId),
                .cancel(id: cancelNewRoundPollingId),
                .cancel(id: cancelShareTrackingId),
                .run { [votingAPI] send in
                    let allRounds = try await votingAPI.fetchAllRounds()
                    await send(.allRoundsLoaded(allRounds))
                } catch: { error, _ in
                    votingLogger.error("Failed to refresh rounds list: \(error)")
                }
            )

        case .doneTapped:
            state.screenStack = [.pollsList, .proposalList]
            return .none

        // MARK: - Share Info Sheet

        case .showShareInfo(let proposalId):
            state.shareInfoProposalId = proposalId
            state.showShareInfoSheet = true
            return .none

        case .hideShareInfo:
            state.showShareInfoSheet = false
            state.shareInfoProposalId = nil
            return .none

        // MARK: - Share Delegation Tracking (DB-backed)

        case .loadShareDelegations:
            return .run { [roundId = state.votingRound.id, votingCrypto] send in
                let delegations = try await votingCrypto.getShareDelegations(roundId)
                await send(.shareDelegationsLoaded(delegations))
            } catch: { error, _ in
                // Share tracking is non-critical — silently degrade
                votingLogger.error("Failed to load share delegations: \(error)")
            }

        case .shareDelegationsLoaded(let delegations):
            state.shareDelegations = delegations
            let allConfirmed = !delegations.isEmpty && delegations.allSatisfy(\.confirmed)
            if delegations.isEmpty {
                state.shareTrackingStatus = .idle
            } else if allConfirmed {
                state.shareTrackingStatus = .fullyConfirmed
            } else {
                state.shareTrackingStatus = .tracking
                // Start the single poll loop
                return .run { send in
                    try await Task.sleep(for: .seconds(1))
                    await send(.pollShareStatus)
                }
                .cancellable(id: cancelShareTrackingId, cancelInFlight: true)
            }
            return .none

        case .shareDelegationsRefreshed(let delegations):
            // Update state only — called from the poll loop. Does NOT start a new poll.
            state.shareDelegations = delegations
            let allConfirmed = !delegations.isEmpty && delegations.allSatisfy(\.confirmed)
            if delegations.isEmpty {
                state.shareTrackingStatus = .idle
            } else if allConfirmed {
                state.shareTrackingStatus = .fullyConfirmed
            } else {
                state.shareTrackingStatus = .tracking
            }
            return .none

        case .pollShareStatus:
            guard state.shareTrackingStatus == .tracking else { return .none }
            return .run { [
                roundId = state.votingRound.id,
                votes = state.votes,
                proposals = state.votingRound.proposals,
                singleShare = state.activeSession?.isLastMoment ?? false,
                voteEndTime = UInt64(state.activeSession?.voteEndTime.timeIntervalSince1970 ?? 0),
                votingAPI, votingCrypto
            ] send in
                // Load fresh delegations from DB so we don't re-query already-confirmed shares.
                let freshDelegations = (try? await votingCrypto.getShareDelegations(roundId)) ?? []
                let confirmed = freshDelegations.filter(\.confirmed).count
                let unconfirmed = freshDelegations.filter { !$0.confirmed }
                let now = UInt64(Date().timeIntervalSince1970)

                votingLogger.debug("[SharePoll] total=\(freshDelegations.count) confirmed=\(confirmed) unconfirmed=\(unconfirmed.count)")

                // Track shares that need resubmission (still pending after overdue threshold)
                struct ResubmitCandidate {
                    let share: VotingShareDelegation
                    let proposalId: UInt32
                    let bundleIndex: UInt32
                }
                var resubmitQueue: [ResubmitCandidate] = []

                // Check confirmation after the helper had time to process the share.
                // Delayed shares use submitAt; immediate shares use createdAt.
                let checkGrace: UInt64 = 10
                let readyShares = unconfirmed.filter { share in
                    isShareReadyForStatusCheck(share, now: now, checkGrace: checkGrace)
                }
                let futureCount = unconfirmed.count - readyShares.count

                votingLogger.debug("[SharePoll] ready=\(readyShares.count) future=\(futureCount)")

                let pollResult = await pollShareStatusesForRecovery(
                    readyShares: readyShares,
                    roundId: roundId,
                    now: now,
                    voteEndTime: voteEndTime,
                    fetchShareStatus: votingAPI.fetchShareStatus
                )

                var newlyConfirmed = 0
                for key in pollResult.confirmedShares {
                    do {
                        try await votingCrypto.markShareConfirmed(
                            roundId, key.bundleIndex, key.proposalId, key.shareIndex
                        )
                        newlyConfirmed += 1
                    } catch {
                        votingLogger.warning("Failed to mark share confirmed for proposal \(key.proposalId), share \(key.shareIndex): \(error)")
                    }
                }

                resubmitQueue = pollResult.resubmissionShares.map {
                    ResubmitCandidate(
                        share: $0,
                        proposalId: $0.proposalId,
                        bundleIndex: $0.bundleIndex
                    )
                }

                if !readyShares.isEmpty {
                    votingLogger.debug("[SharePoll] queried=\(pollResult.queriedCount) newlyConfirmed=\(newlyConfirmed)")
                }

                // Phase 2: Resubmit overdue pending shares
                // Group by (bundleIndex, proposalId) to rebuild payloads once per group
                let grouped = Dictionary(grouping: resubmitQueue) { "\($0.bundleIndex):\($0.proposalId)" }
                for (_, candidates) in grouped {
                    guard let first = candidates.first else { continue }
                    let bundleIndex = first.bundleIndex
                    let proposalId = first.proposalId

                    // Rebuild share payloads from the stored commitment bundle (includes vcTreePosition)
                    guard let result = try? await votingCrypto.getVoteCommitmentBundleWithPosition(roundId, bundleIndex, proposalId),
                          let choice = votes[proposalId]
                    else { continue }
                    let savedBundle = result.bundle
                    let vcTreePosition = result.vcTreePosition
                    let numOptions = UInt32(proposals.first { $0.id == proposalId }?.options.count ?? 3)

                    do {
                        var payloads = try await votingCrypto.buildSharePayloads(
                            savedBundle.encShares, savedBundle, choice, numOptions,
                            vcTreePosition, singleShare
                        )
                        // Set submit_at to 0 (immediate) for resubmission
                        for i in payloads.indices {
                            payloads[i].submitAt = 0
                        }

                        // Resubmit only the shares that are overdue
                        for candidate in candidates {
                            guard let payload = payloads.first(where: {
                                $0.encShare.shareIndex == candidate.share.shareIndex
                            }) else { continue }

                            let acceptedServers = try await votingAPI.resubmitShare(
                                payload,
                                roundId,
                                candidate.share.sentToURLs
                            )
                            let newServers = acceptedServers.filter {
                                !candidate.share.sentToURLs.contains($0)
                            }

                            if !newServers.isEmpty {
                                // Record the new servers in DB
                                try await votingCrypto.addSentServers(
                                    roundId, bundleIndex, proposalId,
                                    candidate.share.shareIndex, newServers
                                )
                                votingLogger.info("Resubmitted share p\(proposalId)s\(candidate.share.shareIndex) to \(newServers.count) new server(s)")
                            }
                        }
                    } catch {
                        votingLogger.warning("Share resubmission failed for bundle \(bundleIndex), proposal \(proposalId): \(error)")
                    }
                }

                // Reload fresh state from DB and update the UI (without starting a new poll)
                let updatedDelegations = (try? await votingCrypto.getShareDelegations(roundId)) ?? freshDelegations
                await send(.shareDelegationsRefreshed(updatedDelegations))

                // Schedule next poll: sleep until the next share is ready to check.
                let refreshedNow = UInt64(Date().timeIntervalSince1970)
                let stillUnconfirmed = updatedDelegations.filter { !$0.confirmed }

                // Find the soonest unconfirmed share's check time.
                let futureCheckTimes = stillUnconfirmed.compactMap { share -> UInt64? in
                    let readyAt = shareRecoveryBaseTime(share) + checkGrace
                    return readyAt > refreshedNow ? readyAt : nil
                }

                let sleepSeconds: UInt64
                if stillUnconfirmed.isEmpty {
                    votingLogger.debug("[SharePoll] all confirmed, stopping poll")
                    return
                } else if let soonest = futureCheckTimes.min() {
                    sleepSeconds = min(soonest - refreshedNow, 30)
                } else {
                    sleepSeconds = 15
                }

                let actualSleep = max(sleepSeconds, 3)
                votingLogger.debug("[SharePoll] sleeping \(actualSleep)s (stillUnconfirmed=\(stillUnconfirmed.count) futureShares=\(futureCheckTimes.count))")
                try await Task.sleep(for: .seconds(actualSleep))
                await send(.pollShareStatus)
            } catch: { _, _ in }
            .cancellable(id: cancelShareTrackingId, cancelInFlight: true)

        // MARK: - Proposal List

        case .proposalTapped(let id):
            state.selectedProposalId = id
            // Entering the detail from Review starts an edit session. Snapshot
            // the current draft so Cancel can discard any changes; Save is a
            // no-op on draftVotes since castVote already persists each tap.
            if case .reviewVotes = state.currentScreen {
                state.editingFromReview = State.EditingFromReviewSnapshot(
                    proposalId: id,
                    priorDraft: state.draftVotes[id]
                )
            }
            state.screenStack.append(.proposalDetail(id: id))
            return .none

        // MARK: - Proposal Detail

        case let .castVote(proposalId, choice):
            guard state.voteRecord == nil else { return .none }
            guard state.votes[proposalId] == nil else { return .none }
            if state.draftVotes[proposalId] == choice {
                state.draftVotes.removeValue(forKey: proposalId)
            } else {
                state.draftVotes[proposalId] = choice
            }
            Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
            return .none

        case .voteSubmissionBundleStarted(let index):
            state.currentVoteBundleIndex = index
            state.voteSubmissionStep = .preparingProof
            return .none

        case .voteSubmissionStepUpdated(let step):
            state.voteSubmissionStep = step
            return .none

        case .advanceAfterVote:
            state.isSubmittingVote = false
            state.submittingProposalId = nil
            state.voteSubmissionStep = nil
            state.currentVoteBundleIndex = nil
            // Return to proposal list so the user can pick their next vote freely.
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            }
            // Auto-resume: if there are remaining drafts after a crash-recovered
            // vote, continue submitting.
            if state.canSubmitBatch {
                let remainingCount = state.draftVotes.count
                votingLogger.info("Auto-resuming batch submission with \(remainingCount) remaining drafts")
                return .send(.submitAllDrafts)
            }
            // Vote finished — start share tracking now that delegation rows are written.
            if !state.votes.isEmpty && state.shareTrackingStatus == .idle {
                state.shareTrackingStatus = .loading
                return .send(.loadShareDelegations)
            }
            return .none

        case .cancelEdit:
            // Revert the edited proposal's draft to the snapshot captured when
            // the session started. `nil` prior draft means "not drafted before
            // edit", so we remove whatever was set during the session.
            if let snapshot = state.editingFromReview {
                if let prior = snapshot.priorDraft {
                    state.draftVotes[snapshot.proposalId] = prior
                } else {
                    state.draftVotes.removeValue(forKey: snapshot.proposalId)
                }
                Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
                state.editingFromReview = nil
            }
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            }
            return .none

        case .saveEdit:
            // Draft already reflects the user's choices via .castVote — just
            // close the edit session and return to Review.
            state.editingFromReview = nil
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            }
            return .none

        case .backToList:
            // Any exit path other than Cancel leaves the draft as-is; clearing
            // the snapshot so a subsequent tap into detail (from the list
            // proper, not Review) doesn't inherit stale edit-session state.
            state.editingFromReview = nil
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            } else if case .confirmSubmission = state.currentScreen {
                state.screenStack.removeLast()
            } else if case .reviewVotes = state.currentScreen {
                state.screenStack.removeLast()
            } else if case .proposalList = state.currentScreen, state.screenStack.count > 1 {
                state.screenStack.removeLast()
            }
            return .none

        case .nextProposalDetail:
            guard let index = state.detailProposalIndex else { return .none }
            let isLast = index == state.votingRound.proposals.count - 1

            if isLast {
                if state.allDrafted {
                    // All answered -> review
                    state.screenStack.removeLast()
                    state.screenStack.append(.reviewVotes)
                }
                // If unanswered -> .none; view handles sheet display
            } else {
                let nextId = state.votingRound.proposals[index + 1].id
                state.selectedProposalId = nextId
                state.screenStack.removeLast()
                state.screenStack.append(.proposalDetail(id: nextId))
            }
            return .none

        case .navigateToReview:
            state.screenStack.append(.reviewVotes)
            return .none

        case .navigateToConfirmation:
            state.screenStack.append(.confirmSubmission)
            return .none

        case .confirmUnanswered:
            guard state.voteRecord == nil else { return .none }
            // Auto-draft Abstain for every unanswered proposal, then go to review.
            for proposal in state.votingRound.proposals
                where state.draftVotes[proposal.id] == nil && state.votes[proposal.id] == nil {
                let abstainIndex: UInt32
                if let existing = proposal.options.first(where: {
                    $0.label.localizedCaseInsensitiveContains("abstain")
                }) {
                    abstainIndex = existing.index
                } else {
                    abstainIndex = (proposal.options.map(\.index).max() ?? 0) + 1
                }
                state.draftVotes[proposal.id] = .option(abstainIndex)
            }
            Self.persistDrafts(state.draftVotes, walletId: state.walletId, roundId: state.roundId)
            state.screenStack.removeLast()
            state.screenStack.append(.reviewVotes)
            return .none

        case .dismissUnanswered:
            if case .proposalDetail = state.currentScreen {
                state.screenStack.removeLast()
            }
            return .none

        case .previousProposalDetail:
            if let index = state.detailProposalIndex, index > 0 {
                let prevId = state.votingRound.proposals[index - 1].id
                state.selectedProposalId = prevId
                state.screenStack.removeLast()
                state.screenStack.append(.proposalDetail(id: prevId))
            }
            return .none

        default:
            return .none
        }
    }
}
