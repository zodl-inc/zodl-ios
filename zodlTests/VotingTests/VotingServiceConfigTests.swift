#if VOTING_ENABLED
import CryptoKit
import Foundation
import Testing
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct VotingServiceConfigTests {
    @Test func decodeFromFullZIP1244CompliantJSON() throws {
        let json = """
        {
          "config_version": 1,
          "vote_servers": [
            {"url": "https://vote1.example.com", "label": "validator-1"}
          ],
          "pir_endpoints": [
            {"url": "https://pir1.example.com", "label": "pir-1"}
          ],
          "supported_versions": {
            "pir": ["v0", "v1"],
            "vote_protocol": "v0",
            "tally": "v0",
            "vote_server": "v1"
          },
          "rounds": {}
        }
        """
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))

        #expect(config.configVersion == 1)
        #expect(config.voteServers.count == 1)
        #expect(config.pirEndpoints.first?.label == "pir-1")
        #expect(config.supportedVersions.voteServer == "v1")
        #expect(config.supportedVersions.pir == ["v0", "v1"])
    }

    @Test func decodeAcceptsConfigWithoutProposalsSnapshotOrDeadline() {
        let json = """
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {}
        }
        """

        #expect(throws: Never.self) {
            try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))
        }
    }

    @Test func decodeAcceptsEmptyRoundsRegistry() throws {
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data("""
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {}
        }
        """.utf8))

        #expect(config.rounds.isEmpty)
        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func validateRejectsNonHexRoundId() {
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://x", label: "a")],
            pirEndpoints: [.init(url: "https://y", label: "b")],
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [
                String(repeating: "z", count: 64): .init(
                    authVersion: 1,
                    eaPk: Data(repeating: 0x01, count: 32),
                    signatures: []
                )
            ]
        )

        #expect(throws: (any Error).self) {
            try config.validate()
        }
    }

    @Test func staticConfigValidationRejectsShortTrustedKey() {
        let config = makeStaticConfig(trustedKeyBytes: Data(repeating: 0x01, count: 31))

        #expect(throws: (any Error).self) {
            try config.validate()
        }
    }

    @Test func pinnedConfigSourceParseAcceptsCosmovisorChecksumAndStripsIt() throws {
        let hex = String(repeating: "0a", count: 32)
        let source = try PinnedConfigSource.parse(
            "https://example.com/static-voting-config.json?foo=bar&checksum=sha256:\(hex)&baz=qux"
        )

        #expect(source.url.absoluteString == "https://example.com/static-voting-config.json?foo=bar&baz=qux")
        #expect(source.sha256?.count == 32)
        #expect(source.sha256?.first == 0x0a)
    }

    @Test func pinnedConfigSourceParseAcceptsMissingChecksum() throws {
        let source = try PinnedConfigSource.parse("https://example.com/static-voting-config.json")

        #expect(source.url.absoluteString == "https://example.com/static-voting-config.json")
        #expect(source.sha256 == nil)
    }

    @Test func pinnedConfigSourceParseRejectsMalformedSources() {
        let validHex = String(repeating: "0a", count: 32)
        let cases = [
            "https://example.com/static-voting-config.json?checksum=sha512:\(validHex)",
            "https://example.com/static-voting-config.json?checksum=sha256:\(String(repeating: "0A", count: 32))",
            "https://example.com/static-voting-config.json?checksum=sha256:\(String(repeating: "0g", count: 32))",
            "https://example.com/static-voting-config.json?checksum=sha256:\(String(repeating: "0a", count: 31))",
            "not a url?checksum=sha256:\(validHex)"
        ]

        for raw in cases {
            let error = #expect(throws: VotingConfigError.self, "raw=\(raw)") {
                try PinnedConfigSource.parse(raw)
            }
            guard case .staticConfigSourceMalformed? = error else {
                Issue.record("expected malformed source for \(raw), got \(String(describing: error))")
                continue
            }
        }
    }

    @Test func staticConfigDecodeAndVerifyAcceptsMatchingSHA256() throws {
        let config = makeStaticConfig()
        let data = try JSONEncoder().encode(config)
        let sha256 = Data(SHA256.hash(data: data))

        let decoded = try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: sha256)

        #expect(decoded == config)
    }

    @Test func staticConfigDecodeAndVerifyRejectsHashMismatch() throws {
        let data = try JSONEncoder().encode(makeStaticConfig())

        let error = #expect(throws: VotingConfigError.self) {
            try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: Data(repeating: 0, count: 32))
        }
        guard case .staticConfigHashMismatch? = error else {
            Issue.record("expected hash mismatch, got \(String(describing: error))")
            return
        }
    }

    @Test func staticConfigDecodeAndVerifyStillValidatesDecodedConfig() throws {
        let config = makeStaticConfig(trustedKeyBytes: Data(repeating: 0x01, count: 31))
        let data = try JSONEncoder().encode(config)
        let sha256 = Data(SHA256.hash(data: data))

        #expect(throws: (any Error).self) {
            try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: sha256)
        }
    }

    @Test func validateAcceptsCurrentWalletCapabilities() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1")
        )

        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func validateRejectsUnknownVoteServer() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v99")
        )

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .unsupportedVersion(let component, let advertised)? = error else {
            Issue.record("expected unsupportedVersion, got \(String(describing: error))")
            return
        }
        #expect(component == "vote_server")
        #expect(advertised == "v99")
    }

    @Test func validateRejectsWhenPIRIntersectionIsEmpty() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v42"], voteProtocol: "v0", tally: "v0", voteServer: "v1")
        )

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .unsupportedVersion(let component, _)? = error else {
            Issue.record("expected unsupportedVersion, got \(String(describing: error))")
            return
        }
        #expect(component == "pir")
    }

    @Test func validateAcceptsWhenPIRIntersectionIsNonEmpty() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v42", "v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1")
        )

        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func validateRejectsUnknownVoteProtocol() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v99", tally: "v0", voteServer: "v1")
        )

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .unsupportedVersion(let component, _)? = error else {
            Issue.record("expected unsupportedVersion, got \(String(describing: error))")
            return
        }
        #expect(component == "vote_protocol")
    }

    @Test func validateRejectsUnknownTally() {
        let config = makeConfig(
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v99", voteServer: "v1")
        )

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .unsupportedVersion(let component, _)? = error else {
            Issue.record("expected unsupportedVersion, got \(String(describing: error))")
            return
        }
        #expect(component == "tally")
    }

    private func makeConfig(supportedVersions: VotingServiceConfig.SupportedVersions) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://x", label: "a")],
            pirEndpoints: [.init(url: "https://y", label: "b")],
            supportedVersions: supportedVersions,
            rounds: [:]
        )
    }

    private func makeStaticConfig(
        trustedKeyBytes: Data = Data(repeating: 0x01, count: 32)
    ) -> StaticVotingConfig {
        StaticVotingConfig(
            staticConfigVersion: 1,
            dynamicConfigURL: URL(string: "https://example.com/dynamic-voting-config.json")!,
            trustedKeys: [
                .init(keyId: "test", alg: "ed25519", pubkey: trustedKeyBytes, notes: nil)
            ]
        )
    }
}

