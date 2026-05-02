import Combine
import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

// MARK: - Delegation (Witness Verification, Round Resume, Delegation Signing, ZKP)

func votingSeedFingerprint(for account: WalletAccount?) -> Data? {
    if let seedFingerprint = account?.seedFingerprint, seedFingerprint.count == 32 {
        return Data(seedFingerprint)
    }
    return nil
}

func votingAccountIndex(for account: WalletAccount?) -> UInt32 {
    account.flatMap(\.zip32AccountIndex).map { UInt32($0.index) } ?? 0
}

/// `senderSeed` is unused in seedless PCZT prep — when an Orchard FVK override and a
/// seed fingerprint are supplied, `buildVotingPczt` derives `ak` from the FVK directly
/// and never touches the seed. Pass this at those call sites instead of a bare `[]`.
let emptySenderSeed: [UInt8] = []

private enum DelegationTxConfirmationStatus: Sendable {
    case confirmed(vanPosition: UInt32)
    case failed(code: UInt32, log: String)
    case notFound
}

extension Voting {
    func reduceDelegation(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {

        // MARK: - Witness Verification

        case .verifyWitnesses:
            guard let activeSession = state.activeSession else {
                state.witnessStatus = .failed(String(localizable: .coinVoteStoreErrorMissingActiveSession))
                return .none
            }
            state.witnessTiming = nil
            let roundId = activeSession.voteRoundId.hexString
            let snapshotHeight = activeSession.snapshotHeight
            let notes = state.walletNotes
            let network = zcashSDKEnvironment.network
            let walletDbPath = databaseFiles.dataDbURLFor(network).path
            return .run { [sdkSynchronizer, votingCrypto, votingAPI] send in
                // Check if this round already exists and ALL bundles have proofs
                let existingState = try? await votingCrypto.getRoundState(roundId)
                let alreadyAuthorized = existingState?.proofGenerated ?? false

                if alreadyAuthorized {
                    await send(.roundResumeChecked(alreadyAuthorized: true))
                    return
                }

                // --- Crash recovery: check if some delegation TXs already landed on-chain ---
                let existingBundleCount = (try? await votingCrypto.getBundleCount(roundId)) ?? 0

                var recoveredDelegationHashes: [(UInt32, String)] = []
                for bundleIndex: UInt32 in 0..<existingBundleCount {
                    if case let .present(txHash)? = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) {
                        recoveredDelegationHashes.append((bundleIndex, txHash))
                    }
                }

                if !recoveredDelegationHashes.isEmpty {
                    var recoveredPositions: [UInt32: UInt32] = [:]
                    for (bundleIndex, txHash) in recoveredDelegationHashes {
                        if let vanPosition = try? await Self.recoverDelegationVanPosition(
                            roundId: roundId,
                            bundleIndex: bundleIndex,
                            txHash: txHash,
                            votingCrypto: votingCrypto,
                            votingAPI: votingAPI,
                            confirmationTimeout: 0,
                            retryDelay: .zero
                        ) {
                            recoveredPositions[bundleIndex] = vanPosition
                        }
                    }

                    if existingBundleCount > 0 && UInt32(recoveredPositions.count) >= existingBundleCount {
                        try await votingCrypto.clearRecoveryState(roundId)
                        await send(.roundResumeChecked(alreadyAuthorized: true))
                        return
                    } else if !recoveredPositions.isEmpty {
                        await send(.witnessPreparationStarted)
                        let count = try await votingCrypto.getBundleCount(roundId)
                        await send(.witnessVerificationCompleted([], [], .init(treeStateFetchMs: 0, witnessGenerationMs: 0, verificationMs: 0), count))
                        return
                    }
                }

                await send(.witnessPreparationStarted)

                try? await votingCrypto.clearRound(roundId)
                try await votingCrypto.clearRecoveryState(roundId)
                let params = VotingRoundParams(
                    voteRoundId: activeSession.voteRoundId,
                    snapshotHeight: snapshotHeight,
                    eaPK: activeSession.eaPK,
                    ncRoot: activeSession.ncRoot,
                    nullifierIMTRoot: activeSession.nullifierIMTRoot
                )
                try await votingCrypto.initRound(params, nil)

                // Skip witness pipeline if wallet has no notes at snapshot height
                guard !notes.isEmpty else {
                    let emptyTiming = Voting.State.WitnessTiming(
                        treeStateFetchMs: 0,
                        witnessGenerationMs: 0,
                        verificationMs: 0
                    )
                    await send(.witnessVerificationCompleted([], [], emptyTiming, 0))
                    return
                }

                // Setup bundles (value-aware split into groups of up to 5)
                let setupResult = try await votingCrypto.setupBundles(roundId, notes)
                let bundleCount = setupResult.bundleCount
                votingLogger.info("Setup \(bundleCount) bundle(s) for \(notes.count) notes (eligible weight: \(setupResult.eligibleWeight))")

                // Phase 1: Fetch tree state from lightwalletd
                let fetchStart = ContinuousClock.now
                let treeStateBytes = try await sdkSynchronizer.getTreeState(snapshotHeight)
                try await votingCrypto.storeTreeState(roundId, treeStateBytes)
                let fetchEnd = ContinuousClock.now
                let fetchMs = UInt64(fetchStart.duration(to: fetchEnd).components.seconds * 1000)
                    + UInt64(fetchStart.duration(to: fetchEnd).components.attoseconds / 1_000_000_000_000_000)
                votingLogger.debug("Tree state fetch: \(fetchMs)ms")

                // Phase 2: Generate witnesses per-bundle (includes Rust-side verification)
                let noteChunks = notes.smartBundles().bundles
                var allWitnesses: [WitnessData] = []
                for bundleIndex in 0..<bundleCount {
                    let chunkNotes = noteChunks[Int(bundleIndex)]
                    let witnesses = try await votingCrypto.generateNoteWitnesses(
                        roundId, bundleIndex, walletDbPath, chunkNotes
                    )
                    allWitnesses.append(contentsOf: witnesses)
                }
                let genEnd = ContinuousClock.now
                let genMs = UInt64(fetchEnd.duration(to: genEnd).components.seconds * 1000)
                    + UInt64(fetchEnd.duration(to: genEnd).components.attoseconds / 1_000_000_000_000_000)
                votingLogger.debug("Witness generation: \(genMs)ms (\(allWitnesses.count) notes)")

                // Phase 3: Verify each witness on Swift side for UI display
                let sortedNotes = noteChunks.flatMap { $0 }
                var results: [Voting.State.NoteWitnessResult] = []
                for (idx, witness) in allWitnesses.enumerated() {
                    let verified = (try? await votingCrypto.verifyWitness(witness)) ?? false
                    let note = sortedNotes[idx]
                    results.append(.init(position: note.position, value: note.value, verified: verified))
                    votingLogger.debug("Note pos=\(note.position) value=\(note.value) verified=\(verified)")
                }
                let verifyEnd = ContinuousClock.now
                let verifyMs = UInt64(genEnd.duration(to: verifyEnd).components.seconds * 1000)
                    + UInt64(genEnd.duration(to: verifyEnd).components.attoseconds / 1_000_000_000_000_000)
                votingLogger.debug("Swift verification: \(verifyMs)ms")
                votingLogger.info("Total witness pipeline: \(fetchMs + genMs + verifyMs)ms")

                let timing = Voting.State.WitnessTiming(
                    treeStateFetchMs: fetchMs,
                    witnessGenerationMs: genMs,
                    verificationMs: verifyMs
                )
                await send(.witnessVerificationCompleted(results, allWitnesses, timing, bundleCount))
            } catch: { error, send in
                votingLogger.error("Witness verification failed: \(error)")
                await send(.witnessVerificationFailed(error.localizedDescription))
            }

        case .witnessPreparationStarted:
            // Only shown for fresh rounds (not cached). This avoids a brief
            // flash of "Preparing note witnesses..." when resuming a round.
            state.witnessStatus = .inProgress
            state.delegationProofStatus = .notStarted
            state.delegationPrecomputeStatus = .notStarted
            state.isDelegationPrecomputeInFlight = false
            return .none

        case .rerunWitnessVerification:
            // Invalidate cached witnesses and re-run from scratch
            state.noteWitnessResults = []
            state.cachedWitnesses = []
            state.witnessTiming = nil
            state.delegationPrecomputeStatus = .notStarted
            state.isDelegationPrecomputeInFlight = false
            return .merge(.cancel(id: cancelDelegationPrecomputeId), .send(.verifyWitnesses))

        case let .witnessVerificationCompleted(results, witnesses, timing, bundleCount):
            state.noteWitnessResults = results
            state.cachedWitnesses = witnesses
            state.witnessTiming = timing
            state.witnessStatus = .completed
            state.bundleCount = bundleCount
            // If bundles were previously skipped, the DB count is less than the
            // total from smartBundles(). Recalculate votingWeight to reflect only
            // the kept bundles (quantized per bundle).
            let allBundles = state.walletNotes.smartBundles().bundles
            if bundleCount > 0, Int(bundleCount) < allBundles.count {
                state.votingWeight = (0..<Int(bundleCount)).reduce(UInt64(0)) { total, i in
                    let raw = allBundles[i].reduce(UInt64(0)) { $0 + $1.value }
                    return total + quantizeWeight(raw)
                }
            }
            // Delegation (ZKP #1) is deferred until the user submits their vote.
            // Witnesses are ready; start seedless PIR prep if the hotkey is also ready.
            return .send(.maybeStartDelegationPrecompute)

        case .witnessVerificationFailed(let error):
            let message = VotingErrorMapper.userFriendlyMessage(from: error)
            state.witnessStatus = .failed(message)
            state.delegationProofStatus = .failed(message)
            state.isDelegationProofInFlight = false
            state.delegationPrecomputeStatus = .failed(message)
            state.isDelegationPrecomputeInFlight = false
            return .none

        // MARK: - Round Resume

        case .roundResumeChecked(let alreadyAuthorized):
            if alreadyAuthorized {
                state.delegationProofStatus = .complete
                state.screenStack = [.pollsList, .proposalList]
                state.witnessStatus = .completed
                // Restore bundleCount from the DB so vote casting knows how many bundles to iterate.
                // Start state stream to sync votes and hotkey from the existing round,
                // then trigger a refresh so the current DB state is published
                // (stateStream uses dropFirst, so without this the existing value is lost).
                let roundId = state.roundId
                return .merge(
                    .run { [votingCrypto] send in
                        let count = try await votingCrypto.getBundleCount(roundId)
                        await send(.bundleCountRestored(count))
                    } catch: { error, send in
                        votingLogger.error("Failed to restore bundle count: \(error)")
                        await send(.witnessVerificationFailed(
                            String(localizable: .coinVoteDelegationRestoreVotingStateFailed(error.localizedDescription))
                        ))
                    },
                    .publisher {
                        votingCrypto.stateStream()
                            .receive(on: DispatchQueue.main)
                            .map(Action.votingDbStateChanged)
                    }
                    .cancellable(id: cancelStateStreamId, cancelInFlight: true),
                    .run { _ in
                        await votingCrypto.refreshState(roundId)
                    }
                )
            }
            return .none

        case .bundleCountRestored(let count):
            state.bundleCount = count
            // If bundles were previously skipped, the DB count is less than the
            // total from smartBundles(). Recalculate votingWeight to reflect only
            // the kept bundles (quantized per bundle).
            let allBundles = state.walletNotes.smartBundles().bundles
            if count > 0, Int(count) < allBundles.count {
                state.votingWeight = (0..<Int(count)).reduce(UInt64(0)) { total, i in
                    let raw = allBundles[i].reduce(UInt64(0)) { $0 + $1.value }
                    return total + quantizeWeight(raw)
                }
            }
            let roundId = state.roundId
            let bundleCount = count
            return .run { [votingCrypto] send in
                let votes = (try? await votingCrypto.getVotes(roundId)) ?? []

                // Check 1: a TX hash exists but the vote isn't marked as submitted
                // in the DB yet (crash during step 2 or 3 of a bundle).
                // Add the vote to draftVotes and let submitAllDrafts handle recovery.
                let unsubmitted = votes.filter { !$0.submitted }
                for vote in unsubmitted {
                    if case .present? = try? await votingCrypto.getVoteTxHash(roundId, vote.bundleIndex, vote.proposalId) {
                        votingLogger.info("Vote resume: found in-flight vote for proposal \(vote.proposalId), auto-resuming via batch path")
                        await send(.setDraftVote(proposalId: vote.proposalId, choice: vote.choice))
                        await send(.submitAllDrafts)
                        return
                    }
                }

                // Check 2: partial vote — some bundles submitted, but fewer
                // VoteRecords than bundleCount (crash before a later bundle's
                // buildVoteCommitment created a VoteRecord).
                if bundleCount > 1 {
                    var byProposal: [UInt32: (submitted: Int, total: Int, choice: VoteChoice)] = [:]
                    for vote in votes {
                        var entry = byProposal[vote.proposalId] ?? (submitted: 0, total: 0, choice: vote.choice)
                        entry.total += 1
                        if vote.submitted { entry.submitted += 1 }
                        byProposal[vote.proposalId] = entry
                    }
                    for (proposalId, info) in byProposal {
                        if info.submitted > 0, info.total < Int(bundleCount) {
                            votingLogger.info("Vote resume: proposal \(proposalId) has \(info.total)/\(bundleCount) bundle records, resuming via batch path")
                            await send(.setDraftVote(proposalId: proposalId, choice: info.choice))
                            await send(.submitAllDrafts)
                            return
                        }
                    }
                }
            }

        // MARK: - Delegation Signing

        case .copyHotkeyAddress:
            if let address = state.hotkeyAddress {
                pasteboard.setString(address.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
            }
            return .none

        case .delegationApproved:
            // User is already on the proposal list; delegation signing screen
            // was pushed on top. Just trigger the proof pipeline.
            return .send(.startDelegationProof)

        case .delegationRejected:
            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil
            state.keystoneSigningStatus = .idle
            state.keystoneBundleSignatures = []
            state.isDelegationProofInFlight = false
            // Cancel any pending submission that triggered delegation.
            state.pendingBatchSubmission = false
            state.isSubmittingVote = false
            // Pop the delegation signing screen back to proposals.
            if state.screenStack.last == .delegationSigning {
                state.screenStack.removeLast()
                return .none
            }
            return .send(.dismissFlow)

        case .retryKeystoneSigning:
            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil
            state.keystoneSigningStatus = .idle
            state.currentKeystoneBundleIndex = 0
            state.isDelegationProofInFlight = false
            state.keystoneBundleSignatures = []
            return .send(.startDelegationProof)

        // MARK: - ZKP Delegation

        case .maybeStartDelegationPrecompute:
            guard !state.isKeystoneUser else { return .none }
            guard !state.isDelegationReady else { return .none }
            guard !state.isDelegationProofInFlight, !state.isDelegationPrecomputeInFlight else { return .none }
            guard state.delegationPrecomputeStatus == .notStarted else { return .none }
            guard state.witnessStatus == .completed, state.hotkeyAddress != nil else { return .none }
            guard let activeSession = state.activeSession, activeSession.status == .active else { return .none }
            guard state.bundleCount > 0, !state.walletNotes.isEmpty else { return .none }
            guard
                let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
                !pirEndpoints.isEmpty
            else {
                return .none
            }
            guard let seedFingerprint = votingSeedFingerprint(for: state.selectedWalletAccount) else {
                votingLogger.debug("Skipping delegation PIR precompute: missing selected-account seed fingerprint")
                return .none
            }

            state.delegationPrecomputeStatus = .inProgress
            state.isDelegationPrecomputeInFlight = true

            let roundId = activeSession.voteRoundId.hexString
            let expectedSnapshotHeight = activeSession.snapshotHeight
            let cachedNotes = state.walletNotes
            let bundleCount = state.bundleCount
            let network = zcashSDKEnvironment.network
            let networkId: UInt32 = network.networkType == .mainnet ? 0 : 1
            let accountIndex = votingAccountIndex(for: state.selectedWalletAccount)
            let roundName = state.votingRound.title

            return .run { [votingCrypto, mnemonic, walletStorage] send in
                let hotkeyPhrase = try walletStorage.exportVotingHotkey("").seedPhrase.value()
                let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
                let noteChunks = cachedNotes.smartBundles().bundles
                guard Int(bundleCount) <= noteChunks.count else {
                    throw "Delegation precompute bundle count exceeds prepared note bundles"
                }

                var totalCached: UInt32 = 0
                var totalFetched: UInt32 = 0
                for bundleIndex: UInt32 in 0..<bundleCount {
                    try Task.checkCancellation()
                    if case .present? = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) {
                        continue
                    }

                    let bundleNotes = noteChunks[Int(bundleIndex)]
                    guard let firstNote = bundleNotes.first else { continue }
                    let orchardFvk = try votingCrypto.extractOrchardFvkFromUfvk(firstNote.ufvkStr, networkId)

                    _ = try await votingCrypto.buildVotingPczt(
                        roundId,
                        bundleIndex,
                        bundleNotes,
                        emptySenderSeed,
                        hotkeySeed,
                        networkId,
                        accountIndex,
                        roundName,
                        orchardFvk,
                        seedFingerprint
                    )

                    let result = try await votingCrypto.precomputeDelegationPir(
                        roundId,
                        bundleIndex,
                        bundleNotes,
                        pirEndpoints,
                        expectedSnapshotHeight,
                        networkId
                    )
                    totalCached += result.cachedCount
                    totalFetched += result.fetchedCount
                    votingLogger.info(
                        "Delegation PIR precompute bundle \(bundleIndex + 1)/\(bundleCount): cached=\(result.cachedCount) fetched=\(result.fetchedCount)"
                    )
                }

                votingLogger.info("Delegation PIR precompute complete: cached=\(totalCached) fetched=\(totalFetched)")
                await send(.delegationPrecomputeCompleted(roundId: roundId))
            } catch: { error, send in
                await send(.delegationPrecomputeFailed(roundId: roundId, error: error.localizedDescription))
            }
            .cancellable(id: cancelDelegationPrecomputeId, cancelInFlight: true)

        case let .delegationPrecomputeCompleted(roundId):
            guard state.roundId == roundId else { return .none }
            state.delegationPrecomputeStatus = .ready
            state.isDelegationPrecomputeInFlight = false
            if state.pendingBatchSubmission && !state.isKeystoneUser {
                state.pendingBatchSubmission = false
                state.batchSubmissionStatus = .idle
                return .send(.authenticationSucceeded)
            }
            return .none

        case let .delegationPrecomputeFailed(roundId, error):
            guard state.roundId == roundId else { return .none }
            let message = VotingErrorMapper.userFriendlyMessage(from: error)
            state.delegationPrecomputeStatus = .failed(message)
            state.isDelegationPrecomputeInFlight = false
            if state.pendingBatchSubmission && !state.isKeystoneUser {
                state.pendingBatchSubmission = false
                state.batchSubmissionStatus = .idle
                return .send(.authenticationSucceeded)
            }
            return .none

        case .startDelegationProof:
            guard !state.isDelegationProofInFlight && state.delegationProofStatus != .complete else {
                return .none
            }
            state.isDelegationProofInFlight = true
            guard let activeSession = state.activeSession else {
                return .send(.delegationProofFailed(
                    roundId: state.roundId,
                    error: VotingFlowError.missingActiveSession.localizedDescription
                ))
            }
            let roundId = activeSession.voteRoundId.hexString
            let keystoneMetadata: (seedFingerprint: Data, accountIndex: UInt32)?
            if state.isKeystoneUser {
                guard
                    let account = state.selectedWalletAccount,
                    let zip32AccountIndex = account.zip32AccountIndex
                else {
                    return .send(.delegationProofFailed(
                        roundId: roundId,
                        error: VotingFlowError.missingSigningAccount.localizedDescription
                    ))
                }
                guard
                    let seedFingerprint = account.seedFingerprint,
                    seedFingerprint.count == 32
                else {
                    return .send(.delegationProofFailed(
                        roundId: roundId,
                        error: VotingFlowError.missingSigningAccount.localizedDescription
                    ))
                }
                keystoneMetadata = (Data(seedFingerprint), UInt32(zip32AccountIndex.index))
            } else {
                keystoneMetadata = nil
            }
            if state.isKeystoneUser {
                state.keystoneSigningStatus = .preparingRequest
            } else {
                state.delegationProofStatus = .generating(progress: 0)
            }
            let cachedNotes = state.walletNotes
            let network = zcashSDKEnvironment.network
            let networkId: UInt32 = network.networkType == .mainnet ? 0 : 1
            let isKeystoneUser = state.isKeystoneUser
            let accountIndex: UInt32 = isKeystoneUser
                ? keystoneMetadata?.accountIndex ?? 0
                : votingAccountIndex(for: state.selectedWalletAccount)
            let keystoneSeedFingerprint = keystoneMetadata?.seedFingerprint
            let pcztSeedFingerprint = isKeystoneUser
                ? keystoneSeedFingerprint
                : votingSeedFingerprint(for: state.selectedWalletAccount)
            let roundName = state.votingRound.title
            // serviceConfig is guaranteed loaded by the time the user reaches any voting
            // pipeline: the .configError gate in .initialize/.allRoundsLoaded blocks entry
            // to the voting screens when config is missing. The guard is defense-in-depth.
            guard
                let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
                !pirEndpoints.isEmpty,
                let expectedSnapshotHeight = state.activeSession?.snapshotHeight
            else {
                votingLogger.error("serviceConfig/activeSession unexpectedly nil in startActiveRoundPipeline; aborting")
                return .none
            }
            let keystoneBundleIndex = state.currentKeystoneBundleIndex
            let bundleCount = state.bundleCount
            let delegationPrepared = state.isDelegationPrecomputeReady
            return .merge(
                // Subscribe to DB state stream (follows SDKSynchronizer pattern)
                .publisher {
                    votingCrypto.stateStream()
                        .receive(on: DispatchQueue.main)
                        .map(Action.votingDbStateChanged)
                }
                .cancellable(id: cancelStateStreamId, cancelInFlight: true),
                // Run delegation proof pipeline
                // Round is already initialized and witnesses cached by verifyWitnesses
                .run { [backgroundTask, sdkSynchronizer, votingCrypto, votingAPI, mnemonic, walletStorage] send in
                    let bgTaskId = await backgroundTask.beginTask("Delegation proof generation")
                    do {
                        // Reload hotkey from keychain (generated during initialize)
                        let hotkeyPhrase = try walletStorage.exportVotingHotkey("").seedPhrase.value()
                        let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
                        if isKeystoneUser {
                            guard bundleCount > 0 else {
                                await backgroundTask.endTask(bgTaskId)
                                await send(.delegationProofCompleted(roundId: roundId))
                                return
                            }
                            // Build voting PCZT for the current bundle — its single Orchard
                            // action IS the voting dummy action, so Keystone's SpendAuth
                            // signature will verify against the PCZT's ZIP-244 sighash.
                            let noteChunks = cachedNotes.smartBundles().bundles
                            let bundleNotes = noteChunks[Int(keystoneBundleIndex)]
                            // Extract Orchard FVK from the note's UFVK so the PCZT uses
                            // Keystone's ak (matching what the ZKP prover derives from the
                            // note's ufvk_str). Without this, rk in the PCZT would be
                            // derived from the app's ak, causing a mismatch (Bug 3 fix).
                            let orchardFvk = try votingCrypto.extractOrchardFvkFromUfvk(
                                bundleNotes[0].ufvkStr, networkId
                            )
                            votingLogger.info("Keystone: preparing PCZT for bundle \(keystoneBundleIndex + 1)/\(bundleCount)")
                            let govPczt = try await votingCrypto.buildVotingPczt(
                                roundId,
                                keystoneBundleIndex,
                                bundleNotes,
                                emptySenderSeed,
                                hotkeySeed,
                                networkId,
                                accountIndex,
                                roundName,
                                orchardFvk,
                                keystoneSeedFingerprint
                            )
                            let redactedPczt = try await sdkSynchronizer
                                .redactPCZTForSigner(govPczt.pcztBytes)
                            await backgroundTask.endTask(bgTaskId)
                            await send(.keystoneSigningPrepared(roundId: roundId, govPczt, redactedPczt))
                            return
                        }

                        // Non-Keystone path: delegate using shared pipeline helper.
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
                            seedFingerprint: pcztSeedFingerprint,
                            votingCrypto: votingCrypto,
                            votingAPI: votingAPI,
                            send: send
                        )
                    } catch {
                        await backgroundTask.endTask(bgTaskId)
                        throw error
                    }
                    await backgroundTask.endTask(bgTaskId)
                } catch: { error, send in
                    if isKeystoneUser {
                        await send(.keystoneSigningFailed(roundId: roundId, error: error.localizedDescription))
                    } else {
                        await send(.delegationProofFailed(roundId: roundId, error: error.localizedDescription))
                    }
                }
                .cancellable(id: cancelDelegationProofId, cancelInFlight: true)
            )

