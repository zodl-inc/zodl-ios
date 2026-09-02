#if VOTING_ENABLED
@preconcurrency import Combine
import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

/// The incident, end to end, in the order a voter lived it: a poll whose
/// delegation was broadcast, an error telling them to leave and re-enter, the
/// wipe that advice caused, recovery on the next launch, and -- once the
/// restore entry point exists -- voting again.
///
/// Runs on a simulator through `Scripts/e2e/run-delegation-recovery-e2e.sh`.
///
/// WHAT THIS PROVES TODAY, and what it does not. Every stage up to and
/// including the escrow being import-ready is asserted for real. The final
/// stage -- restoring the carved delegation into `bundles` so the round can be
/// voted on -- is `.disabled`, because `zcash_voting` exposes no entry point
/// that can do it (see `restoringTheCarvedDelegationLetsTheRoundBeVotedOn`).
/// It is written out rather than omitted so that the missing piece is visible
/// in the suite instead of living in someone's head.
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

    // MARK: - Stage 5: voting again (PENDING)

    /// The step this suite exists to reach, and cannot yet run.
    ///
    /// BLOCKED ON: an entry point in `zcash_voting` that restores carved
    /// delegation state into `bundles`. `import_delegation_capability` is the
    /// closest thing and is the wrong tool:
    ///
    ///   - it is a capability-TRANSFER protocol, taking `capability_json` in
    ///     an exact canonical encoding and returning a digest that
    ///     acknowledges delivered bytes to a funds controller;
    ///   - it validates the capability against a trusted voter context
    ///     (`vote_chain_id`, network, round params, and the hotkey's own
    ///     delegation target);
    ///   - and `bundle_matches` requires the heavy columns to be NULL, so it
    ///     rejects exactly our case -- the round was cleared AND REBUILT, so
    ///     `bundles` holds rebuilt rows and the import reads as conflicting
    ///     local state.
    ///
    /// What is needed instead is narrow: restore `(round_id, bundle_index,
    /// van_comm_rand, gov_comm, total_note_value, delegation_tx_hash)` over
    /// the rebuilt rows in one transaction, with preconditions written for
    /// this incident. That is a `zcash_voting` change plus an FFI binding.
    ///
    /// WHEN THAT EXISTS, enable this and assert: restore from the escrow,
    /// then drive a vote through `commitVote` and `submitVoteCommitment`
    /// against `FakeVoteServer`, and check the committed bundle opens the VAN
    /// the chain already holds -- i.e. the vote is accepted under the ORIGINAL
    /// delegation rather than the rebuild's. `theEscrowHoldsEverythingARestoreWillNeed`
    /// already proves the inputs are present, so only the restore call itself
    /// is missing.
    @Test(.disabled("Needs a zcash_voting entry point to restore carved delegation state; see the doc comment."))
    func restoringTheCarvedDelegationLetsTheRoundBeVotedOn() async throws {
        Issue.record("unreachable while disabled")
    }
}
}
#endif