@Suite struct RoundAuthenticatorTests {
    private let roundId = "58d9319ac86933b81769a7c0972444fa39212ad3790646398de6ce6534de2225"
    private let eaPK = Data(base64Encoded: "N72oXeIF96QwWBtChaCwde3tjTt75ZfAs455V4usYwM=")!
    private let adminPubkey = Data(base64Encoded: "rKDbmhkoW9ja7dMiCV+1uTao7wXWV6xN/57erkrOuiQ=")!
    private let adminSignature = Data(
        base64Encoded: "rnll+KsHIFt73GpyNoWrX57dlcX8hTi8GU5X/xpwg3vcE+jCARUXpD7LsK+OLw6R5q1kU/zccwNgzsmclt4WAg=="
    )!

    @Test func authenticateAcceptsFixtureFromDynamicConfig() {
        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: eaPK,
                roundIdHex: roundId,
                rounds: [roundId: makeEntry()],
                trustedKeys: [makeTrustedKey()]
            ) == .authenticated
        )
    }

    @Test func authenticateReportsMissingRound() {
        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: eaPK,
                roundIdHex: roundId,
                rounds: [:],
                trustedKeys: [makeTrustedKey()]
            ) == .missingRound
        )
    }

    @Test func authenticateReportsUnknownAuthVersion() {
        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: eaPK,
                roundIdHex: roundId,
                rounds: [roundId: makeEntry(authVersion: 2)],
                trustedKeys: [makeTrustedKey()]
            ) == .unknownAuthVersion
        )
    }

    @Test func authenticateReportsInvalidSignatures() {
        var badSig = adminSignature
        badSig[0] ^= 0xFF

        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: eaPK,
                roundIdHex: roundId,
                rounds: [roundId: makeEntry(signature: badSig)],
                trustedKeys: [makeTrustedKey()]
            ) == .invalidSignatures
        )
    }

    @Test func authenticateReportsEaPKMismatch() {
        var chainEaPK = eaPK
        chainEaPK[0] ^= 0xFF

        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: chainEaPK,
                roundIdHex: roundId,
                rounds: [roundId: makeEntry()],
                trustedKeys: [makeTrustedKey()]
            ) == .eaPKMismatch
        )
    }

    @Test func authenticateReportsInvalidSignaturesWhenEntryEaPKIsShort() {
        #expect(
            RoundAuthenticator.authenticate(
                chainEaPK: eaPK,
                roundIdHex: roundId,
                rounds: [roundId: makeEntry(eaPK: Data(repeating: 0x01, count: 31))],
                trustedKeys: [makeTrustedKey()]
            ) == .invalidSignatures
        )
    }

    @Test func verifyEntrySignaturesRejectsUnknownKeyId() {
        let entry = makeEntry(keyId: "unknown-key")

        #expect(!RoundAuthenticator.verifyEntrySignatures(entry: entry, trustedKeys: [makeTrustedKey()]))
    }

    @Test func verifyEntrySignaturesRejectsSignatureAlgMismatch() {
        let entry = makeEntry(signatureAlg: "ed448")

        #expect(!RoundAuthenticator.verifyEntrySignatures(entry: entry, trustedKeys: [makeTrustedKey()]))
    }

    @Test func verifyEntrySignaturesRejectsTrustedKeyAlgMismatch() {
        let trustedKey = StaticVotingConfig.TrustedKey(
            keyId: "valar-test",
            alg: "ed448",
            pubkey: adminPubkey,
            notes: nil
        )

        #expect(!RoundAuthenticator.verifyEntrySignatures(entry: makeEntry(), trustedKeys: [trustedKey]))
    }

    @Test func verifyEntrySignaturesRejectsShortSignature() {
        let entry = makeEntry(signature: Data(repeating: 0x01, count: 63))

        #expect(!RoundAuthenticator.verifyEntrySignatures(entry: entry, trustedKeys: [makeTrustedKey()]))
    }

    @Test func verifyEntrySignaturesAcceptsWhenAnySignatureIsValid() {
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 1,
            eaPk: eaPK,
            signatures: [
                .init(keyId: "valar-test", alg: "ed25519", sig: Data(repeating: 0x01, count: 64)),
                .init(keyId: "valar-test", alg: "ed25519", sig: adminSignature)
            ]
        )

        #expect(RoundAuthenticator.verifyEntrySignatures(entry: entry, trustedKeys: [makeTrustedKey()]))
    }

    @Test func serviceConfigDropsOnlyRoundsWithoutValidSignatures() {
        var badSignature = adminSignature
        badSignature[0] ^= 0xFF
        let invalidRoundId = String(repeating: "b", count: 64)
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://vote.example.com", label: "vote")],
            pirEndpoints: [.init(url: "https://pir.example.com", label: "pir")],
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [
                roundId: makeEntry(),
                invalidRoundId: makeEntry(signature: badSignature)
            ]
        )

        let filtered = serviceConfigRetainingRoundsWithValidSignatures(config, trustedKeys: [makeTrustedKey()])

        #expect(Set(filtered.rounds.keys) == [roundId])
    }

    private func makeEntry(
        authVersion: Int = 1,
        eaPK: Data? = nil,
        keyId: String = "valar-test",
        signatureAlg: String = "ed25519",
        signature: Data? = nil
    ) -> VotingServiceConfig.RoundEntry {
        .init(
            authVersion: authVersion,
            eaPk: eaPK ?? self.eaPK,
            signatures: [
                .init(keyId: keyId, alg: signatureAlg, sig: signature ?? adminSignature)
            ]
        )
    }

    private func makeTrustedKey() -> StaticVotingConfig.TrustedKey {
        .init(keyId: "valar-test", alg: "ed25519", pubkey: adminPubkey, notes: nil)
    }
}