        case let .keystoneSigningPrepared(roundId, govPczt, unsignedPczt):
            guard state.roundId == roundId else { return .none }
            state.pendingVotingPczt = govPczt

            state.pendingUnsignedDelegationPczt = unsignedPczt
            state.keystoneSigningStatus = .awaitingSignature
            return .none

        case .keystoneSigningFailed(let roundId, let error):
            guard state.roundId == roundId else { return .none }
            state.keystoneSigningStatus = .failed(VotingErrorMapper.userFriendlyMessage(from: error))
            return .none

        case .openKeystoneSignatureScan:
            keystoneHandler.resetQRDecoder()
            var scanState = Scan.State.initial
            scanState.instructions = String(localizable: .coinVoteDelegationSigningScanInstructions)
            scanState.checkers = [.keystoneVotingDelegationPCZTScanChecker]
            state.keystoneScan = scanState
            return .none

        case .keystoneScan(.presented(.foundVotingDelegationPCZT(let signedPczt))):
            state.keystoneScan = nil
            state.keystoneSigningStatus = .parsingSignature
            guard let govPczt = state.pendingVotingPczt else {
                return .send(.spendAuthSignatureExtractionFailed(
                    VotingFlowError.missingPendingUnsignedPczt.localizedDescription
                ))
            }
            let actionIndex = govPczt.actionIndex
            return .run { [votingCrypto] send in
                let spendAuthSig = try votingCrypto.extractSpendAuthSignatureFromSignedPczt(
                    signedPczt,
                    actionIndex
                )
                await send(.spendAuthSignatureExtracted(spendAuthSig, signedPczt))
            } catch: { error, send in
                await send(.spendAuthSignatureExtractionFailed(error.localizedDescription))
            }

