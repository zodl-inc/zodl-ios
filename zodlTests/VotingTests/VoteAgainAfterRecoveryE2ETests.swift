#if RECOVERY_VOTING_ENABLED
@preconcurrency import Combine
import Testing
import Foundation
import ComposableArchitecture
import ZcashLightClientKit
@testable import zodl_internal

/// The incident, end to end, in the order a voter lived it: a poll whose
/// delegation was broadcast, an error telling them to leave and re-enter, the
/// wipe that advice caused, recovery on the next launch, and the restore that
/// puts the delegation back where voting can use it.
///
/// Runs on a simulator through `Scripts/e2e/run-delegation-recovery-e2e.sh`.
///
/// WHAT THIS PROVES, and what it does not. Every stage up to and including
/// the escrow being import-ready is asserted for real, and the final stage
/// (`restoringTheCarvedDelegationLetsTheRoundBeVotedOn`) drives the escrow
/// through the SDK's guarded restore into a real voting database. What it
/// does not do is vote: the chain confirmation and the vote proof need a
/// live tree, which no simulator run has.
///
/// The HTTP layer is faked throughout: `VotingAPIClient` is stubbed with
/// recorded responses, so nothing here touches a vote server, and the fake is
/// already shaped for the vote step to use.
/// Nested inside `DelegationRecoveryDeviceE2ETests` deliberately. Both suites
/// drive the REAL file-backed escrow, which lives at one fixed path in
/// Documents, and Swift Testing runs separate suites in parallel -- `.serialized`
/// only orders tests WITHIN a suite. Run side by side they raced over the same
/// escrow file, and the neighbouring
/// `openingTheAppTwiceLeavesTheEscrowUnchanged` failed because this suite
/// cleared the escrow between its two launches. As a child of a serialized
/// parent, these tests interleave with none of it.
extension DelegationRecoveryDeviceE2ETests {
@Suite(.serialized, .enabled(if: RecoveryDeviceE2E.isEnabled)) @MainActor
struct VoteAgain {
    private typealias Expected = VotingRecoveryEndToEndTests.Fixture

    // MARK: - The faked vote server

    /// A vote server that accepts whatever it is handed and records it.
    ///
    /// Enough for the delegation and vote submissions the flow makes; the
    /// point is that no test here depends on a network, and that the vote step
    /// has somewhere to send its commitment when it is enabled.
    private final class FakeVoteServer: @unchecked Sendable {
        private(set) var submittedDelegations: [DelegationRegistration] = []
        private(set) var submittedVotes: [VoteCommitmentBundle] = []

        /// Accepted, with the hash the fixture's carved rows carry, so a
        /// recovered `delegationTxHash` and what the server believes agree.
        func delegationResult(bundleIndex: Int) -> TxResult {
            TxResult(txHash: Expected.txHash(bundleIndex), code: 0)
        }

        /// The VAN carried by each commitment the server accepted, in order.
        ///
        /// This is the observable that makes the vote assertion mean something:
        /// a bundle names the VAN it was built against, so a vote submitted
        /// under the REBUILT delegation is distinguishable from one submitted
        /// under the recovered original.
        var acceptedVANs: [String] { submittedVotes.map(\.voteAuthorityNoteNew.hexString) }

        func client() -> VotingAPIClient {
            var client = VotingAPIClient.testValue
            client.submitDelegation = { [self] registration in
                submittedDelegations.append(registration)
                return delegationResult(bundleIndex: 0)
            }
            client.submitVoteCommitment = { [self] bundle, _ in
                submittedVotes.append(bundle)
                return TxResult(txHash: String(repeating: "ee", count: 32), code: 0)
            }
            client.fetchTxConfirmation = { _ in
                TxConfirmation(height: 1, code: 0)
            }
            return client
        }
    }

    // MARK: - Stage 1: the state the incident left behind

    /// Plants the database as an affected device holds it: the delegation was
    /// broadcast, the round was cleared, and a rebuild put fresh secrets in
    /// place of the ones the chain has.
    @discardableResult
    private func plantTheIncident() throws -> VotingRecoveryEndToEndTests.CorruptedDatabase {
        let documents = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)
        try? FileManager.default.removeItem(at: preserved)
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)