@Suite struct VotingSessionParsingTests {
    @Test func parseVotingSessionAcceptsValidProposalBounds() {
        #expect(throws: Never.self) {
            try parseVotingSession(from: makeRound())
        }
    }

    @Test func parseVotingSessionRejectsEmptyProposals() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: []))
        }
    }

    @Test func parseVotingSessionRejectsTooManyProposals() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: (1...16).map { makeProposal(id: $0) }))
        }
    }

    @Test func parseVotingSessionRejectsProposalIdOutsideRange() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [makeProposal(id: 16)]))
        }
    }

    @Test func parseVotingSessionRejectsDuplicateProposalIds() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [makeProposal(id: 1), makeProposal(id: 1)]))
        }
    }

    @Test func parseVotingSessionRejectsTooFewOptions() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [
                makeProposal(id: 1, options: [makeOption(index: 0)])
            ]))
        }
    }

    @Test func parseVotingSessionRejectsTooManyOptions() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [
                makeProposal(id: 1, options: (0...8).map { makeOption(index: $0) })
            ]))
        }
    }

    @Test func parseVotingSessionRejectsDuplicateOptionIndices() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [
                makeProposal(id: 1, options: [makeOption(index: 0), makeOption(index: 0)])
            ]))
        }
    }

    @Test func parseVotingSessionRejectsNonContiguousOptionIndices() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [
                makeProposal(id: 1, options: [makeOption(index: 0), makeOption(index: 2)])
            ]))
        }
    }

    private func makeRound(proposals: [[String: Any]]? = nil) -> [String: Any] {
        [
            "vote_round_id": Data(repeating: 0xAA, count: 32).base64EncodedString(),
            "snapshot_height": 1,
            "snapshot_blockhash": Data(repeating: 0x01, count: 32).base64EncodedString(),
            "proposals_hash": Data(repeating: 0x02, count: 32).base64EncodedString(),
            "vote_end_time": 3,
            "ceremony_phase_start": 2,
            "ea_pk": Data(repeating: 0x03, count: 32).base64EncodedString(),
            "vk_zkp1": Data(repeating: 0x04, count: 32).base64EncodedString(),
            "vk_zkp2": Data(repeating: 0x05, count: 32).base64EncodedString(),
            "vk_zkp3": Data(repeating: 0x06, count: 32).base64EncodedString(),
            "nc_root": Data(repeating: 0x07, count: 32).base64EncodedString(),
            "nullifier_imt_root": Data(repeating: 0x08, count: 32).base64EncodedString(),
            "creator": "creator",
            "description": "description",
            "proposals": proposals ?? [makeProposal(id: 1)],
            "status": SessionStatus.active.rawValue,
            "created_at_height": 1,
            "title": "Round"
        ]
    }

    private func makeProposal(id: Int, options: [[String: Any]]? = nil) -> [String: Any] {
        [
            "id": id,
            "title": "Proposal \(id)",
            "description": "Proposal description",
            "options": options ?? [makeOption(index: 0), makeOption(index: 1)]
        ]
    }

    private func makeOption(index: Int) -> [String: Any] {
        ["index": index, "label": "Option \(index)"]
    }
}