        case .keystoneScan(.presented(.cancelTapped)),
            .keystoneScan(.dismiss):
            state.keystoneScan = nil
            return .none

        case .keystoneScan:
            return .none

        case let .spendAuthSignatureExtracted(keystoneSig, signedPczt):
            guard let rk = state.pendingVotingPczt?.rk else { // swiftlint:disable:this identifier_name
                return .send(.delegationProofFailed(
                    roundId: state.roundId,
                    error: VotingFlowError.missingPendingUnsignedPczt.localizedDescription
                ))
            }

            // Extract ZIP-244 sighash from the signed PCZT synchronously in a
            // lightweight .run so we can store it alongside the sig.
            let bundleCount = state.bundleCount
            let currentIndex = state.currentKeystoneBundleIndex
            return .run { [votingCrypto] send in
                let keystoneSighash = try votingCrypto.extractPcztSighash(signedPczt)
                // Store signature for this bundle
                await send(.keystoneBundleSignatureStored(
                    .init(sig: keystoneSig, sighash: keystoneSighash, rk: rk),
                    bundleIndex: currentIndex,
                    bundleCount: bundleCount
                ))
            } catch: { error, send in
                await send(.spendAuthSignatureExtractionFailed(error.localizedDescription))
            }

        case let .keystoneBundleSignatureStored(signature, bundleIndex, bundleCount):
            state.keystoneBundleSignatures.append(signature)
            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil

