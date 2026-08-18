#if VOTING_ENABLED
@preconcurrency import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

// MARK: - Live key

extension VotingCryptoClient: DependencyKey {
    static var liveValue: Self {
        let dbActor = DatabaseActor()
        let stateSubject = CurrentValueSubject<VotingDbState, Never>(.initial)

        /// Query rounds + votes tables and publish combined state.
        // @Sendable: captured by Task.detached closures; only touches Sendable stateSubject and parameters.
        @Sendable func publishState(backend: VotingRustBackend, roundId: String) {
            guard let roundState = try? backend.getRoundState(roundId: roundId) else { return }
            let votes = (try? backend.getVotes(roundId: roundId)) ?? []
            let bundleCount = (try? backend.getBundleCount(roundId: roundId)) ?? 0
            let dbState = VotingDbState(
                roundState: RoundStateInfo(
                    roundId: roundState.roundId,
                    phase: roundState.phase.toModel(),
                    snapshotHeight: roundState.snapshotHeight,
                    hotkeyAddress: roundState.hotkeyAddress,
                    delegatedWeight: roundState.delegatedWeight,
                    proofGenerated: roundState.proofGenerated
                ),
                votes: votes.map { $0.toModel() },
                bundleCount: bundleCount
            )
            stateSubject.send(dbState)
        }

        return Self(
            stateStream: {
                stateSubject
                    .dropFirst() // Skip initial empty state
                    .eraseToAnyPublisher()
            },
            refreshState: { roundId in
                guard let backend = try? await dbActor.backend() else { return }
                publishState(backend: backend, roundId: roundId)
            },
            openDatabase: { path, networkId in
                try await dbActor.open(path: path, networkId: networkId)
            },
            setWalletId: { walletId in
                let backend = try await dbActor.backend()
                try backend.setWalletId(walletId)
            },
            initRound: { params, sessionJson in
                let backend = try await dbActor.backend()
                let roundIdHex = params.voteRoundId.hexString
                try backend.initRound(
                    roundId: roundIdHex,
                    snapshotHeight: params.snapshotHeight,
                    eaPublicKey: [UInt8](params.eaPK),
                    ncRoot: [UInt8](params.ncRoot),
                    nullifierImtRoot: [UInt8](params.nullifierIMTRoot),
                    sessionJson: sessionJson
                )
                publishState(backend: backend, roundId: roundIdHex)
            },
            getRoundState: { roundId in
                let backend = try await dbActor.backend()
                let state = try backend.getRoundState(roundId: roundId)
                return RoundStateInfo(
                    roundId: state.roundId,
                    phase: state.phase.toModel(),
                    snapshotHeight: state.snapshotHeight,
                    hotkeyAddress: state.hotkeyAddress,
                    delegatedWeight: state.delegatedWeight,
                    proofGenerated: state.proofGenerated
                )
            },
            getVotes: { roundId in
                let backend = try await dbActor.backend()
                let votes = try backend.getVotes(roundId: roundId)
                return votes.map { $0.toModel() }
            },
            listRounds: {
                let backend = try await dbActor.backend()
                return try backend.listRounds().map {
                    RoundSummaryInfo(
                        roundId: $0.roundId,
                        phase: $0.phase.toModel(),
                        snapshotHeight: $0.snapshotHeight,
                        createdAt: $0.createdAt
                    )
                }
            },
            clearRound: { roundId in
                let backend = try await dbActor.backend()
                try backend.clearRound(roundId: roundId)
            },
            deleteSkippedBundles: { roundId, keepCount in
                let backend = try await dbActor.backend()
                _ = try backend.deleteSkippedBundles(roundId: roundId, keepCount: keepCount)
            },
            warmProvingCaches: {
                try await Task.detached(priority: .background) {
                    try VotingRustBackend.warmProvingCaches()
                }.value
            },
            getWalletNotes: { walletDbPath, snapshotHeight, networkId, accountUUID in
                let backend = try await dbActor.backend()
                let notes = try backend.getWalletNotes(
                    accountUuidBytes: accountUUID,
                    dataDbPath: walletDbPath,
                    snapshotHeight: snapshotHeight,
                    networkId: networkId
                )
                return notes.map { (note: VotingNoteInfo) -> NoteInfo in
                    let commitment: Data = Data(note.commitment)
                    let nullifier: Data = Data(note.nullifier)
                    let diversifier: Data = Data(note.diversifier)
                    let rho: Data = Data(note.rho)
                    let rseed: Data = Data(note.rseed)
                    return NoteInfo(
                        commitment: commitment,
                        nullifier: nullifier,
                        value: note.value,
                        position: note.position,
                        diversifier: diversifier,
                        rho: rho,
                        rseed: rseed,
                        scope: note.scope,
                        ufvkStr: note.ufvkStr
                    )
                }
            },
            setupBundles: { roundId, notes in
                let backend = try await dbActor.backend()
                let sdkNotes = notes.map { $0.toSDK() }
                let result = try backend.setupBundles(roundId: roundId, notes: sdkNotes)
                return BundleSetupResult(
                    bundleCount: result.bundleCount,
                    eligibleWeight: result.eligibleWeight
                )
            },
            getBundleCount: { roundId in
                let backend = try await dbActor.backend()
                return try backend.getBundleCount(roundId: roundId)
            },
            generateNoteWitnesses: { roundId, bundleIndex, walletDbPath, notes, networkId in
                let backend = try await dbActor.backend()
                let sdkNotes = notes.map { $0.toSDK() }
                let witnesses = try backend.generateNoteWitnesses(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    walletDbPath: walletDbPath,
                    notes: sdkNotes,
                    networkId: networkId
                )
                return witnesses.map { witness -> WitnessData in
                    let noteCommitment: Data = Data(witness.noteCommitment)
                    let root: Data = Data(witness.root)
                    let authPath: [Data] = witness.authPath.map { Data($0) }
                    return WitnessData(
                        noteCommitment: noteCommitment,
                        position: witness.position,
                        root: root,
                        authPath: authPath
                    )
                }
            },
            verifyWitness: { witness in
                let noteCommitment: [UInt8] = [UInt8](witness.noteCommitment)
                let root: [UInt8] = [UInt8](witness.root)
                let authPath: [[UInt8]] = witness.authPath.map { [UInt8]($0) }
                let sdkWitness = VotingWitnessData(
                    noteCommitment: noteCommitment,
                    position: witness.position,
                    root: root,
                    authPath: authPath
                )
                return try VotingRustBackend.verifyWitness(sdkWitness)
            },
            generateHotkey: { networkId in
                let hotkey = try VotingRustBackend.generateHotkey(networkId: networkId)
                return VotingHotkey(
                    storedSecret: Data(hotkey.storedSecret),
                    rawOrchardAddress: Data(hotkey.rawOrchardAddress),
                    addressIndex: hotkey.addressIndex
                )
            },
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderFvk: [UInt8](orchardFvkOverride),
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // Ironwood (NU6.3) consensus branch ID, published by the SDK so a future
                // network upgrade cannot go stale here the way the old hardcoded NU6 literal
                // did (CHP.md §11.5 N1).
                let consensusBranchId = UInt32(bitPattern: ZcashSDK.nu63ConsensusBranchID)
                let keys = VotingDelegationKeyInputs(
                    fvk: actualFvkBytes,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName
                )
                let result = try backend.buildPczt(VotingBuildPcztParams(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    keys: keys,
                    consensusBranchId: consensusBranchId
                ))
                publishState(backend: backend, roundId: roundId)
                let pcztBytes: Data = Data(result.pcztBytes)
                let pcztSighash: Data = Data(result.pcztSighash)
                let rk: Data = Data(result.randomizedKey)
                let alpha: Data = Data(result.alpha)
                let nfSigned: Data = Data(result.nfSigned)
                let cmxNew: Data = Data(result.cmxNew)
                let govNullifiers: [Data] = result.govNullifiers.map { Data($0) }
                let van: Data = Data(result.van)
                let vanCommRand: Data = Data(result.vanCommRand)
                let dummyNullifiers: [Data] = result.dummyNullifiers.map { Data($0) }
                let rhoSigned: Data = Data(result.rhoSigned)
                let paddedCmx: [Data] = result.paddedCmx.map { Data($0) }
                let rseedSigned: Data = Data(result.rseedSigned)
                let rseedOutput: Data = Data(result.rseedOutput)
                let actionBytes: Data = Data(result.actionBytes)
                return VotingPcztResult(
                    pcztBytes: pcztBytes,
                    pcztSighash: pcztSighash,
                    rk: rk,
                    alpha: alpha,
                    nfSigned: nfSigned,
                    cmxNew: cmxNew,
                    govNullifiers: govNullifiers,
                    van: van,
                    vanCommRand: vanCommRand,
                    dummyNullifiers: dummyNullifiers,
                    rhoSigned: rhoSigned,
                    paddedCmx: paddedCmx,
                    rseedSigned: rseedSigned,
                    rseedOutput: rseedOutput,
                    actionBytes: actionBytes,
                    actionIndex: result.actionIndex
                )
            },
            storeTreeState: { roundId, treeState in
                let backend = try await dbActor.backend()
                try backend.storeTreeState(roundId: roundId, treeState: [UInt8](treeState))
            },
            extractSpendAuthSignatureFromSignedPczt: { signedPczt, actionIndex in
                Data(try VotingRustBackend.extractSpendAuthSig(
                    signedPczt: [UInt8](signedPczt),
                    actionIndex: actionIndex
                ))
            },
            extractPcztSighash: { pcztBytes in
                Data(try VotingRustBackend.extractPcztSighash(pczt: [UInt8](pcztBytes)))
            },
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId, pirDepth, tier0Layers, tier1Layers in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers)
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName, pirEndpoints, expectedSnapshotHeight, pirDepth, tier0Layers, tier1Layers in
                AsyncThrowingStream<ProofEvent, Error> { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let keys = VotingDelegationKeyInputs(
                                fvk: inputs.fvkBytes,
                                hotkeyStoredSecret: hotkeyStoredSecret,
                                seedFingerprint: inputs.seedFingerprint,
                                accountIndex: accountIndex,
                                roundName: roundName
                            )
                            let params = VotingDelegationProofParams(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                keys: keys
                            )
                            let result = try await backend.buildAndProveDelegation(
                                params,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                pirLayout: VotingPirLayout(pirDepth: pirDepth, tier0Layers: tier0Layers, tier1Layers: tier1Layers),
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            // Don't call publishState here — the Rust FFI may still hold
                            // a brief RefCell borrow on the DB connection, and publishState
                            // borrows it again. Let the store call refreshState after
                            // receiving .completed to avoid the concurrent borrow panic.
                            continuation.yield(.completed(Data(result.proof)))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
            extractOrchardFvkFromUfvk: { ufvkStr, networkId in
                Data(try VotingRustBackend.extractOrchardFvk(ufvk: ufvkStr, networkId: networkId))
            },
            // swiftlint:disable:next function_parameter_count
            commitVote: { roundId, bundleIndex, hotkeyStoredSecret, proposalId, choice, numOptions, voteCommitmentTreePosition, vanAuthPath, vanPosition, vanAnchorHeight, singleShare in
                let backend = try await dbActor.backend()
                let vanWitness = try VotingVanWitness.make(
                    authPath: vanAuthPath.map { [UInt8]($0) },
                    position: vanPosition,
                    anchorHeight: vanAnchorHeight
                )
                let result = try await backend.commitVote(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    proposalId: proposalId,
                    choice: choice.ffiValue,
                    numOptions: numOptions,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    vanWitness: vanWitness,
                    singleShare: singleShare
                )
                publishState(backend: backend, roundId: roundId)
                let encShares: [EncryptedShare] = try result.encShares.map { share in
                    guard
                        let c1 = Data(base64Encoded: share.ciphertext1),
                        let c2 = Data(base64Encoded: share.ciphertext2)
                    else {
                        throw VotingCryptoError.malformedWireShare(share.shareIndex)
                    }
                    return EncryptedShare(c1: c1, c2: c2, shareIndex: share.shareIndex)
                }
                let bundle = VoteCommitmentBundle(
                    vanNullifier: Data(result.vanNullifier),
                    voteAuthorityNoteNew: Data(result.voteAuthorityNoteNew),
                    voteCommitment: Data(result.voteCommitment),
                    proposalId: result.proposalId,
                    proof: Data(result.proof),
                    encShares: encShares,
                    anchorHeight: result.anchorHeight,
                    voteRoundId: roundId,
                    sharesHash: Data(),
                    rVpkBytes: Data(result.voteKeyRandomizer)
                )
                let signature = CastVoteSignature(voteAuthSig: Data(result.voteAuthSig))
                return (bundle, signature)
            },
            signDelegationRequest: { roundId, bundleIndex, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName in
                let backend = try await dbActor.backend()
                // Same derivation the software branch of `buildVotingPczt` uses: the sender's
                // Orchard FVK and ZIP-32 seed fingerprint come from the seed itself, so the
                // delegation keys here are byte-identical to the ones that built the PCZT.
                let inputs = try VotingRustBackend.generateDelegationInputs(
                    senderSeed: senderSeed,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let signed = try backend.signDelegationRequest(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keys: VotingDelegationKeyInputs(
                        fvk: inputs.fvkBytes,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        seedFingerprint: inputs.seedFingerprint,
                        accountIndex: accountIndex,
                        roundName: roundName
                    ),
                    seed: senderSeed
                )
                return (signature: Data(signed.signature), sighash: Data(signed.sighash))
            },
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    signature: [UInt8](signature),
                    sighash: [UInt8](sighash)
                )
                guard
                    let rk = Data(base64Encoded: sub.randomizedKey),
                    let spendAuthSig = Data(base64Encoded: sub.spendAuthSig)
                else {
                    throw VotingCryptoError.malformedDelegationSubmission(
                        "rk/spend_auth_sig did not base64-decode"
                    )
                }
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    tx1Effects: sub.tx1Effects,
                    signedNoteNullifier: sub.nfSigned,
                    cmxNew: sub.cmxNew,
                    vanCmx: sub.govComm,
                    govNullifiers: sub.govNullifiers,
                    proof: sub.proof,
                    voteRoundId: sub.voteRoundId,
                    sighash: sighash
                )
            },
            storeVanPosition: { roundId, bundleIndex, position in
                let backend = try await dbActor.backend()
                try backend.storeVanPosition(roundId: roundId, bundleIndex: bundleIndex, position: position)
            },
            syncVoteTree: { roundId, nodeUrl in
                let backend = try await dbActor.backend()
                return try backend.syncVoteTree(roundId: roundId, nodeUrl: nodeUrl)
            },
            generateVanWitness: { roundId, bundleIndex, anchorHeight in
                let backend = try await dbActor.backend()
                let witness = try backend.generateVanWitness(roundId: roundId, bundleIndex: bundleIndex, anchorHeight: anchorHeight)
                return VanWitness(
                    authPath: witness.authPath.map { Data($0) },
                    position: witness.position,
                    anchorHeight: witness.anchorHeight
                )
            },
            markVoteSubmitted: { roundId, bundleIndex, proposalId, txHash in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, txHash: txHash)
                publishState(backend: backend, roundId: roundId)
            },
            resetTreeClient: {
                let backend = try await dbActor.backend()
                try backend.resetTreeClient()
            },
            extractNcRoot: { treeStateBytes in
                Data(try VotingRustBackend.extractNcRoot(treeState: [UInt8](treeStateBytes)))
            },
            storeDelegationTxHash: { roundId, bundleIndex, txHash in
                let backend = try await dbActor.backend()
                try backend.storeDelegationTxHash(roundId: roundId, bundleIndex: bundleIndex, txHash: txHash)
            },
            getDelegationTxHash: { roundId, bundleIndex in
                let backend = try await dbActor.backend()
                if let txHash = try backend.getDelegationTxHash(roundId: roundId, bundleIndex: bundleIndex) {
                    return .present(txHash)
                }
                return .notFound
            },
            storeVoteTxHash: { roundId, bundleIndex, proposalId, txHash in
                let backend = try await dbActor.backend()
                try backend.storeVoteTxHash(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, txHash: txHash)
            },
            getVoteTxHash: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                if let txHash = try backend.getVoteTxHash(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) {
                    return .present(txHash)
                }
                return .notFound
            },
            confirmVoteSubmission: { roundId, bundleIndex, proposalId, txHash, eventsJson in
                let backend = try await dbActor.backend()
                let confirmation = try backend.confirmVoteSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    txHash: txHash,
                    eventsJson: eventsJson
                )
                publishState(backend: backend, roundId: roundId)
                return VoteConfirmationInfo(
                    txHash: confirmation.txHash,
                    vanLeafPosition: confirmation.vanLeafPosition,
                    voteCommitmentTreePosition: confirmation.voteCommitmentTreePosition
                )
            },
            getCommitmentBundleJson: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else {
                    return nil
                }
                return (bundleJson: result.bundleJson, vcTreePosition: result.voteCommitmentTreePosition)
            },
            recoverWireJson: { commitmentBundleJson, proposalId, shareIndex, voteCommitmentTreePosition, submitAt in
                try VotingRustBackend.recoverWireJson(
                    commitmentBundleJson: commitmentBundleJson,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    voteCommitmentTreePosition: voteCommitmentTreePosition,
                    submitAt: submitAt
                )
            },
            recoverableShareIndices: { commitmentBundleJson in
                try VotingRustBackend.recoverableShareIndices(
                    commitmentBundleJson: commitmentBundleJson
                )
            },
            storeKeystoneBundleSignature: { roundId, info in
                let backend = try await dbActor.backend()
                try backend.storeKeystoneSignature(
                    roundId: roundId,
                    bundleIndex: info.bundleIndex,
                    sig: [UInt8](info.sig),
                    sighash: [UInt8](info.sighash),
                    randomizedKey: [UInt8](info.rk)
                )
            },
            loadKeystoneBundleSignatures: { roundId in
                let backend = try await dbActor.backend()
                return try backend.getKeystoneSignatures(roundId: roundId).map { sigInfo -> KeystoneBundleSignatureInfo in
                    let sig: Data = Data(sigInfo.sig)
                    let sighash: Data = Data(sigInfo.sighash)
                    let rk: Data = Data(sigInfo.randomizedKey)
                    return KeystoneBundleSignatureInfo(
                        bundleIndex: sigInfo.bundleIndex,
                        sig: sig,
                        sighash: sighash,
                        rk: rk
                    )
                }
            },
            getVoteCommitmentBundle: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else { return nil }
                return try JSONDecoder().decode(VoteCommitmentBundle.self, from: Data(result.bundleJson.utf8))
            },
            getVoteCommitmentBundleWithPosition: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else { return nil }
                let bundle = try JSONDecoder().decode(VoteCommitmentBundle.self, from: Data(result.bundleJson.utf8))
                return (bundle: bundle, vcTreePosition: result.voteCommitmentTreePosition)
            },
            clearRecoveryState: { roundId in
                let backend = try await dbActor.backend()
                try backend.clearRecoveryState(roundId: roundId)
            },
            computeShareNullifier: { voteCommitment, shareIndex, primaryBlind in
                try VotingRustBackend.computeShareNullifier(
                    voteCommitment: voteCommitment,
                    shareIndex: shareIndex,
                    primaryBlind: primaryBlind
                )
            },
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    submitAt: submitAt
                )
            },
            getShareDelegations: { roundId in
                let backend = try await dbActor.backend()
                return try backend.getShareDelegations(roundId: roundId)
            },
            getUnconfirmedDelegations: { roundId in
                let backend = try await dbActor.backend()
                return try backend.getUnconfirmedDelegations(roundId: roundId)
            },
            markShareConfirmed: { roundId, bundleIndex, proposalId, shareIndex in
                let backend = try await dbActor.backend()
                try backend.markShareConfirmed(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex
                )
            },
            addSentServers: { roundId, bundleIndex, proposalId, shareIndex, newURLs in
                let backend = try await dbActor.backend()
                try backend.addSentServers(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    newURLs: newURLs
                )
            }
        )
    }
}