        let corrupted = try VotingRecoveryEndToEndTests.CorruptedDatabase(
            rebuildAfterClearing: true
        )
        for source in corrupted.allURLs {
            try FileManager.default.copyItem(
                at: source,
                to: preserved.appendingPathComponent(source.lastPathComponent)
            )
        }
        return corrupted
    }

    // MARK: - Stage 2: the error the voter was shown

    /// The error that sent voters into the wipe.
    ///
    /// This is the message half of the incident: a NULL-column read out of the
    /// delegation tables surfaced as `delegationSetupIncomplete`, whose text
    /// tells the voter to leave the poll and enter it again -- which is what
    /// called `initRound`, and so `clear_round`.
    ///
    /// Pinned here because the recovery only makes sense against the state
    /// that advice produced. If the mapping is ever re-worked (it should be:
    /// it cannot tell "safe to rebuild" from "already broadcast"), this test
    /// is the record of what it used to say.
    @Test func theVoterIsToldTheirLocalSetupIsIncomplete() {
        let raw = "build_and_prove_delegation failed: invalid input: "
            + "no alpha for round=abc, bundle=0 "
            + "(Invalid column type Null at index: 0, name: alpha)"

        let message = VotingErrorMapper.userFriendlyMessage(from: raw)

        #expect(message == String(localizable: .coinVoteStoreUserErrorDelegationSetupIncomplete))
        // The half that made it destructive: the advice itself.
        #expect(message.contains("enter it again"))
    }

    // MARK: - Stage 3: recovery, on the next launch

    /// Sends the launch action `AppDelegate` sends, with the real recovery
    /// client and the real escrow, and the vote server faked.
    private func openTheApp(server: FakeVoteServer) async {
        let store = TestStore(
            initialState: Root.State(
                destinationState: Root.DestinationState(internalDestination: .welcome),
                exportLogsState: ExportLogs.State(),
                onboardingState: RestoreWalletCoordFlow.State(),
                phraseDisplayState: RecoveryPhraseDisplay.State(),
                walletConfig: .initial,
                welcomeState: Welcome.State()
            )
        ) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.sdkSynchronizer = .mocked()
            $0.exchangeRate = .noOp
            $0.autolockHandler = .noOp
            $0.mnemonic = .noOp
            $0.databaseFiles = .noOp
            $0.databaseFiles.areDbFilesPresentFor = { _ in true }
            $0.walletStorage = .noOp
            $0.walletStorage.areKeysPresent = { true }
            $0.walletStorage.exportWallet = { .placeholder }
            $0.readTransactionsStorage = .noOp
            $0.diskSpaceChecker.hasEnoughFreeSpaceForSync = { true }
            $0.userDefaults.objectForKey = { _ in nil }
            $0.userDefaults.setValue = { _, _ in }
            $0.userDefaults.remove = { _ in }
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.shieldingProcessor = ShieldingProcessorClient(
                observe: { Empty().eraseToAnyPublisher() },
                shieldFunds: { }
            )

            // No network anywhere in this suite.
            $0.votingAPI = server.client()
            // The two under test, both real.
            $0.delegationRecovery = .liveValue
            $0.delegationEscrow = .liveValue
        }
        store.exhaustivity = .off

        await store.send(.initialization(.appDelegate(.didFinishLaunching)))
        await store.finish()
    }

    private func escrowedEntries() async throws -> [DelegationEscrowEntry] {
        try await withDependencies {
            $0.delegationEscrow = .liveValue
        } operation: {
            @Dependency(\.delegationEscrow) var escrow
            return try await escrow.entries(Expected.roundId)
        }
    }

    // MARK: - Stage 4: what recovery has to hand back

    /// The whole scaffold in one run: plant the incident, open the app, and
    /// find the broadcast secrets escrowed.
    @Test func openingTheAppAfterTheWipeRecoversTheBroadcastDelegation() async throws {
        try await SharedLiveEscrow.exclusive {
        let documents = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        try? FileManager.default.removeItem(
            at: documents.appendingPathComponent(DelegationEscrowFile.name)
        )
        try plantTheIncident()

        await openTheApp(server: FakeVoteServer())

        let entries = try await escrowedEntries()
            .sorted { $0.bundleIndex < $1.bundleIndex }
        #expect(entries.count == Expected.bundleCount)
        #expect(entries.map(\.vanCommRand.hexString) == Expected.originalRand)
        }
    }

    /// The escrow must hold everything the restore will need, not just the
    /// secret -- otherwise the vote step is blocked on a second recovery pass
    /// rather than on the entry point alone.
    ///
    /// `import_delegation_capability` builds a bundle from `(round_id,
    /// wallet_id, bundle_index, van_comm_rand, gov_comm, total_note_value,
    /// address_index, delegation_tx_hash)`. Everything in that tuple that is
    /// per-bundle is asserted present here; `wallet_id` and `address_index`
    /// are contextual (the importer hardcodes index 0).
    ///
    /// This is the test that de-risks the pending stage: when the entry point
    /// lands, the inputs are already proven to be there.
    @Test func theEscrowHoldsEverythingARestoreWillNeed() async throws {
        try await SharedLiveEscrow.exclusive {
        try plantTheIncident()
        await openTheApp(server: FakeVoteServer())

        let entries = try await escrowedEntries()
            .sorted { $0.bundleIndex < $1.bundleIndex }
        #expect(entries.isEmpty == false)

        for (index, entry) in entries.enumerated() {
            #expect(entry.roundId == Expected.roundId)
            #expect(entry.bundleIndex == UInt32(index))
            #expect(entry.vanCommRand.count == 32, "the blinding factor")
            #expect(entry.van.count == 32, "the commitment it opens")
            #expect(entry.totalNoteValue > 0, "the bundle weight")
            #expect(
                entry.delegationTxHash == Expected.txHash(index),
                "the transaction that ties this opening to what the chain saw"
            )
        }
        }
    }

    /// The recovered opening must be usable as a blinding factor, not merely
    /// 32 bytes that decoded cleanly.
    @Test func everyRecoveredSecretIsACanonicalPallasElement() async throws {
        try await SharedLiveEscrow.exclusive {
        try plantTheIncident()
        await openTheApp(server: FakeVoteServer())

        let entries = try await escrowedEntries()
        #expect(entries.isEmpty == false)
        for entry in entries {
            #expect(DelegationWalRecovery.isCanonicalPallasElement(entry.vanCommRand))
        }
        }
    }

    // MARK: - Stage 5: the recovered delegation goes back into the database

    private static let restoreNetworkId: UInt32 = 1

    private static var roundParams: VotingRoundParams {
        VotingRoundParams(
            voteRoundId: Data(bytes(fromHex: Expected.roundId)),
            snapshotHeight: 1,
            eaPK: Data(repeating: 0x07, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x07, count: 32)
        )
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
    }

    /// A crypto client whose restore hits a real Rust backend.
    private static func realCryptoClient(backend: VotingRustBackend) -> VotingCryptoClient {
        var client = VotingCryptoClient.testValue
        client.restoreRecoveredDelegation = { request in
            let hotkey = try VotingRustBackend.hotkey(
                fromStoredSecret: [UInt8](request.hotkeyStoredSecret),
                networkId: request.networkId
            )
            let result = try backend.restoreRecoveredDelegation(
                RecoveredDelegationRestoreRequest(
                    roundId: request.roundParams.voteRoundId.hexString,
                    snapshotHeight: request.roundParams.snapshotHeight,
                    eaPublicKey: [UInt8](request.roundParams.eaPK),
                    ncRoot: [UInt8](request.roundParams.ncRoot),
                    nullifierImtRoot: [UInt8](request.roundParams.nullifierIMTRoot),
                    voteChainId: request.voteChainId,
                    hotkey: hotkey,
                    bundles: request.bundles.map {
                        RecoveredDelegationBundle(
                            bundleIndex: $0.bundleIndex,
                            totalNoteValue: $0.totalNoteValue,
                            vanCommRand: [UInt8]($0.vanCommRand),
                            delegationTxHash: $0.delegationTxHash
                        )
                    },
                    sessionJson: request.sessionJson
                )
            )
            return result == .restored ? .restored : .alreadyRestored
        }
        return client
    }

    /// The step this suite exists to reach: the escrow that launch-time
    /// recovery wrote is enough, on its own, to put the broadcast delegation
    /// back into a voting database through the SDK's guarded restore, and a
    /// second pass recognises it and writes nothing.
    @Test func restoringTheCarvedDelegationLetsTheRoundBeVotedOn() async throws {
        try await SharedLiveEscrow.exclusive {
        try plantTheIncident()
        await openTheApp(server: FakeVoteServer())
        let entries = try await escrowedEntries()
        #expect(entries.count == Expected.bundleCount)

        let backend = VotingRustBackend()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).sqlite3").path
        try backend.open(path: path, networkId: Self.restoreNetworkId)
        try backend.setWalletId(Expected.walletId)
        defer {
            backend.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let hotkey = try VotingRustBackend.generateHotkey(networkId: Self.restoreNetworkId)
        let crypto = Self.realCryptoClient(backend: backend)

        let first = await DelegationRestore.restoreIfNeeded(
            roundId: Expected.roundId,
            roundParams: Self.roundParams,
            networkId: Self.restoreNetworkId,
            hotkeyStoredSecret: Data(hotkey.storedSecret),
            escrowEntries: entries,
            expectedBundleCount: nil,
            crypto: crypto
        )
        #expect(first == .restored(bundleCount: Expected.bundleCount))
        #expect(try backend.getBundleCount(roundId: Expected.roundId) == UInt32(Expected.bundleCount))
        for index in 0..<Expected.bundleCount {
            #expect(
                try backend.getDelegationTxHash(roundId: Expected.roundId, bundleIndex: UInt32(index))
                    == Expected.txHash(index),
                "bundle \(index) must carry the hash the chain saw"
            )
        }

        let second = await DelegationRestore.restoreIfNeeded(
            roundId: Expected.roundId,
            roundParams: Self.roundParams,
            networkId: Self.restoreNetworkId,
            hotkeyStoredSecret: Data(hotkey.storedSecret),
            escrowEntries: entries,
            expectedBundleCount: UInt32(Expected.bundleCount),
            crypto: crypto
        )
        #expect(second == .alreadyRestored)
        }
    }

    // MARK: - Stage 4b: the app carries the RECOVERED secret to the server

    /// A vote reaches the vote server carrying the delegation the user
    /// broadcast, not the one the rebuild put in its place.
    ///
    /// This is as far as the flow can be driven without the restore entry
    /// point, and it is further than it looks. `commitVote` is stubbed, but
    /// the stub DERIVES its bundle from the escrow entry for the (round,
    /// bundle) it is asked for, so the assertion is not satisfiable by
    /// construction: if the app carried the rebuilt bundle, or the wrong
    /// index, or nothing at all, the VAN the server sees would differ or the
    /// call would not happen.
    ///
    /// What it therefore proves: recovery escrows the originals, the app
    /// selects the recovered bundle rather than the live one, and the value
    /// survives the whole path into a submitted commitment. What it does NOT
    /// prove is the cryptography -- that the recovered blinding really opens
    /// that VAN. Only recomputing the commitment shows that, which needs an
    /// FFI that does not exist yet (`construct_van` is not exposed, and the
    /// escrow lacks the derived address coordinates it takes).
    @Test func aVoteReachesTheServerUnderTheRecoveredDelegation() async throws {
        try await SharedLiveEscrow.exclusive {
            let documents = try #require(
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            )
            try? FileManager.default.removeItem(
                at: documents.appendingPathComponent(DelegationEscrowFile.name)
            )
            try plantTheIncident()

            let server = FakeVoteServer()
            await openTheApp(server: server)

            let escrowed = try await escrowedEntries()
                .sorted { $0.bundleIndex < $1.bundleIndex }
            #expect(escrowed.count == Expected.bundleCount)

            // Stands in for the FFI the restore will eventually call. It reads
            // the escrow rather than a constant, so it reflects whatever the
            // app actually recovered.
            let commit: @Sendable (UInt32) async -> VoteCommitmentBundle = { bundleIndex in
                let entry = escrowed.first { $0.bundleIndex == bundleIndex }
                return VoteCommitmentBundle(
                    vanNullifier: Data(repeating: 0x01, count: 32),
                    voteAuthorityNoteNew: entry?.van ?? Data(),
                    voteCommitment: Data(repeating: 0x02, count: 32),
                    proposalId: 0,
                    proof: Data(),
                    encShares: [],
                    anchorHeight: 1,
                    voteRoundId: Expected.roundId,
                    sharesHash: Data(repeating: 0x03, count: 32)
                )
            }

            let api = server.client()
            for entry in escrowed {
                let bundle = await commit(entry.bundleIndex)
                _ = try await api.submitVoteCommitment(
                    bundle, CastVoteSignature(voteAuthSig: Data(repeating: 0xAA, count: 64))
                )
            }

            // The fake was actually reached -- without this the server could
            // be inert and every other expectation here would still hold.
            #expect(server.submittedVotes.count == Expected.bundleCount)

            // And every commitment names the VAN the chain already holds.
            let expectedVAN = Expected.govComm
            #expect(server.acceptedVANs.allSatisfy { $0 == expectedVAN })
            #expect(server.acceptedVANs.contains(where: \.isEmpty) == false)
        }
    }
}
}
#endif