            // Persist to recovery store so signatures survive app restarts
            let roundId = state.roundId
            let sigInfo = KeystoneBundleSignatureInfo(
                bundleIndex: bundleIndex,
                sig: signature.sig,
                sighash: signature.sighash,
                rk: signature.rk
            )
            let persistEffect: Effect<Action> = .run { [votingCrypto] _ in
                try await votingCrypto.storeKeystoneBundleSignature(roundId, sigInfo)
            }

            if bundleIndex + 1 < bundleCount {
                // More bundles to sign — advance index, then auto-start the next bundle's PCZT.
                state.currentKeystoneBundleIndex += 1
                state.isDelegationProofInFlight = false
                state.keystoneSigningStatus = .idle
                return .merge(persistEffect, .send(.delegationApproved))
            } else {
                // All bundles signed — pop delegation signing and show the
                // submission screen with the authorizing progress bar while
                // the ZKP proof is generated and delegation TX submitted.
                state.keystoneSigningStatus = .idle
                state.delegationProofStatus = .generating(progress: 0)
                state.batchSubmissionStatus = .authorizing
                state.voteSubmissionStep = .authorizingVote
                if state.screenStack.last == .delegationSigning {
                    state.screenStack.removeLast()
                }
                return .merge(persistEffect, .send(.keystoneAllBundlesSigned))
            }