// MARK: - DatabaseActor

/// Thread-safe holder for the VotingRustBackend instance.
private actor DatabaseActor {
    private var _backend: VotingRustBackend?

    func open(path: String, networkId: UInt32) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path, networkId: networkId)
        _backend = b
    }

    func backend() throws -> VotingRustBackend {
        guard let _backend else {
            throw VotingCryptoError.databaseNotOpen
        }
        return _backend
    }
}

// MARK: - Helpers

enum VotingCryptoError: LocalizedError {
    case proofFailed(String)
    case databaseNotOpen
    case hotkeySeedBindingMismatch
    case invalidSpendAuthSignatureLength(Int)
    case invalidKeystoneMetadata
    case malformedWireShare(UInt32)
    case malformedDelegationSubmission(String)

    var errorDescription: String? {
        switch self {
        case .proofFailed(let reason):
            return "Delegation proof generation failed: \(reason)"
        case .databaseNotOpen:
            return "Voting database is not open."
        case .hotkeySeedBindingMismatch:
            return "Hotkey derivation mismatch while building delegation sign action."
        case .invalidSpendAuthSignatureLength(let actual):
            return "SpendAuthSig must be 64 bytes, got \(actual)."
        case .invalidKeystoneMetadata:
            return "Missing or invalid Keystone signing metadata."
        case .malformedWireShare(let shareIndex):
            return "commitVote returned a non-base64 encrypted share at index \(shareIndex)."
        case .malformedDelegationSubmission(let detail):
            return "getDelegationSubmission returned malformed wire data: \(detail)"
        }
    }
}

