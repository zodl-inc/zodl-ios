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
        func publishState(backend: VotingRustBackend, roundId: String) {
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
            openDatabase: { path in
                try await dbActor.open(path: path)
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
                    eaPk: [UInt8](params.eaPK),
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
                    walletDbPath: walletDbPath,
                    snapshotHeight: snapshotHeight,
                    networkId: networkId,
                    accountUUID: accountUUID
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
            generateNoteWitnesses: { roundId, bundleIndex, walletDbPath, notes in
                let backend = try await dbActor.backend()
                let sdkNotes = notes.map { $0.toSDK() }
                let witnesses = try backend.generateNoteWitnesses(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    walletDbPath: walletDbPath,
                    notes: sdkNotes
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
            generateHotkey: { roundId, seed in
                let backend = try await dbActor.backend()
                let hotkey = try backend.generateHotkey(roundId: roundId, seed: seed)
                return VotingHotkey(
                    secretKey: Data(hotkey.secretKey),
                    publicKey: Data(hotkey.publicKey),
                    address: hotkey.address
                )
            },
            // swiftlint:disable:next line_length
            buildVotingPczt: { roundId, bundleIndex, notes, senderSeed, hotkeySeed, networkId, accountIndex, roundName, orchardFvkOverride, keystoneSeedFingerprintOverride in
                let backend = try await dbActor.backend()
                _ = try backend.generateHotkey(roundId: roundId, seed: hotkeySeed)
                let inputs: VotingDelegationInputs
                let actualFvkBytes: [UInt8]
                if let orchardFvkOverride {
                    guard let keystoneSeedFingerprintOverride else {
                        throw VotingCryptoError.invalidKeystoneMetadata
                    }
                    inputs = try VotingRustBackend.generateDelegationInputsWithFvk(
                        fvkBytes: [UInt8](orchardFvkOverride),
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex,
                        seedFingerprint: [UInt8](keystoneSeedFingerprintOverride)
                    )
                    actualFvkBytes = [UInt8](orchardFvkOverride)
                } else {
                    inputs = try VotingRustBackend.generateDelegationInputs(
                        senderSeed: senderSeed,
                        hotkeySeed: hotkeySeed,
                        networkId: networkId,
                        accountIndex: accountIndex
                    )
                    actualFvkBytes = inputs.fvkBytes
                }
                let sdkNotes = notes.map { $0.toSDK() }
                // NU6 consensus branch ID; coin_type 133 = mainnet, 1 = testnet
                let consensusBranchId: UInt32 = 0xC8E7_1055
                let coinType: UInt32 = networkId == 0 ? 133 : 1
                let result = try backend.buildVotingPczt(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    fvkBytes: actualFvkBytes,
                    hotkeyRawAddress: inputs.hotkeyRawAddress,
                    consensusBranchId: consensusBranchId,
                    coinType: coinType,
                    seedFingerprint: inputs.seedFingerprint,
                    accountIndex: accountIndex,
                    roundName: roundName,
                    addressIndex: 0
                )
                publishState(backend: backend, roundId: roundId)
                let pcztBytes: Data = Data(result.pcztBytes)
                let rk: Data = Data(result.rk)
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
                try backend.storeTreeState(roundId: roundId, treeStateBytes: [UInt8](treeState))
            },
            extractSpendAuthSignatureFromSignedPczt: { signedPczt, actionIndex in
                Data(try VotingRustBackend.extractSpendAuthSig(
                    signedPcztBytes: [UInt8](signedPczt),
                    actionIndex: actionIndex
                ))
            },
            extractPcztSighash: { pcztBytes in
                Data(try VotingRustBackend.extractPcztSighash(pcztBytes: [UInt8](pcztBytes)))
            },
            precomputeDelegationPir: { roundId, bundleIndex, bundleNotes, pirEndpoints, expectedSnapshotHeight, networkId in
                let backend = try await dbActor.backend()
                let sdkNotes = bundleNotes.map { $0.toSDK() }
                let result = try await backend.precomputeDelegationPir(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    notes: sdkNotes,
                    pirEndpoints: pirEndpoints,
                    expectedSnapshotHeight: expectedSnapshotHeight,
                    networkId: networkId
                )
                return DelegationPirPrecomputeResult(
                    cachedCount: result.cachedCount,
                    fetchedCount: result.fetchedCount
                )
            },
            // swiftlint:disable:next line_length
            buildAndProveDelegation: { roundId, bundleIndex, bundleNotes, senderSeed, hotkeySeed, networkId, accountIndex, pirEndpoints, expectedSnapshotHeight in
                AsyncThrowingStream { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let inputs = try VotingRustBackend.generateDelegationInputs(
                                senderSeed: senderSeed,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                accountIndex: accountIndex
                            )
                            let sdkNotes = bundleNotes.map { $0.toSDK() }
                            let result = try await backend.buildAndProveDelegation(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                notes: sdkNotes,
                                hotkeyRawAddress: inputs.hotkeyRawAddress,
                                pirEndpoints: pirEndpoints,
                                expectedSnapshotHeight: expectedSnapshotHeight,
                                networkId: networkId,
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
                Data(try VotingRustBackend.extractOrchardFvkFromUfvk(ufvkStr: ufvkStr, networkId: networkId))
            },
            decomposeWeight: { weight in
                (try? VotingRustBackend.decomposeWeight(weight)) ?? []
            },
            encryptShares: { roundId, shares in
                let backend = try await dbActor.backend()
                let encrypted = try backend.encryptShares(roundId: roundId, shares: shares)
                return encrypted.map { share in
                    EncryptedShare(
                        c1: Data(share.c1),
                        c2: Data(share.c2),
                        shareIndex: share.shareIndex
                    )
                }
            },
            // swiftlint:disable:next line_length
            buildVoteCommitment: { roundId, bundleIndex, hotkeySeed, networkId, proposalId, choice, numOptions, vanAuthPath, vanPosition, anchorHeight, singleShare in
                AsyncThrowingStream { continuation in
                    Task.detached {
                        do {
                            let backend = try await dbActor.backend()
                            let result = try backend.buildVoteCommitment(
                                roundId: roundId,
                                bundleIndex: bundleIndex,
                                hotkeySeed: hotkeySeed,
                                networkId: networkId,
                                proposalId: proposalId,
                                choice: choice.ffiValue,
                                numOptions: numOptions,
                                vanAuthPath: vanAuthPath.map { [UInt8]($0) },
                                vanPosition: vanPosition,
                                anchorHeight: anchorHeight,
                                singleShare: singleShare ? 1 : 0,
                                progress: { progress in
                                    continuation.yield(.progress(progress))
                                }
                            )
                            publishState(backend: backend, roundId: roundId)
                            let vanNullifier: Data = Data(result.vanNullifier)
                            let voteAuthorityNoteNew: Data = Data(result.voteAuthorityNoteNew)
                            let voteCommitment: Data = Data(result.voteCommitment)
                            let proof: Data = Data(result.proof)
                            let sharesHash: Data = Data(result.sharesHash)
                            let rVpkBytes: Data = Data(result.rVpkBytes)
                            let alphaV: Data = Data(result.alphaV)
                            let encShares: [EncryptedShare] = result.encShares.map { share in
                                EncryptedShare(
                                    c1: Data(share.c1),
                                    c2: Data(share.c2),
                                    shareIndex: share.shareIndex
                                )
                            }
                            let shareBlindFactors: [Data] = result.shareBlinds.map { Data($0) }
                            let shareComms: [Data] = result.shareComms.map { Data($0) }
                            let bundle = VoteCommitmentBundle(
                                vanNullifier: vanNullifier,
                                voteAuthorityNoteNew: voteAuthorityNoteNew,
                                voteCommitment: voteCommitment,
                                proposalId: proposalId,
                                proof: proof,
                                encShares: encShares,
                                anchorHeight: result.anchorHeight,
                                voteRoundId: result.voteRoundId,
                                sharesHash: sharesHash,
                                shareBlindFactors: shareBlindFactors,
                                shareComms: shareComms,
                                rVpkBytes: rVpkBytes,
                                alphaV: alphaV
                            )
                            continuation.yield(.completed(bundle))
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            },
            buildSharePayloads: { encShares, commitment, voteDecision, numOptions, vcTreePosition, singleShare in
                let backend = try await dbActor.backend()
                let sdkShares = encShares.map {
                    VotingWireEncryptedShare(
                        c1: [UInt8]($0.c1),
                        c2: [UInt8]($0.c2),
                        shareIndex: $0.shareIndex
                    )
                }
                let vanNullifier: [UInt8] = [UInt8](commitment.vanNullifier)
                let voteAuthorityNoteNew: [UInt8] = [UInt8](commitment.voteAuthorityNoteNew)
                let voteCommitment: [UInt8] = [UInt8](commitment.voteCommitment)
                let proof: [UInt8] = [UInt8](commitment.proof)
                let sharesHash: [UInt8] = [UInt8](commitment.sharesHash)
                let shareBlinds: [[UInt8]] = commitment.shareBlindFactors.map { [UInt8]($0) }
                let shareComms: [[UInt8]] = commitment.shareComms.map { [UInt8]($0) }
                let rVpkBytes: [UInt8] = [UInt8](commitment.rVpkBytes)
                let alphaV: [UInt8] = [UInt8](commitment.alphaV)
                let sdkCommitment = VotingVoteCommitmentBundle(
                    vanNullifier: vanNullifier,
                    voteAuthorityNoteNew: voteAuthorityNoteNew,
                    voteCommitment: voteCommitment,
                    proposalId: commitment.proposalId,
                    proof: proof,
                    encShares: sdkShares,
                    anchorHeight: commitment.anchorHeight,
                    voteRoundId: commitment.voteRoundId,
                    sharesHash: sharesHash,
                    shareBlinds: shareBlinds,
                    shareComms: shareComms,
                    rVpkBytes: rVpkBytes,
                    alphaV: alphaV
                )
                let payloads = try backend.buildSharePayloads(
                    encShares: sdkShares,
                    commitment: sdkCommitment,
                    voteDecision: voteDecision.ffiValue,
                    numOptions: numOptions,
                    vcTreePosition: vcTreePosition,
                    singleShare: singleShare ? 1 : 0
                )
                return payloads.map { payload in
                    let encShare = EncryptedShare(
                        c1: Data(payload.encShare.c1),
                        c2: Data(payload.encShare.c2),
                        shareIndex: payload.encShare.shareIndex
                    )
                    let allEncShares = payload.allEncShares.map { wire in
                        EncryptedShare(
                            c1: Data(wire.c1),
                            c2: Data(wire.c2),
                            shareIndex: wire.shareIndex
                        )
                    }
                    let shareComms = payload.shareComms.map { Data($0) }
                    return SharePayload(
                        sharesHash: Data(payload.sharesHash),
                        proposalId: payload.proposalId,
                        voteDecision: payload.voteDecision,
                        encShare: encShare,
                        treePosition: payload.treePosition,
                        allEncShares: allEncShares,
                        shareComms: shareComms,
                        primaryBlind: Data(payload.primaryBlind)
                    )
                }
            },
            getDelegationSubmission: { roundId, bundleIndex, senderSeed, networkId, accountIndex in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmission(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    senderSeed: senderSeed,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.rk)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
                    sighash: sighash
                )
            },
            getDelegationSubmissionWithKeystoneSig: { roundId, bundleIndex, keystoneSig, keystoneSighash in
                let backend = try await dbActor.backend()
                let sub = try backend.getDelegationSubmissionWithKeystoneSig(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    sig: [UInt8](keystoneSig),
                    sighash: [UInt8](keystoneSighash)
                )
                let voteRoundIdBytes = Data(hexString: sub.voteRoundId)
                let rk: Data = Data(sub.rk)
                let spendAuthSig: Data = Data(sub.spendAuthSig)
                let signedNoteNullifier: Data = Data(sub.nfSigned)
                let cmxNew: Data = Data(sub.cmxNew)
                let vanCmx: Data = Data(sub.govComm)
                let govNullifiers: [Data] = sub.govNullifiers.map { Data($0) }
                let proof: Data = Data(sub.proof)
                let sighash: Data = Data(sub.sighash)
                return DelegationRegistration(
                    rk: rk,
                    spendAuthSig: spendAuthSig,
                    signedNoteNullifier: signedNoteNullifier,
                    cmxNew: cmxNew,
                    vanCmx: vanCmx,
                    govNullifiers: govNullifiers,
                    proof: proof,
                    voteRoundId: voteRoundIdBytes,
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
            markVoteSubmitted: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                try backend.markVoteSubmitted(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId)
                publishState(backend: backend, roundId: roundId)
            },
            resetTreeClient: {
                let backend = try await dbActor.backend()
                try backend.resetTreeClient()
            },
            signCastVote: { hotkeySeed, networkId, bundle in
                let rVpkBytes: [UInt8] = [UInt8](bundle.rVpkBytes)
                let vanNullifier: [UInt8] = [UInt8](bundle.vanNullifier)
                let voteAuthorityNoteNew: [UInt8] = [UInt8](bundle.voteAuthorityNoteNew)
                let voteCommitment: [UInt8] = [UInt8](bundle.voteCommitment)
                let alphaV: [UInt8] = [UInt8](bundle.alphaV)
                let sig = try VotingRustBackend.signCastVote(
                    hotkeySeed: hotkeySeed,
                    networkId: networkId,
                    voteRoundIdHex: bundle.voteRoundId,
                    rVpkBytes: rVpkBytes,
                    vanNullifier: vanNullifier,
                    voteAuthorityNoteNew: voteAuthorityNoteNew,
                    voteCommitment: voteCommitment,
                    proposalId: bundle.proposalId,
                    anchorHeight: bundle.anchorHeight,
                    alphaV: alphaV
                )
                return CastVoteSignature(
                    voteAuthSig: Data(sig.voteAuthSig)
                )
            },
            extractNcRoot: { treeStateBytes in
                Data(try VotingRustBackend.extractNcRoot(treeStateBytes: [UInt8](treeStateBytes)))
            },
            storeDelegationTxHash: { roundId, bundleIndex, txHash in
                let backend = try await dbActor.backend()
                try backend.storeDelegationTxHash(roundId: roundId, bundleIndex: bundleIndex, txHash: txHash)
            },
            getDelegationTxHash: { roundId, bundleIndex in
                let backend = try await dbActor.backend()
                return try backend.getDelegationTxHash(roundId: roundId, bundleIndex: bundleIndex)
            },
            storeVoteTxHash: { roundId, bundleIndex, proposalId, txHash in
                let backend = try await dbActor.backend()
                try backend.storeVoteTxHash(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, txHash: txHash)
            },
            getVoteTxHash: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                return try backend.getVoteTxHash(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId)
            },
            storeKeystoneBundleSignature: { roundId, info in
                let backend = try await dbActor.backend()
                try backend.storeKeystoneSignature(roundId: roundId, bundleIndex: info.bundleIndex, sig: info.sig, sighash: info.sighash, rk: info.rk)
            },
            loadKeystoneBundleSignatures: { roundId in
                let backend = try await dbActor.backend()
                return try backend.getKeystoneSignatures(roundId: roundId).map { sigInfo -> KeystoneBundleSignatureInfo in
                    let sig: Data = Data(sigInfo.sig)
                    let sighash: Data = Data(sigInfo.sighash)
                    let rk: Data = Data(sigInfo.rk)
                    return KeystoneBundleSignatureInfo(
                        bundleIndex: sigInfo.bundleIndex,
                        sig: sig,
                        sighash: sighash,
                        rk: rk
                    )
                }
            },
            storeVoteCommitmentBundle: { roundId, bundleIndex, proposalId, bundle, vcTreePosition in
                let backend = try await dbActor.backend()
                let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? "{}"
                try backend.storeCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId, bundleJson: json, vcTreePosition: vcTreePosition)
            },
            getVoteCommitmentBundle: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else { return nil }
                return try JSONDecoder().decode(VoteCommitmentBundle.self, from: Data(result.json.utf8))
            },
            getVoteCommitmentBundleWithPosition: { roundId, bundleIndex, proposalId in
                let backend = try await dbActor.backend()
                guard let result = try backend.getCommitmentBundle(roundId: roundId, bundleIndex: bundleIndex, proposalId: proposalId) else { return nil }
                let bundle = try JSONDecoder().decode(VoteCommitmentBundle.self, from: Data(result.json.utf8))
                return (bundle: bundle, vcTreePosition: result.vcTreePosition)
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
            recordShareDelegation: { roundId, bundleIndex, proposalId, shareIndex, sentToURLs, nullifier, submitAt in
                let backend = try await dbActor.backend()
                try backend.recordShareDelegation(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    proposalId: proposalId,
                    shareIndex: shareIndex,
                    sentToURLs: sentToURLs,
                    nullifier: nullifier,
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

    func open(path: String) throws {
        // If already open, close the old backend before opening a fresh one.
        // This makes re-initialization safe (e.g. onAppear firing twice).
        if let old = _backend {
            old.close()
            _backend = nil
        }
        let b = VotingRustBackend()
        try b.open(path: path)
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

    /// Initialize Data from a hex-encoded string (e.g. "0a1b2c").
    init(hexString: String) {
        var data = Data()
        var hex = hexString
        while hex.count >= 2 {
            let byteString = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
        }
        self = data
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