        case .keystoneAllBundlesSigned:
            guard let activeSession = state.activeSession else {
                return .send(.delegationProofFailed(
                    roundId: state.roundId,
                    error: VotingFlowError.missingActiveSession.localizedDescription
                ))
            }

            let roundId = activeSession.voteRoundId.hexString
            let expectedSnapshotHeight = activeSession.snapshotHeight
            let cachedNotes = state.walletNotes
            let network = zcashSDKEnvironment.network
            let networkId: UInt32 = network.networkType == .mainnet ? 0 : 1
            let accountIndex: UInt32 = state.selectedWalletAccount.flatMap(\.zip32AccountIndex).map { UInt32($0.index) } ?? 0
            guard
                let pirEndpoints = state.serviceConfig?.pirEndpoints.map(\.url),
                !pirEndpoints.isEmpty
            else {
                votingLogger.error("serviceConfig unexpectedly nil during delegation proof; aborting")
                return .none
            }
            let storedSignatures = state.keystoneBundleSignatures
            let signedCount = storedSignatures.count

            return .run { [backgroundTask, votingCrypto, votingAPI, mnemonic, walletStorage] send in
                let bgTaskId = await backgroundTask.beginTask("Keystone delegation proof")
                do {
                    let senderPhrase = try walletStorage.exportWallet().seedPhrase.value()
                    let senderSeed = try mnemonic.toSeed(senderPhrase)
                    let hotkeyPhrase = try walletStorage.exportVotingHotkey("").seedPhrase.value()
                    let hotkeySeed = try mnemonic.toSeed(hotkeyPhrase)
                    let noteChunks = cachedNotes.smartBundles().bundles
                    var completedBundles = Set<UInt32>()
                    for idx: UInt32 in 0..<UInt32(signedCount) {
                        if let vanPosition = try await Self.recoverDelegationVanPosition(
                            roundId: roundId,
                            bundleIndex: idx,
                            votingCrypto: votingCrypto,
                            votingAPI: votingAPI
                        ) {
                            votingLogger.debug("Recovered Keystone delegation bundle \(idx) VAN position: \(vanPosition)")
                            completedBundles.insert(idx)
                        }
                    }

                    for (bundleIndex, sig) in storedSignatures.enumerated() {
                        let bundleIdx = UInt32(bundleIndex)
                        if completedBundles.contains(bundleIdx) {
                            votingLogger.debug("Keystone delegation bundle \(bundleIdx) already submitted, skipping")
                            let overallProgress = Double(bundleIndex + 1) / Double(signedCount)
                            await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                            continue
                        }
                        let bundleNotes = noteChunks[bundleIndex]
                        votingLogger.info("Keystone batch: proving bundle \(bundleIndex + 1)/\(signedCount)")

                        for try await event in votingCrypto.buildAndProveDelegation(
                            roundId,
                            bundleIdx,
                            bundleNotes,
                            senderSeed,
                            hotkeySeed,
                            networkId,
                            accountIndex,
                            pirEndpoints,
                            expectedSnapshotHeight
                        ) {
                            switch event {
                            case .progress(let progress):
                                let overallProgress = (Double(bundleIndex) + progress) / Double(signedCount)
                                votingLogger.debug("ZKP #1 bundle \(bundleIdx) progress: \(Int(progress * 100))%")
                                await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                            case .completed(let proof):
                                votingLogger.info("ZKP #1 bundle \(bundleIdx) COMPLETE — proof size: \(proof.count) bytes")
                            }
                        }

                        // Submit delegation TX using the stored Keystone signature
                        let registration = try await votingCrypto.getDelegationSubmissionWithKeystoneSig(
                            roundId, bundleIdx, sig.sig, sig.sighash
                        )
                        if registration.rk != sig.rk ||
                            registration.spendAuthSig != sig.sig ||
                            registration.sighash != sig.sighash {
                            throw VotingFlowError.invalidDelegationSignature
                        }
                        votingLogger.debug(
                            """
                            Keystone delegation tuple \
                            rk=\(Data(registration.rk.prefix(8)).hexString) \
                            sighash=\(Data(sig.sighash.prefix(8)).hexString) \
                            sig=\(Data(sig.sig.prefix(8)).hexString)
                            """
                        )
                        let delegTxResult = try await votingAPI.submitDelegation(registration)
                        votingLogger.info("Delegation TX \(bundleIdx) submitted: \(delegTxResult.txHash)")

                        // Persist TX hash for crash recovery
                        try await votingCrypto.storeDelegationTxHash(roundId, bundleIdx, delegTxResult.txHash)

                        let vanPosition = try await Self.requireDelegationVanPosition(
                            txHash: delegTxResult.txHash,
                            votingAPI: votingAPI
                        )
                        try await votingCrypto.storeVanPosition(roundId, bundleIdx, vanPosition)
                        votingLogger.debug("VAN position stored for bundle \(bundleIdx): \(vanPosition)")
                    }

                    await send(.delegationProofCompleted(roundId: roundId))
                } catch {
                    await backgroundTask.endTask(bgTaskId)
                    throw error
                }
                await backgroundTask.endTask(bgTaskId)
            } catch: { error, send in
                await send(.delegationProofFailed(roundId: roundId, error: error.localizedDescription))
            }
            .cancellable(id: cancelDelegationProofId, cancelInFlight: true)