private extension VoteChoice {
    var ffiValue: UInt32 { index }

    static func fromFFI(_ value: UInt32) -> VoteChoice { .option(value) }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct VotingVanWitnessWire: Codable {
    let authPath: [[UInt8]]
    let position: UInt32
    let anchorHeight: UInt32

    enum CodingKeys: String, CodingKey {
        case authPath = "auth_path"
        case position
        case anchorHeight = "anchor_height"
    }
}

private func hexEncodedString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private extension VotingVanWitness {
    static func make(authPath: [[UInt8]], position: UInt32, anchorHeight: UInt32) throws -> VotingVanWitness {
        let wire = VotingVanWitnessWire(
            authPath: authPath,
            position: position,
            anchorHeight: anchorHeight
        )
        let data = try JSONEncoder().encode(wire)
        return try JSONDecoder().decode(VotingVanWitness.self, from: data)
    }
}

private extension NoteInfo {
    func toSDK() -> VotingNoteInfo {
        let commitmentBytes: [UInt8] = [UInt8](commitment)
        let nullifierBytes: [UInt8] = [UInt8](nullifier)
        let diversifierBytes: [UInt8] = [UInt8](diversifier)
        let rhoBytes: [UInt8] = [UInt8](rho)
        let rseedBytes: [UInt8] = [UInt8](rseed)
        return VotingNoteInfo(
            commitment: commitmentBytes,
            nullifier: nullifierBytes,
            value: value,
            position: position,
            diversifier: diversifierBytes,
            rho: rhoBytes,
            rseed: rseedBytes,
            scope: scope,
            ufvkStr: ufvkStr
        )
    }
}

private extension VotingRoundPhase {
    func toModel() -> RoundPhaseInfo {
        switch self {
        case .initialized: return .initialized
        case .hotkeyGenerated: return .hotkeyGenerated
        case .delegationConstructed: return .delegationConstructed
        case .delegationProved: return .delegationProved
        case .voteReady: return .voteReady
        }
    }
}

private extension VotingVoteRecord {
    func toModel() -> VoteRecord {
        VoteRecord(
            proposalId: proposalId,
            bundleIndex: bundleIndex,
            choice: VoteChoice.fromFFI(choice),
            submitted: submitted
        )
    }
}
#endif
