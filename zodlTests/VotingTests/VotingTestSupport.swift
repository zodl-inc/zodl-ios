#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

/// The fixtures, doubles and waiting helpers the voting suites share.
///
/// Reached by conformance rather than copied: the coordinator suite and the
/// optimization-parity suite drive the same coordinator through the same
/// dependency closures, and a fixture that drifted between them would let the
/// two suites disagree about what the SDK answers.
///
/// `Sendable` because the fixtures are read from inside the `@Sendable`
/// dependency closures a store's effects call, which capture the suite.
protocol VotingTestSuite: Sendable {}

/// The parent of every voting suite that drives a coordinator over the
/// process-global `@Shared` values — `swapAPIAccess` and
/// `selectedWalletAccount`.
///
/// `.serialized` orders tests *within* a suite; two top-level suites still run
/// in parallel with each other, so the route-change tests of one could flip the
/// shared value the account-switch tests of the other had just written and read
/// back. Nesting them under one serialized parent is what extends that ordering
/// across both. Any future suite writing those values belongs here too.
@Suite(.serialized) struct VotingSharedStateSuites {}

extension VotingTestSuite {
    // MARK: - Round identity and wallets

    var activeRoundId: String { String(repeating: "aa", count: 32) }

    static var walletSeed: [UInt8] { [UInt8](repeating: 0x07, count: 32) }