        case .keystoneSignaturesRestored(let savedSigs):
            // Restore in-memory signatures from persisted recovery state
            state.keystoneBundleSignatures = savedSigs.map {
                State.KeystoneBundleSignature(sig: $0.sig, sighash: $0.sighash, rk: $0.rk)
            }
            state.currentKeystoneBundleIndex = UInt32(savedSigs.count)
            if UInt32(savedSigs.count) >= state.bundleCount {
                // All bundles were signed — go straight to batch proving
                state.keystoneSigningStatus = .idle
                state.screenStack = [.pollsList, .proposalList]
                state.delegationProofStatus = .generating(progress: 0)
                return .send(.keystoneAllBundlesSigned)
            } else {
                // Some bundles signed — show signing screen and auto-start next PCZT build
                state.keystoneSigningStatus = .idle
                state.screenStack = [.delegationSigning]
                return .send(.delegationApproved)
            }

        case .keystoneShowSigningScreen:
            state.screenStack = [.delegationSigning]
            return .send(.delegationApproved)

        case .skipRemainingKeystoneBundles:
            // Show confirmation alert with locked-in / giving-up amounts.
            let signedCount = state.keystoneBundleSignatures.count
            guard signedCount > 0 else { return .none }
            state.skipBundlesAlert = .confirmSkip(
                lockedIn: state.signedBundlesZECString,
                givingUp: state.skippedBundlesZECString
            )
            return .none

        case .skipBundlesAlert(.presented(.skipRemainingKeystoneBundlesConfirmed)):
            state.skipBundlesAlert = nil
            return .send(.skipRemainingKeystoneBundlesConfirmed)