@Suite struct ShareRecoveryPollingTests {
    @Test func pollingConfirmsFromRecordedHelperInsteadOfFirstConfiguredHelper() async throws {
        let recorder = SharePostRecorder()
        let share = try makeShareDelegation(
            sentToURLs: [
                "https://helper-3.example.com",
                "https://helper-4.example.com",
                "https://helper-5.example.com"
            ],
            submitAt: 0,
            createdAt: 100
        )

        let result = await VotingCoordFlow.pollShareStatusesForRecovery(
            readyShares: [share],
            roundId: "aabb",
            now: 200,
            voteEndTime: 1_000,
            fetchShareStatus: { helperURL, _, _ in
                await recorder.record(helperURL)
                return helperURL == "https://helper-3.example.com" ? .confirmed : .pending
            }
        )

        let queriedServers = await recorder.servers()
        #expect(queriedServers == ["https://helper-3.example.com"])
        #expect(result.confirmedShares == [
            ShareDelegationKey(bundleIndex: 0, proposalId: 1, shareIndex: 0)
        ])
        #expect(result.resubmissionShares.isEmpty)
        #expect(result.queriedCount == 1)
    }

    @Test func pollingContinuesAfterOneRecordedHelperErrors() async throws {
        let recorder = SharePostRecorder()
        let share = try makeShareDelegation(
            sentToURLs: [
                "https://helper-3.example.com",
                "https://helper-4.example.com"
            ],
            submitAt: 0,
            createdAt: 100
        )

        let result = await VotingCoordFlow.pollShareStatusesForRecovery(
            readyShares: [share],
            roundId: "aabb",
            now: 200,
            voteEndTime: 1_000,
            fetchShareStatus: { helperURL, _, _ in
                await recorder.record(helperURL)
                if helperURL == "https://helper-3.example.com" {
                    throw SharePostFailure()
                }
                return .confirmed
            }
        )

        let queriedServers = await recorder.servers()
        #expect(queriedServers == [
            "https://helper-3.example.com",
            "https://helper-4.example.com"
        ])
        #expect(result.confirmedShares == [
            ShareDelegationKey(bundleIndex: 0, proposalId: 1, shareIndex: 0)
        ])
        #expect(result.resubmissionShares.isEmpty)
        #expect(result.queriedCount == 2)
    }

    @Test func immediateSharesUseCreatedAtForReadinessAndResubmission() throws {
        let share = try makeShareDelegation(
            sentToURLs: ["https://helper.example.com"],
            submitAt: 0,
            createdAt: 100
        )

        #expect(!VotingCoordFlow.isShareReadyForStatusCheck(share, now: 109))
        #expect(VotingCoordFlow.isShareReadyForStatusCheck(share, now: 110))
        #expect(!VotingCoordFlow.shouldResubmitShare(share, now: 129, voteEndTime: 200))
        #expect(VotingCoordFlow.shouldResubmitShare(share, now: 130, voteEndTime: 200))
    }

    @Test func delayedSharesUseSubmitAtForReadinessAndResubmission() throws {
        let share = try makeShareDelegation(
            sentToURLs: ["https://helper.example.com"],
            submitAt: 200,
            createdAt: 100
        )

        #expect(!VotingCoordFlow.isShareReadyForStatusCheck(share, now: 209))
        #expect(VotingCoordFlow.isShareReadyForStatusCheck(share, now: 210))
        #expect(!VotingCoordFlow.shouldResubmitShare(share, now: 229, voteEndTime: 320))
        #expect(VotingCoordFlow.shouldResubmitShare(share, now: 230, voteEndTime: 320))
    }
}