    func keystoneWalletAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }

    func zashiWalletAccount() -> WalletAccount {
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

    // MARK: - Rounds and service config

    func votingSession(
        status: SessionStatus = .active,
        proposalCount: Int = 1,
        voteEndsIn: TimeInterval = 60
    ) -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 123,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: .now.addingTimeInterval(voteEndsIn),
            ceremonyStart: .now.addingTimeInterval(-60),
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            description: "Round description",
            proposals: (1...max(proposalCount, 1)).map { index in
                VotingProposal(
                    id: UInt32(index),
                    title: "Proposal \(index)",
                    description: "Description \(index)",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose")
                    ]
                )
            },
            status: status,
            createdAtHeight: 123,
            title: "Round"
        )
    }

    static func makeServiceConfig(
        voteServers: [VotingServiceConfig.ServiceEndpoint] = [],
        rounds: [String: VotingServiceConfig.RoundEntry] = [:]
    ) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: voteServers,
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: rounds,
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1, polyLen: 4096)
        )
    }

    static func roundEntry() -> VotingServiceConfig.RoundEntry {
        VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: Data(repeating: 0x03, count: 32),
            signatures: []
        )
    }

    // MARK: - Flow state and dependencies

    /// The state an active round is entered from: one active round, a resolved
    /// service config, a software wallet account, and the polls-list spinner the
    /// entry is expected to clear.
    func sessionFlowState(
        drafts: [UInt32: VoteChoice] = [:],
        isKeystone: Bool = false,
        voteEndsIn: TimeInterval = 60
    ) -> VotingCoordFlow.State {
        var session = RoundSession(roundId: activeRoundId)
        session.draftVotes = drafts
        var state = VotingCoordFlow.State()
        state.roundCache[activeRoundId] = session
        state.allRounds = [
            RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2, voteEndsIn: voteEndsIn))
        ]
        state.serviceConfig = Self.makeServiceConfig(
            voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")]
        )
        state.checkingEligibilityRoundId = activeRoundId
        state.isKeystoneUser = isKeystone
        state.$selectedWalletAccount.withLock { $0 = isKeystone ? keystoneWalletAccount() : zashiWalletAccount() }
        state.$swapAPIAccess.withLock { $0 = .direct }
        return state
    }

    /// Everything the round-session path touches outside `votingCrypto`'s
    /// session calls, which each test stubs for itself.
    func sessionDependencies(_ dependencies: inout DependencyValues, recorder: EventRecorder) {
        dependencies.sdkSynchronizer = .mocked(
            latestState: {
                var latestState = SynchronizerState.zero
                latestState.fullyScannedHeight = 1_000
                return latestState
            }
        )
        dependencies.sdkSynchronizer.getTreeState = { _ in Data([0x01]) }
        dependencies.databaseFiles.dataDbURLFor = { _ in URL(fileURLWithPath: "/tmp/voting-tests-data.db") }
        dependencies.mnemonic.toSeed = { _ in Self.walletSeed }
        dependencies.walletStorage.exportWallet = { StoredWallet.placeholder }
        dependencies.walletStorage.exportVotingHotkey = { _ in
            StoredVotingHotkey(storedSecret: VotingHotkeySecret(Data(repeating: 0x11, count: 32)), version: 1)
        }
        dependencies.localAuthentication.authenticate = { true }
        dependencies.backgroundTask = .noOp
        dependencies.votingAPI.startHealthProbeSweep = { }
        dependencies.votingMetadata = votingMetadataClient(VotingMetadataBox())
        dependencies.continuousClock = ImmediateClock()
        dependencies.votingCrypto.openRoundSession = { _, _, _, _ in recorder.record("openRoundSession") }
        dependencies.votingCrypto.closeRoundSession = { _ in recorder.record("closeRoundSession") }
        dependencies.votingCrypto.cancelRoundSession = { _ in }
        dependencies.votingCrypto.runRound = { _, _, _ in
            recorder.record("runRound")
            return AsyncThrowingStream { $0.finish() }
        }
        dependencies.votingCrypto.precomputeDelegationProof = { _, _ in
            recorder.record("precomputeDelegationProof")
            return AsyncThrowingStream { $0.finish() }
        }
        dependencies.votingCrypto.eligibility = { _ in try self.eligibilityReport() }
        dependencies.votingCrypto.updateHostConfiguration = { _ in recorder.record("updateHostConfiguration") }
        // Re-entering a round whose rows already exist asks the crate to
        // re-derive the layout, so every session open can reach this. The
        // default answers the untrimmed single-bundle round the rest of these
        // fixtures describe -- the same figures `eligibilityReport()` and a
        // default `plan()` give -- so a suite that is not about the layout
        // cannot tell the restore apart from the read-only path it replaces.
        dependencies.votingCrypto.pendingShareRounds = { [] }
        dependencies.votingCrypto.setupBundles = { _ in
            try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
        }
    }

    /// Everything a Keystone round touches outside the per-test signature and
    /// run stubs.
    func keystoneDependencies(
        _ dependencies: inout DependencyValues,
        recorder: EventRecorder,
        bundleCount: UInt32
    ) {
        sessionDependencies(&dependencies, recorder: recorder)
        dependencies.keystoneHandler = .noOp
        dependencies.votingCrypto.sessionPlan = { _ in
            let call = recorder.recordAndCount("sessionPlan")
            return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
        }
        dependencies.votingCrypto.setupBundles = { _ in
            try self.bundleLayout(bundleCount: bundleCount, eligibleWeight: 100_000_000)
        }
        dependencies.votingCrypto.setBallotIntents = { _, _ in try self.plan(allDecided: true) }
        dependencies.votingCrypto.keystoneSignatures = { _ in [] }
        dependencies.votingCrypto.keystoneSigningRequests = { _, bundleIndices in
            recorder.record("keystoneSigningRequests:\(Self.indexList(bundleIndices))")
            return try bundleIndices.map {
                try self.keystoneSigningRequest(bundleIndex: $0, bundleCount: bundleCount)
            }
        }
    }

    /// Wires one gate into the voting client, so a store's effects and a Root reset running
    /// beside them ask the same one — which is what the app does, the live client holding it.
    func teardownDependencies(_ dependencies: inout DependencyValues, gate: VotingTeardown) {
        dependencies.votingCrypto.beginWalletTeardown = { gate.begin() }
        dependencies.votingCrypto.endWalletTeardown = { gate.end() }
        dependencies.votingCrypto.teardownGenerationIfIdle = { gate.generationIfIdle }
        dependencies.votingCrypto.teardownAllowsOpen = { gate.allowsOpen(capturedGeneration: $0) }
        dependencies.votingCrypto.teardownBegan = { gate.began }
    }

    func votingMetadataClient(
        _ box: VotingMetadataBox
    ) -> VotingMetadataProviderClient {
        var client = VotingMetadataProviderClient()
        client.load = { _ in }
        client.store = { _ in }
        client.resetAccount = { _ in }
        client.reset = {}
        client.loadDrafts = { box.drafts[$0] ?? [:] }
        client.setDrafts = { drafts, roundId in box.drafts[roundId] = drafts }
        client.clearDrafts = { roundId in box.drafts[roundId] = [:] }
        client.loadSubmittedVotes = { box.submittedVotes[$0] ?? [:] }
        client.setSubmittedVotes = { votes, roundId in
            box.submittedVotes[roundId] = votes
        }
        client.clearSubmittedVotes = { roundId in box.submittedVotes[roundId] = [:] }
        client.record = { box.records[$0] }
        client.allRecords = { box.records }
        client.setRecord = { record, roundId in box.records[roundId] = record }
        client.clearRecord = { roundId in box.records.removeValue(forKey: roundId) }
        return client
    }

    // MARK: - Wire-JSON fixtures

    /// The crate's own wire shape for a plan, decoded rather than constructed:
    /// the SDK's views are `Decodable` only, and going through JSON keeps these
    /// tests honest about what a session actually answers with.
    func plan(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        delegationBundlesNeedingSigning: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil,
        bundlePhases: [String]? = nil,
        legacyInFlight: Bool = false
    ) throws -> VotingRoundPlan {
        let payload = planPayload(
            needsBundleSetup: needsBundleSetup,
            openProposals: openProposals,
            allDecided: allDecided,
            delegationBundlesNeedingWork: delegationBundlesNeedingWork,
            delegationBundlesNeedingSigning: delegationBundlesNeedingSigning,
            completedChoices: completedChoices,
            bundlePhases: bundlePhases,
            legacyInFlight: legacyInFlight
        )
        return try JSONDecoder().decode(VotingRoundPlan.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    /// One plan in the crate's wire shape.
    ///
    /// `bundlePhases` names one bundle per entry, in index order, so a round
    /// with more than one bundle -- or one whose delegation the crate says is
    /// already `signed` -- can be described. The default is the single prepared
    /// bundle most of these tests want.
    func planPayload(
        needsBundleSetup: Bool = false,
        openProposals: [UInt32] = [],
        allDecided: Bool = false,
        delegationBundlesNeedingWork: [UInt32] = [],
        delegationBundlesNeedingSigning: [UInt32] = [],
        completedChoices: [(UInt32, UInt32?)]? = nil,
        bundlePhases: [String]? = nil,
        legacyInFlight: Bool = false
    ) -> [String: Any] {
        let noIntents: [Int] = []
        let delegationStatuses = (bundlePhases ?? ["prepared"]).enumerated().map { index, phase in
            ["bundle_index": index, "phase": phase, "terminal": false] as [String: Any]
        }
        var payload: [String: Any] = [
            "round_id": activeRoundId,
            "pending_recovery": false,
            "blocking_recovery": false,
            "blocking_share_work": false,
            "has_unconfirmed_shares": false,
            "hotkey_bound": true,
            "completed_for_display": completedChoices != nil,
            "needs_draft_setup": false,
            "needs_bundle_setup": needsBundleSetup,
            "needs_delegation_signing": false,
            "has_in_flight_delegation": false,
            "delegation_bundles_needing_work": delegationBundlesNeedingWork.map { Int($0) },
            "delegation_bundles_needing_signing": delegationBundlesNeedingSigning.map { Int($0) },
            "needs_vote_polling": false,
            "has_remaining_vote_or_share_work": !allDecided,
            "has_recoverable_vote_or_share_work": !allDecided,
            "primary_action": needsBundleSetup ? "delegate" : "vote",
            "delegation_statuses": delegationStatuses,
            "open_proposals": openProposals.map { Int($0) },
            "unrostered_intents": noIntents,
            "immediate_share_confirmed": false,
            "all_decided": allDecided
        ]
        if let completedChoices {
            payload["completed_vote_display"] = [
                "choices": completedChoices.map { choice -> [String: Any] in
                    ["proposal_id": Int(choice.0), "choice": choice.1.map { Int($0) } as Any]
                }
            ]
        }
        if legacyInFlight {
            payload["has_legacy_in_flight_submission"] = true
        }
        return payload
    }

    func bundleLayout(
        bundleCount: UInt32,
        eligibleWeight: UInt64,
        privacyTrimDroppedBundles: UInt32 = 0,
        privacyTrimDroppedValueZatoshi: UInt64 = 0,
        skippedSuffixBundles: UInt32 = 0,
        skippedSuffixValueZatoshi: UInt64 = 0
    ) throws -> VotingBundleLayout {
        let payload: [String: Any] = [
            "bundle_count": Int(bundleCount),
            "eligible_weight": Int(eligibleWeight),
            "dropped_count": 0,
            "privacy_trim_dropped_bundles": Int(privacyTrimDroppedBundles),
            "privacy_trim_dropped_notes": 0,
            "privacy_trim_dropped_value_zatoshi": Int(privacyTrimDroppedValueZatoshi),
            "skipped_suffix_bundles": Int(skippedSuffixBundles),
            "skipped_suffix_notes": 0,
            "skipped_suffix_value_zatoshi": Int(skippedSuffixValueZatoshi)
        ]
        return try JSONDecoder().decode(VotingBundleLayout.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    func eligibilityReport(eligibleWeight: UInt64 = 50_000_000) throws -> VotingEligibilityReport {
        let payload: [String: Any] = [
            "distinct_note_count": 1,
            "eligible_weight": Int(eligibleWeight),
            "is_eligible": eligibleWeight > 0,
            "privacy_trim_dropped_value_zatoshi": 0
        ]
        return try JSONDecoder().decode(VotingEligibilityReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    /// One run report in the crate's wire shape.
    ///
    /// `chainOutcomeKind` and `diagnostic` describe the quiescence's own
    /// outcome; `confirmedTransactionHash` adds a separate confirmed entry to
    /// the report's `chain_outcomes` list, which is what a run that reached the
    /// chain reports whatever it then stopped on. `failures` are step failures
    /// in dispatch order.
    func runReport(
        kind: String,
        completedProposals: UInt32,
        totalProposals: UInt32,
        chainOutcomeKind: String? = nil,
        diagnostic: String? = nil,
        completedChoices: [(UInt32, UInt32?)]? = nil,
        bundles: [UInt32] = [],
        bundlePhases: [String]? = nil,
        confirmedTransactionHash: String? = nil,
        failures: [(kind: String, message: String)] = []
    ) throws -> VotingRoundRunReport {
        var quiescence: [String: Any] = ["kind": kind]
        if !bundles.isEmpty {
            quiescence["bundles"] = bundles.map { Int($0) }
        }
        if let chainOutcomeKind {
            var outcome: [String: Any] = ["kind": chainOutcomeKind]
            if let diagnostic {
                outcome["diagnostic"] = ["message": diagnostic]
            }
            quiescence["chain_outcome"] = outcome
        }
        var payload: [String: Any] = [
            "quiescence": quiescence,
            "tally": [
                "completed_proposals": Int(completedProposals),
                "total_proposals": Int(totalProposals),
                "remaining_obligations": Int(totalProposals - completedProposals)
            ]
        ]
        if let completedChoices {
            payload["plan"] = planPayload(
                allDecided: true,
                completedChoices: completedChoices,
                bundlePhases: bundlePhases
            )
        }
        if let confirmedTransactionHash {
            payload["chain_outcomes"] = [[
                "step": ["kind": "advance_vote_batch", "bundle_index": 0, "proposal_id": 0, "choice": 0, "share_index": 0],
                "outcome": [
                    "kind": "confirmed",
                    "confirmation_source": "hash",
                    "transaction_hash": confirmedTransactionHash,
                    "vote_commitment_positions": [0]
                ]
            ]]
        }
        if !failures.isEmpty {
            payload["failures"] = failures.map { failure in
                ["failure": ["kind": failure.kind, "message": failure.message]] as [String: Any]
            }
        }
        return try JSONDecoder().decode(VotingRoundRunReport.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    /// One driver event in the crate's wire shape, for the folds a run's
    /// narration drives.
    func driveEvent(_ json: String) throws -> VotingRoundDriveEvent {
        try JSONDecoder().decode(VotingRoundDriveEvent.self, from: Data(json.utf8))
    }

    func keystoneSigningRequest(
        bundleIndex: UInt32,
        bundleCount: UInt32,
        delegatedWeight: UInt64 = 50_000_000,
        eligibleWeight: UInt64 = 100_000_000
    ) throws -> VotingKeystoneSigningRequest {
        let payload: [String: Any] = [
            "bundle_index": Int(bundleIndex),
            "bundle_count": Int(bundleCount),
            "redacted_pczt": Data([0x0A, UInt8(bundleIndex)]).base64EncodedString(),
            "pczt_sighash": Data(repeating: UInt8(bundleIndex) + 1, count: 32).base64EncodedString(),
            "rk": Data(repeating: 0x0C, count: 32).base64EncodedString(),
            "action_index": 0,
            "display_memo": "Round",
            "eligible_weight_zatoshi": Int(eligibleWeight),
            "delegated_weight_zatoshi": Int(delegatedWeight)
        ]
        return try JSONDecoder().decode(
            VotingKeystoneSigningRequest.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    func keystoneBatchResult(inserted: UInt32) throws -> VotingKeystoneSignatureBatchResult {
        let payload: [String: Any] = ["inserted": Int(inserted), "already_present": 0]
        return try JSONDecoder().decode(
            VotingKeystoneSignatureBatchResult.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    static var keystoneConflictMessage: String { "a stored signature disagrees with the scanned bundle" }

    // MARK: - Share tracking fixtures

    /// The wallet id the pending-share rows are scoped to. Shares belong to the
    /// wallet that delivered them, and the sidecar answers for every wallet it
    /// holds, so a round of somebody else's is not this flow's to resume.
    static var pendingWalletId: String {
        "0303030303030303030303030303030303030303030303030303030303030303"
    }

    /// A round with an open session and nothing tracking it yet -- the state a
    /// `.pollShareStatus` trigger finds -- on a vote that ends far enough away
    /// for the whole backoff ladder to fit before it.
    func shareTrackingState(voteEndsIn: TimeInterval = 3_600) -> VotingCoordFlow.State {
        var state = sessionFlowState(voteEndsIn: voteEndsIn)
        state.checkingEligibilityRoundId = nil
        state.openRoundSessionIds = [activeRoundId]
        state.sessionRouteAccess = .direct
        return state
    }

    func shareTrackingReport(
        kind: String,
        passes: UInt32 = 1,
        messages: [String] = []
    ) throws -> VotingShareTrackingRunReport {
        var quiescence: [String: Any] = ["kind": kind]
        if !messages.isEmpty {
            quiescence["messages"] = messages
        }
        let payload: [String: Any] = ["quiescence": quiescence, "passes": Int(passes)]
        return try JSONDecoder().decode(
            VotingShareTrackingRunReport.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    func shareTrackingEvent(kind: String, pass: UInt32?) throws -> VotingShareTrackingEvent {
        var payload: [String: Any] = ["kind": kind]
        if let pass {
            payload["pass"] = Int(pass)
        }
        return try JSONDecoder().decode(
            VotingShareTrackingEvent.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    func pendingShareRound(walletId: String, roundId: String) throws -> VotingPendingShareRound {
        let payload: [String: Any] = ["wallet_id": walletId, "round_id": roundId]
        return try JSONDecoder().decode(
            VotingPendingShareRound.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    // MARK: - Driving and waiting

    @MainActor
    func waitForStore(
        // Generous ceiling, not a responsiveness claim: starved CI runners have inflated
        // trivially-fast tests to 60-120 s (unit_tests runs 33367909253, 33371909793 — the
        // 2 s budget this replaces lost twice), the poll exits the moment the condition
        // lands, and a real regression still fails, just slower.
        timeoutNanoseconds: UInt64 = 60_000_000_000,
        sourceLocation: SourceLocation = #_sourceLocation,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "Timed out waiting for store state", sourceLocation: sourceLocation)
    }

    /// Signs whichever bundle the flow has put on screen, the way the voter
    /// does it: open the scanner, then hand back the PCZT the device signed.
    @MainActor
    func scanKeystoneSignature(_ store: StoreOf<VotingCoordFlow>, bundleIndex: UInt32) async {
        await waitForStore {
            store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == bundleIndex
        }
        store.send(.openKeystoneSignatureScan)
        store.send(.keystoneScan(.presented(.foundVotingDelegationPCZT(Data([0xAB, UInt8(bundleIndex)])))))
    }

    func tryUnwrap<T>(_ value: T?) -> T {
        guard let value else {
            fatalError("tryUnwrap: required value was unexpectedly nil")
        }
        return value
    }

    /// A directory of this test's own to stand in for `Documents`.
    ///
    /// The sidecar has one name and the suites run in parallel, so two tests that
    /// each create and delete the real `Documents/voting.sqlite3` would be deleting
    /// each other's.
    static func temporaryDocumentsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voting-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Reading what a test drove

    func isProposalListTop(_ state: VotingCoordFlow.State) -> Bool {
        guard case .proposalList = state.path.last else { return false }
        return true
    }

    static func isSessionLifecycleEvent(_ event: String) -> Bool {
        event.hasPrefix("setOperationEpoch")
            || event.hasPrefix("cancelRoundSession")
            || event.hasPrefix("closeRoundSession")
    }

    static func runRoundEvent(_ signer: VotingDelegationSigner) -> String {
        signer == VotingDelegationSigner.keystoneStored ? "runRound.keystoneStored" : "runRound.otherSigner"
    }

    static func indexList(_ indices: [UInt32]) -> String {
        indices.map { String($0) }.joined(separator: ",")
    }

}

final class VotingMetadataBox: @unchecked Sendable {
    var drafts: [String: [String: UInt32]] = [:]
    var submittedVotes: [String: [String: UInt32]] = [:]
    var records: [String: PersistedVotingRecord] = [:]
}

/// A one-shot gate a stubbed dependency parks on until the test opens it, so an effect can be
/// held at a chosen suspension point without a real-time sleep.
actor TestGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumable = waiting
        waiting.removeAll()
        for continuation in resumable {
            continuation.resume()
        }
    }
}

/// Records what a reducer asked to sleep for and returns at once.
///
/// A `TestClock` would answer the same question, but only if the test manages
/// to advance it *after* the effect has registered its sleep — a race a plain
/// `Store` gives no hook to win. Recording the duration instead asserts the
/// backoff ladder exactly, with no real time passing and nothing to order.
///
/// `now` is a fixed instant so `sleep(for:)`'s deadline arithmetic is exact:
/// the duration recorded here is the one that was asked for, to the attosecond.
struct RecordingImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    // Spelled out because `ZcashLightClientKit` exports a `Duration` of its own,
    // and an unqualified one in this file resolves to that instead.
    typealias Duration = Swift.Duration

    let sleeps: LockIsolated<[Swift.Duration]>
    let epoch = ContinuousClock().now

    var now: Instant { epoch }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        // A real clock's sleep is a cancellation point, and an effect that is
        // cancelled while waiting out a backoff must not go on to send.
        try Task.checkCancellation()
        sleeps.withValue { $0.append(epoch.duration(to: deadline)) }
        await Task.yield()
        try Task.checkCancellation()
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    /// Appends `event` and returns how many times it has now been recorded, letting a
    /// closure double behave differently on its first call versus later calls.
    func recordAndCount(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

#endif