        case .skipBundlesAlert(.dismiss):
            state.skipBundlesAlert = nil
            return .none

        case .skipBundlesAlert:
            return .none

        case .skipRemainingKeystoneBundlesConfirmed:
            // User confirmed skip — proceed with only the signed bundles.
            let signedCount = UInt32(state.keystoneBundleSignatures.count)
            guard signedCount > 0 else { return .none }
            state.bundleCount = signedCount

            // Recalculate votingWeight to reflect only signed bundles' quantized weight
            let bundles = state.walletNotes.smartBundles().bundles
            let signedWeight = state.keystoneBundleSignatures.indices.reduce(UInt64(0)) { total, i in
                guard i < bundles.count else { return total }
                let raw = bundles[i].reduce(UInt64(0)) { $0 + $1.value }
                return total + quantizeWeight(raw)
            }
            state.votingWeight = signedWeight

            state.pendingVotingPczt = nil
            state.pendingUnsignedDelegationPczt = nil
            state.keystoneSigningStatus = .idle
            state.screenStack = [.pollsList, .proposalList]
            state.delegationProofStatus = .generating(progress: 0)

            // Delete skipped bundles from DB so proof_generated reflects reality
            let roundId = state.roundId
            return .run { [votingCrypto] send in
                try await votingCrypto.deleteSkippedBundles(roundId, signedCount)
                await send(.keystoneAllBundlesSigned)
            } catch: { error, send in
                await send(.delegationProofFailed(roundId: roundId, error: error.localizedDescription))
            }

        case .keystoneBundleAdvance:
            // Legacy — no longer used; signing loop is handled by keystoneBundleSignatureStored.
            return .none

        case .spendAuthSignatureExtractionFailed(let error):
            state.keystoneSigningStatus = .failed(VotingErrorMapper.userFriendlyMessage(from: error))
            return .none

        case .delegationProofProgress(let roundId, let progress):
            guard state.roundId == roundId else { return .none }
            state.delegationProofStatus = .generating(progress: progress)
            return .none

        case .delegationProofCompleted(let roundId):
            guard state.roundId == roundId, state.activeSession != nil else { return .none }
            state.delegationProofStatus = .complete
            state.isDelegationProofInFlight = false
            state.currentKeystoneBundleIndex = 0
            state.keystoneBundleSignatures = []

            // Pop the delegation signing screen if it was pushed for deferred delegation.
            if state.screenStack.last == .delegationSigning {
                state.screenStack.removeLast()
            }

            // Auto-resume batch submission immediately so the UI transitions
            // to .submitting without a visible gap. Run cleanup in parallel.
            if state.pendingBatchSubmission {
                state.pendingBatchSubmission = false
                // Reset so canSubmitBatch passes — .authorizing makes
                // isBatchSubmitting true which blocks the guard.
                state.batchSubmissionStatus = .idle
                return .merge(
                    .send(.authenticationSucceeded),
                    .run { [votingCrypto] _ in
                        await votingCrypto.refreshState(roundId)
                        try await votingCrypto.clearRecoveryState(roundId)
                    }
                )
            }
            return .run { [votingCrypto] _ in
                await votingCrypto.refreshState(roundId)
                try await votingCrypto.clearRecoveryState(roundId)
            }

        case .delegationProofFailed(let roundId, let error):
            guard state.roundId == roundId else { return .none }
            votingLogger.error("Delegation proof failed (raw): \(error)")
            state.currentKeystoneBundleIndex = 0
            state.keystoneBundleSignatures = []
            let userMessage: String
            if error.contains("total_weight must yield at least 1 ballot") {
                userMessage = String(
                    localizable: .coinVoteDelegationInsufficientSnapshotBalance(
                        Zatoshi(Int64(state.votingWeight)).decimalString(),
                        Zatoshi(Int64(ballotDivisor)).decimalString()
                    )
                )
            } else {
                userMessage = VotingErrorMapper.userFriendlyMessage(from: error)
            }
            state.delegationProofStatus = .failed(userMessage)
            state.isDelegationProofInFlight = false
            return .none