@Suite struct ShareResubmissionFallbackTests {
    @Test func resubmissionTriesUntriedHelpersFirst() async {
        let recorder = SharePostRecorder()

        let acceptedServers = await resubmitSharePayload(
            makeRecoverySharePayload(),
            roundIdHex: "aabb",
            configuredServerURLs: [
                "https://already-sent.example.com",
                "https://untried.example.com"
            ],
            sentToURLs: ["https://already-sent.example.com"],
            postShare: { server, _ in
                await recorder.record(server)
            },
            orderServers: { $0 }
        )

        #expect(acceptedServers == ["https://untried.example.com"])
        let recordedServers = await recorder.servers()
        #expect(recordedServers == ["https://untried.example.com"])
    }

    @Test func resubmissionFallsBackToAlreadySentHelperWhenUntriedFails() async {
        let recorder = SharePostRecorder()

        let acceptedServers = await resubmitSharePayload(
            makeRecoverySharePayload(),
            roundIdHex: "aabb",
            configuredServerURLs: [
                "https://already-sent.example.com",
                "https://untried.example.com"
            ],
            sentToURLs: ["https://already-sent.example.com"],
            postShare: { server, _ in
                await recorder.record(server)
                if server == "https://untried.example.com" {
                    throw SharePostFailure()
                }
            },
            orderServers: { $0 }
        )

        #expect(acceptedServers == ["https://already-sent.example.com"])
        let recordedServers = await recorder.servers()
        #expect(recordedServers == [
            "https://untried.example.com",
            "https://already-sent.example.com"
        ])
    }

    @Test func resubmissionReturnsEmptyWhenAllHelpersFail() async {
        let recorder = SharePostRecorder()

        let acceptedServers = await resubmitSharePayload(
            makeRecoverySharePayload(),
            roundIdHex: "aabb",
            configuredServerURLs: [
                "https://already-sent.example.com",
                "https://untried.example.com"
            ],
            sentToURLs: ["https://already-sent.example.com"],
            postShare: { server, _ in
                await recorder.record(server)
                throw SharePostFailure()
            },
            orderServers: { $0 }
        )

        #expect(acceptedServers.isEmpty)
        let recordedServers = await recorder.servers()
        #expect(recordedServers == [
            "https://untried.example.com",
            "https://already-sent.example.com"
        ])
    }
}

@Suite struct ShareDelegationPostFallbackTests {
    @Test func selectedHelperFailureBackfillsSameShareAndPrunesFailedHelper() async throws {
        let recorder = SharePostRecorder()
        let payload = makeRecoverySharePayload()

        let result = try await delegateSharePayloads(
            [payload],
            roundIdHex: "aabb",
            initialServerURLs: [
                "https://online-one.example.com",
                "https://offline.example.com",
                "https://online-two.example.com"
            ],
            postShare: { server, _ in
                await recorder.record(server)
                if server == "https://offline.example.com" {
                    throw SharePostFailure()
                }
            },
            selectTargets: { servers, targetCount in Array(servers.prefix(targetCount)) }
        )

        let recordedServers = await recorder.servers()
        #expect(recordedServers.count == 3)
        #expect(Set(recordedServers) == Set([
            "https://online-one.example.com",
            "https://offline.example.com",
            "https://online-two.example.com"
        ]))
        #expect(result.delegatedShares.first?.acceptedByServers == [
            "https://online-one.example.com",
            "https://online-two.example.com"
        ])
        #expect(result.remainingServerURLs == [
            "https://online-one.example.com",
            "https://online-two.example.com"
        ])
    }

    @Test func offlineHelperIsAttemptedAtMostOnceThenLaterSharesUseOnlineHelper() async throws {
        let recorder = SharePostRecorder()
        let payloads = (0..<2).map { makeRecoverySharePayload(index: UInt32($0)) }

        let result = try await delegateSharePayloads(
            payloads,
            roundIdHex: "aabb",
            initialServerURLs: [
                "https://offline.example.com",
                "https://online.example.com"
            ],
            postShare: { server, _ in
                await recorder.record(server)
                if server == "https://offline.example.com" {
                    throw SharePostFailure()
                }
            },
            selectTargets: { servers, targetCount in Array(servers.prefix(targetCount)) }
        )

        let recordedServers = await recorder.servers()
        #expect(recordedServers == [
            "https://offline.example.com",
            "https://online.example.com",
            "https://online.example.com"
        ])
        #expect(result.delegatedShares.map(\.acceptedByServers) == [
            ["https://online.example.com"],
            ["https://online.example.com"]
        ])
        #expect(result.remainingServerURLs == ["https://online.example.com"])
    }

    @Test func allSelectedHelpersFailButBackfillHelperSucceeds() async throws {
        let recorder = SharePostRecorder()
        let payload = makeRecoverySharePayload()

        let result = try await delegateSharePayloads(
            [payload],
            roundIdHex: "aabb",
            initialServerURLs: [
                "https://offline-one.example.com",
                "https://offline-two.example.com",
                "https://online.example.com"
            ],
            postShare: { server, _ in
                await recorder.record(server)
                if server != "https://online.example.com" {
                    throw SharePostFailure()
                }
            },
            selectTargets: { servers, targetCount in Array(servers.prefix(targetCount)) }
        )

        let recordedServers = await recorder.servers()
        #expect(recordedServers.count == 3)
        #expect(Set(recordedServers) == Set([
            "https://offline-one.example.com",
            "https://offline-two.example.com",
            "https://online.example.com"
        ]))
        #expect(result.delegatedShares.first?.acceptedByServers == ["https://online.example.com"])
        #expect(result.remainingServerURLs == ["https://online.example.com"])
    }

    @Test func allConfiguredHelpersFailThrowsNoReachableVoteServers() async {
        await #expect(throws: ShareDelegationError.noReachableVoteServers) {
            _ = try await delegateSharePayloads(
                [makeRecoverySharePayload()],
                roundIdHex: "aabb",
                initialServerURLs: [
                    "https://offline-one.example.com",
                    "https://offline-two.example.com"
                ],
                postShare: { _, _ in throw SharePostFailure() },
                selectTargets: { servers, targetCount in Array(servers.prefix(targetCount)) }
            )
        }
    }
}