        default:
            return .none
        }
    }

    /// Run the non-Keystone delegation pipeline for all bundles.
    /// Called inline from submitAllDrafts before the vote pipeline.
    /// The SDK selects a fresh PIR endpoint from `pirEndpoints` per bundle (see
    /// `VotingCryptoClient.buildAndProveDelegation`); pass the entire configured
    /// list and the round's `expectedSnapshotHeight` so stale servers are
    /// skipped without a hard fallback.
    static func runDelegationPipeline(
        roundId: String,
        cachedNotes: [NoteInfo],
        senderSeed: [UInt8],
        hotkeySeed: [UInt8],
        networkId: UInt32,
        accountIndex: UInt32,
        roundName: String,
        pirEndpoints: [String],
        expectedSnapshotHeight: UInt64,
        delegationPrepared: Bool = false,
        seedFingerprint: Data? = nil,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        send: Send<Action>,
        delegationConfirmationTimeout: TimeInterval = 90,
        delegationConfirmationRetryDelay: Duration = .seconds(2)
    ) async throws {
        let noteChunks = cachedNotes.smartBundles().bundles
        let bundleCount = UInt32(noteChunks.count)
        var completedBundles = Set<UInt32>()
        for idx: UInt32 in 0..<bundleCount {
            if let vanPosition = try await Self.recoverDelegationVanPosition(
                roundId: roundId,
                bundleIndex: idx,
                votingCrypto: votingCrypto,
                votingAPI: votingAPI,
                confirmationTimeout: delegationConfirmationTimeout,
                retryDelay: delegationConfirmationRetryDelay
            ) {
                votingLogger.debug("Recovered delegation bundle \(idx) VAN position: \(vanPosition)")
                completedBundles.insert(idx)
            }
        }

        for bundleIndex: UInt32 in 0..<bundleCount {
            if completedBundles.contains(bundleIndex) {
                votingLogger.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) already submitted, skipping")
                continue
            }
            let bundleNotes = noteChunks[Int(bundleIndex)]
            votingLogger.info("Delegation bundle \(bundleIndex + 1)/\(bundleCount) (\(bundleNotes.count) notes)")

            let registration: DelegationRegistration
            if let cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                roundId, bundleIndex, senderSeed, networkId, accountIndex
            ) {
                votingLogger.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
                if delegationPrepared {
                    votingLogger.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using precomputed PIR data")
                } else {
                    let orchardFvk = try seedFingerprint.map { _ in
                        try votingCrypto.extractOrchardFvkFromUfvk(bundleNotes[0].ufvkStr, networkId)
                    }
                    _ = try await votingCrypto.buildVotingPczt(
                        roundId, bundleIndex, bundleNotes,
                        senderSeed, hotkeySeed, networkId, accountIndex, roundName,
                        orchardFvk, seedFingerprint
                    )
                }

                for try await event in votingCrypto.buildAndProveDelegation(
                    roundId, bundleIndex, bundleNotes,
                    senderSeed, hotkeySeed, networkId, accountIndex,
                    pirEndpoints, expectedSnapshotHeight
                ) {
                    switch event {
                    case .progress(let progress):
                        let overallProgress = (Double(bundleIndex) + progress) / Double(bundleCount)
                        votingLogger.debug("ZKP #1 bundle \(bundleIndex) progress: \(Int(progress * 100))%")
                        await send(.delegationProofProgress(roundId: roundId, progress: overallProgress))
                    case .completed(let proof):
                        votingLogger.info("ZKP #1 bundle \(bundleIndex) COMPLETE — proof size: \(proof.count) bytes")
                    }
                }

                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, senderSeed, networkId, accountIndex
                )
            }
            let delegTxResult = try await votingAPI.submitDelegation(registration)
            votingLogger.info("Delegation TX \(bundleIndex) submitted: \(delegTxResult.txHash)")

            try await votingCrypto.storeDelegationTxHash(roundId, bundleIndex, delegTxResult.txHash)

            let vanPosition = try await Self.requireDelegationVanPosition(
                txHash: delegTxResult.txHash,
                votingAPI: votingAPI,
                confirmationTimeout: delegationConfirmationTimeout,
                retryDelay: delegationConfirmationRetryDelay
            )
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            votingLogger.debug("VAN position stored for bundle \(bundleIndex): \(vanPosition)")
        }

        await send(.delegationProofCompleted(roundId: roundId))
    }

    private static func recoverDelegationVanPosition(
        roundId: String,
        bundleIndex: UInt32,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32? {
        guard case let .present(txHash) = try? await votingCrypto.getDelegationTxHash(roundId, bundleIndex) else {
            return nil
        }

        return try await recoverDelegationVanPosition(
            roundId: roundId,
            bundleIndex: bundleIndex,
            txHash: txHash,
            votingCrypto: votingCrypto,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        )
    }

    private static func recoverDelegationVanPosition(
        roundId: String,
        bundleIndex: UInt32,
        txHash: String,
        votingCrypto: VotingCryptoClient,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32? {
        switch try await delegationTxConfirmationStatus(
            txHash: txHash,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        ) {
        case let .confirmed(vanPosition):
            try await votingCrypto.storeVanPosition(roundId, bundleIndex, vanPosition)
            return vanPosition

        case let .failed(code, log):
            votingLogger.warning(
                "Cached delegation TX \(txHash) for bundle \(bundleIndex) is not reusable: code=\(code) log=\(log)"
            )
            return nil

        case .notFound:
            votingLogger.debug("Cached delegation TX \(txHash) for bundle \(bundleIndex) is not confirmed yet")
            return nil
        }
    }

    private static func requireDelegationVanPosition(
        txHash: String,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> UInt32 {
        switch try await delegationTxConfirmationStatus(
            txHash: txHash,
            votingAPI: votingAPI,
            confirmationTimeout: confirmationTimeout,
            retryDelay: retryDelay
        ) {
        case let .confirmed(vanPosition):
            return vanPosition

        case let .failed(code, log):
            throw VotingFlowError.delegationTxFailed(code: code, log: log)

        case .notFound:
            throw VotingFlowError.delegationTxFailed(code: 0, log: "")
        }
    }

    private static func delegationTxConfirmationStatus(
        txHash: String,
        votingAPI: VotingAPIClient,
        confirmationTimeout: TimeInterval = 90,
        retryDelay: Duration = .seconds(2)
    ) async throws -> DelegationTxConfirmationStatus {
        let deadline = Date().addingTimeInterval(confirmationTimeout)

        repeat {
            if let confirmation = try? await votingAPI.fetchTxConfirmation(txHash) {
                guard confirmation.code == 0 else {
                    return .failed(code: confirmation.code, log: confirmation.log)
                }
                guard
                    let leafValue = confirmation.event(ofType: "delegate_vote")?.attribute(forKey: "leaf_index"),
                    let vanPosition = UInt32(leafValue)
                else {
                    return .failed(code: 0, log: "missing delegate_vote leaf_index")
                }
                return .confirmed(vanPosition: vanPosition)
            }

            guard Date() < deadline else {
                return .notFound
            }

            try await Task.sleep(for: retryDelay)
        } while true
    }

    /// Delegate shares using the supplied active-submission server candidates.
    @discardableResult
    static func delegateSharesWithFallback(
        _ payloads: [SharePayload],
        roundId: String,
        votingAPI: VotingAPIClient,
        serverURLs: [String],
        retryDelay: Duration = .seconds(2)
    ) async throws -> ShareDelegationResult {
        guard !serverURLs.isEmpty else {
            throw ShareDelegationError.noReachableVoteServers
        }

        var lastExhaustionError: ShareDelegationError?
        for attempt in 1...3 {
            do {
                return try await votingAPI.delegateShares(payloads, roundId, serverURLs)
            } catch let error as ShareDelegationError where error == .noReachableVoteServers {
                lastExhaustionError = error
                votingLogger.warning("delegateShares attempt \(attempt)/3 exhausted vote servers")
                if attempt < 3 {
                    try await Task.sleep(for: retryDelay)
                }
            } catch {
                votingLogger.warning("delegateShares failed with non-exhaustion error: \(error)")
                throw error
            }
        }

        throw lastExhaustionError ?? ShareDelegationError.noReachableVoteServers
    }
}