@Suite struct DelegateSharesWithFallbackTests {
    @Test func delegateSharesWithFallbackRetriesReachabilityExhaustion() async throws {
        let attempts = AttemptCounter()
        var votingAPI = VotingAPIClient()
        votingAPI.delegateShares = { _, _, serverURLs in
            let attempt = await attempts.increment()
            if attempt < 3 {
                throw ShareDelegationError.noReachableVoteServers
            }
            return ShareDelegationResult(delegatedShares: [], remainingServerURLs: serverURLs)
        }

        let result = try await Voting.delegateSharesWithFallback(
            [],
            roundId: "aabb",
            votingAPI: votingAPI,
            serverURLs: ["https://vote.example.com"],
            retryDelay: .zero
        )

        let attemptCount = await attempts.value()
        #expect(attemptCount == 3)
        #expect(result.remainingServerURLs == ["https://vote.example.com"])
    }

    @Test func delegateSharesWithFallbackRethrowsUnexpectedErrorWithoutRetry() async {
        let attempts = AttemptCounter()
        var votingAPI = VotingAPIClient()
        votingAPI.delegateShares = { _, _, _ in
            _ = await attempts.increment()
            throw SharePostFailure()
        }

        await #expect(throws: SharePostFailure.self) {
            _ = try await Voting.delegateSharesWithFallback(
                [],
                roundId: "aabb",
                votingAPI: votingAPI,
                serverURLs: ["https://vote.example.com"],
                retryDelay: .zero
            )
        }
        let attemptCount = await attempts.value()
        #expect(attemptCount == 1)
    }
}

private actor SharePostRecorder {
    private var postedServers: [String] = []

    func record(_ server: String) {
        postedServers.append(server)
    }

    func servers() -> [String] {
        postedServers
    }
}

private actor AttemptCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private struct SharePostFailure: Error {}

private func makeShareDelegation(
    roundId: String = "aabb",
    bundleIndex: UInt32 = 0,
    proposalId: UInt32 = 1,
    shareIndex: UInt32 = 0,
    sentToURLs: [String],
    confirmed: Bool = false,
    submitAt: UInt64,
    createdAt: UInt64,
    nullifier: [UInt8] = Array(repeating: 0x0A, count: 32)
) throws -> VotingShareDelegation {
    let object: [String: Any] = [
        "round_id": roundId,
        "bundle_index": bundleIndex,
        "proposal_id": proposalId,
        "share_index": shareIndex,
        "sent_to_urls": sentToURLs,
        "nullifier": nullifier.map { String(format: "%02x", $0) }.joined(),
        "confirmed": confirmed,
        "submit_at": submitAt,
        "created_at": createdAt
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(VotingShareDelegation.self, from: data)
}

private func makeRecoverySharePayload(index: UInt32 = 0) -> SharePayload {
    let share = EncryptedShare(
        c1: Data(repeating: UInt8(index + 1), count: 32),
        c2: Data(repeating: UInt8(index + 2), count: 32),
        shareIndex: index
    )
    return SharePayload(
        sharesHash: Data(repeating: 0x01, count: 32),
        proposalId: 1,
        voteDecision: 0,
        encShare: share,
        treePosition: 10,
        allEncShares: [share],
        shareComms: [Data(repeating: 0x03, count: 32)],
        primaryBlind: Data(repeating: 0x04, count: 32),
        submitAt: 99
    )
}
#endif
