#if VOTING_ENABLED
import CryptoKit
import Foundation
import Testing
@preconcurrency import ZODLSwiftWalletSDK
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
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1, "poly_len": 4096}
        }
        """
        let config = try JSONDecoder().decode(VotingServiceConfig.self, from: Data(json.utf8))

        #expect(config.configVersion == 1)
        #expect(config.voteServers.count == 1)
        #expect(config.pirEndpoints.first?.label == "pir-1")
        #expect(config.supportedVersions.voteServer == "v1")
        #expect(config.supportedVersions.pir == ["v0", "v1"])
        // v1.3.0 chain field (MOB-1678): load-bearing since the zcash_voting 3.0 bump —
        // it feeds the delegation FFI and the round-auth v2 payload.
        #expect(config.pirLayout.polyLen == 4096)
    }

    @Test func decodeAcceptsConfigWithoutProposalsSnapshotOrDeadline() {
        let json = """
        {
          "config_version": 1,
          "vote_servers": [{"url": "https://x", "label": "a"}],
          "pir_endpoints": [{"url": "https://y", "label": "b"}],
          "supported_versions": {"pir": ["v0"], "vote_protocol": "v0", "tally": "v0", "vote_server": "v1"},
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1}
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
          "rounds": {},
          "pir_layout": {"pir_depth": 1, "tier0_layers": 1, "tier1_layers": 1}
        }
        """.utf8))

        #expect(config.rounds.isEmpty)
        // Pre-v1.3.0 / cached / mainnet-until-tomorrow: no poly_len key at all still decodes.
        #expect(config.pirLayout.polyLen == nil)
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
            ],
            pirLayout: .init(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)
        )

        #expect(throws: (any Error).self) {
            try config.validate()
        }
    }

    @Test func validateRejectsDuplicateVoteServerURLs() {
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [
                VotingServiceConfig.ServiceEndpoint(url: "https://one.example.com", label: "Primary"),
                VotingServiceConfig.ServiceEndpoint(url: "https://one.example.com", label: "Backup")
            ],
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)
        )

        #expect(throws: (any Error).self) {
            try config.validate()
        }
    }

    @Test func validateRejectsDuplicatePirEndpointURLs() {
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")],
            pirEndpoints: [
                VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "Primary"),
                VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "Backup")
            ],
            supportedVersions: VotingServiceConfig.SupportedVersions(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)
        )

        #expect(throws: (any Error).self) {
            try config.validate()
        }
    }

    @Test func validateAcceptsDuplicateLabelsWithDistinctURLs() {
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [
                VotingServiceConfig.ServiceEndpoint(url: "https://one.example.com", label: "mirror"),
                VotingServiceConfig.ServiceEndpoint(url: "https://two.example.com", label: "mirror")
            ],
            pirEndpoints: [VotingServiceConfig.ServiceEndpoint(url: "https://pir.example.com", label: "pir")],
            supportedVersions: VotingServiceConfig.SupportedVersions(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [:],
            pirLayout: VotingServiceConfig.PirLayout(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)
        )

        #expect(throws: Never.self) {
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

    /// The bundled anchor is a hand-edited string literal carrying a 64-char hash,
    /// and `PinnedConfigSource.sha256` is optional by design — a source without a
    /// `?checksum=` is legal and parses fine (see
    /// `pinnedConfigSourceParseAcceptsMissingChecksum`). `decodeAndVerify` only
    /// checks the digest `if let expectedSHA256`, so a pin that loses its checksum
    /// to a typo, a bad merge, or a truncated edit does not fail — it silently
    /// accepts whatever the host returns, turning the anchor into plain trust in
    /// the transport. Nothing else in the suite pins the bundled constant itself.
    @Test func bundledPinnedSourceCarriesAChecksumSoVerificationCannotSilentlyNoOp() throws {
        #expect(StaticVotingConfig.bundledPinnedSources.first == StaticVotingConfig.bundledPinnedSource)

        for raw in StaticVotingConfig.bundledPinnedSources {
            let source = try PinnedConfigSource.parse(raw)

            #expect(source.url.scheme == "https")
            let digest = try #require(
                source.sha256,
                "bundled pin carries no checksum — decodeAndVerify would accept any bytes the host serves"
            )
            #expect(digest.count == 32)

            // The digest is the pin; it must not also travel to the server as a query
            // the host could key behaviour off.
            let sentQuery = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(!sentQuery.contains { $0.name == "checksum" })
        }
    }

    @Test func staticConfigDecodeAndVerifyAcceptsMatchingSHA256() throws {
        let data = Data(decodeAndVerifyFixtureJSON.utf8)
        let sha256 = Data(SHA256.hash(data: data))

        let decoded = try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: sha256)

        #expect(decoded == makeStaticConfig())
    }

    @Test func staticConfigDecodeAndVerifyRejectsHashMismatch() throws {
        let data = Data(decodeAndVerifyFixtureJSON.utf8)

        let error = #expect(throws: VotingConfigError.self) {
            try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: Data(repeating: 0, count: 32))
        }
        guard case .staticConfigHashMismatch? = error else {
            Issue.record("expected hash mismatch, got \(String(describing: error))")
            return
        }
    }

    @Test func staticConfigDecodeAndVerifyStillValidatesDecodedConfig() throws {
        // 31-byte trusted key: the hash matches and decode succeeds, so the
        // rejection can only come from validate().
        let json = """
        {
          "static_config_version": 1,
          "dynamic_config_url": "https://example.com/dynamic-voting-config.json",
          "trusted_keys": [
            {"key_id": "test", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 31).base64EncodedString())"}
          ]
        }
        """
        let data = Data(json.utf8)
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

    @Test func resolvesAConfigThatAdvertisesVoteProtocolV1() {
        let config = makeConfig(
            supportedVersions: VotingServiceConfig.SupportedVersions(pir: ["v0"], voteProtocol: "v1", tally: "v0", voteServer: "v1")
        )

        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func rejectsAnUnknownVoteProtocol() {
        let config = makeConfig(
            supportedVersions: VotingServiceConfig.SupportedVersions(pir: ["v0"], voteProtocol: "v2", tally: "v0", voteServer: "v1")
        )

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .unsupportedVersion(let component, let advertised)? = error else {
            Issue.record("expected unsupportedVersion, got \(String(describing: error))")
            return
        }
        #expect(component == "vote_protocol")
        #expect(advertised == "v2")
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

    @Test func staticConfigDecodesV1SingularURL() throws {
        let json = """
        {
          "static_config_version": 1,
          "dynamic_config_url": "https://voting.valargroup.dev/prod/dynamic-voting-config.json",
          "trusted_keys": [
            {"key_id": "valargroup", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 32).base64EncodedString())"}
          ]
        }
        """
        let config = try JSONDecoder().decode(StaticVotingConfig.self, from: Data(json.utf8))

        #expect(config.staticConfigVersion == 1)
        #expect(config.dynamicConfigURLs.map(\.absoluteString) == ["https://voting.valargroup.dev/prod/dynamic-voting-config.json"])
        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func staticConfigDecodesV2MirrorList() throws {
        let json = """
        {
          "static_config_version": 2,
          "dynamic_config_urls": [
            "https://voting.valargroup.dev/prod/dynamic-voting-config.json",
            "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/prod/dynamic-voting-config.json"
          ],
          "trusted_keys": [
            {"key_id": "valargroup", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 32).base64EncodedString())"}
          ]
        }
        """
        let config = try JSONDecoder().decode(StaticVotingConfig.self, from: Data(json.utf8))

        #expect(config.staticConfigVersion == 2)
        #expect(config.dynamicConfigURLs.count == 2)
        #expect(config.dynamicConfigURLs.first?.host == "voting.valargroup.dev")
        #expect(config.dynamicConfigURLs.last?.host == "raw.githubusercontent.com")
        #expect(throws: Never.self) {
            try config.validate()
        }
    }

    @Test func staticConfigV2RejectsEmptyMirrorList() throws {
        let config = StaticVotingConfig(
            staticConfigVersion: 2,
            dynamicConfigURLs: [],
            trustedKeys: [
                StaticVotingConfig.TrustedKey(keyId: "test", alg: "ed25519", pubkey: Data(repeating: 0x01, count: 32), notes: nil)
            ]
        )

        #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
    }

    @Test func staticConfigV2RejectsSingularOnlyDocument() {
        let json = """
        {
          "static_config_version": 2,
          "dynamic_config_url": "https://voting.valargroup.dev/prod/dynamic-voting-config.json",
          "trusted_keys": []
        }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StaticVotingConfig.self, from: Data(json.utf8))
        }
    }

    @Test func staticConfigV1RejectsPluralOnlyDocument() {
        let json = """
        {
          "static_config_version": 1,
          "dynamic_config_urls": ["https://voting.valargroup.dev/prod/dynamic-voting-config.json"],
          "trusted_keys": []
        }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StaticVotingConfig.self, from: Data(json.utf8))
        }
    }

    @Test func staticConfigRejectsUnsupportedVersionWithClearMessage() throws {
        let json = """
        {
          "static_config_version": 3,
          "trusted_keys": [
            {"key_id": "valargroup", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 32).base64EncodedString())"}
          ]
        }
        """
        let config = try JSONDecoder().decode(StaticVotingConfig.self, from: Data(json.utf8))

        let error = #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
        guard case .decodeFailed(let detail)? = error else {
            Issue.record("expected decodeFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("unsupported static_config_version 3"))
    }

    @Test func staticConfigRejectsNonHTTPSMirrorEntry() throws {
        let config = StaticVotingConfig(
            staticConfigVersion: 2,
            dynamicConfigURLs: [
                URL(string: "https://voting.valargroup.dev/prod/dynamic-voting-config.json")!,
                URL(string: "http://mirror.example.com/dynamic-voting-config.json")!
            ],
            trustedKeys: [
                StaticVotingConfig.TrustedKey(keyId: "test", alg: "ed25519", pubkey: Data(repeating: 0x01, count: 32), notes: nil)
            ]
        )

        #expect(throws: VotingConfigError.self) {
            try config.validate()
        }
    }

    @Test func fetchFailuresRenderAsFetchFailedNotDecodeFailed() {
        let dynamicMessage = VotingConfigError.dynamicConfigFetchFailed("CDN returned HTTP 403", statusCode: 403).errorDescription ?? ""
        let staticMessage = VotingConfigError.staticConfigFetchFailed("HTTP 503").errorDescription ?? ""

        #expect(dynamicMessage.contains("fetch failed"))
        #expect(staticMessage.contains("fetch failed"))
        #expect(!dynamicMessage.contains("decode"))
        #expect(!staticMessage.contains("decode"))
    }

    @Test func resolveConfigSourcesUsesBundledWalkForNilOverride() {
        #expect(StaticVotingConfig.resolveConfigSources(override: nil) == StaticVotingConfig.bundledParsedSources)
    }

    @Test func resolveConfigSourcesKeepsBundledWalkForSavedBundledMirror() throws {
        for raw in StaticVotingConfig.bundledPinnedSources {
            let source = try PinnedConfigSource.parse(raw)
            #expect(StaticVotingConfig.resolveConfigSources(override: source) == StaticVotingConfig.bundledParsedSources)
        }
    }

    @Test func resolveConfigSourcesIsolatesCustomOverride() throws {
        let custom = try PinnedConfigSource.parse("https://example.com/static-voting-config.json")
        #expect(StaticVotingConfig.resolveConfigSources(override: custom) == [custom])
    }

    private func makeConfig(supportedVersions: VotingServiceConfig.SupportedVersions) -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://x", label: "a")],
            pirEndpoints: [.init(url: "https://y", label: "b")],
            supportedVersions: supportedVersions,
            rounds: [:],
            pirLayout: .init(pirDepth: 1, tier0Layers: 1, tier1Layers: 1)
        )
    }

    private let decodeAndVerifyFixtureJSON = """
    {
      "static_config_version": 1,
      "dynamic_config_url": "https://example.com/dynamic-voting-config.json",
      "trusted_keys": [
        {"key_id": "test", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 32).base64EncodedString())"}
      ]
    }
    """

    private func makeStaticConfig(
        trustedKeyBytes: Data = Data(repeating: 0x01, count: 32)
    ) -> StaticVotingConfig {
        StaticVotingConfig(
            staticConfigVersion: 1,
            dynamicConfigURLs: [URL(string: "https://example.com/dynamic-voting-config.json")!],
            trustedKeys: [
                StaticVotingConfig.TrustedKey(keyId: "test", alg: "ed25519", pubkey: trustedKeyBytes, notes: nil)
            ]
        )
    }
}

@Suite struct RoundAuthenticatorTests {
    private let roundId = "58d9319ac86933b81769a7c0972444fa39212ad3790646398de6ce6534de2225"
    private let otherRoundId = "0000000000000000000000000000000000000000000000000000000000000002"
    private let eaPK = Data(base64Encoded: "N72oXeIF96QwWBtChaCwde3tjTt75ZfAs455V4usYwM=")!
    /// Layout mirroring the crate's `test_pir_layout()` (config/mod.rs tests): 19/12/7/4096.
    private let pirLayout = VotingServiceConfig.PirLayout(
        pirDepth: 19,
        tier0Layers: 12,
        tier1Layers: 7,
        polyLen: 4096
    )
    /// Fresh per-test admin key; entries are signed the way the crate's tests do —
    /// ed25519 over the constructed v2 payload (round_auth.rs test recipe).
    private let adminKey = Curve25519.Signing.PrivateKey()

    // Golden vector from zcash_voting 3.0.0-rc.2
    // (`dynamic_resolution_accepts_vote_sdk_ui_signed_round_entry`, config/mod.rs):
    // a vote-sdk admin-UI / Keplr-derived key signing the poly_len-bound v2 preimage
    // (tag || round_id || ea_pk || 19/12/7/4096). Passing pins byte-for-byte
    // compatibility with the crate's verifier.
    @Test func authenticateAcceptsCrateGoldenVector() {
        let goldenRoundId = "06aae723e42cf615d174f338e8f30a72d2bf3275eb9d9e835cc894f197904b20"
        let goldenKeyId = "keplr:sv1mqts0klc9768rns9h2ykeaka5tve6ts39c2zu3"
        let goldenEaPK = Data(base64Encoded: "GpYa1sCGIMe2bp1O9UgrThrwkCdxu6oHDmhoBTw6EZ8=")!
        let goldenPubkey = Data(base64Encoded: "NDygCpG+Y4T4uu8M1Sb/YG+74lUVj9XgYypUoMQMXT8=")!
        let goldenSig = Data(
            base64Encoded: "RHbpnj2a1VA+wadIQT3JM/r6ADH11VeA8UgT5dhwhixMcS5Bw5ispndM/ZYH/d2vxNBxTRtZwnLyXZjxcVD+Dg=="
        )!
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: goldenEaPK,
            signatures: [.init(keyId: goldenKeyId, alg: "ed25519", sig: goldenSig)]
        )
        let trustedKey = StaticVotingConfig.TrustedKey(
            keyId: goldenKeyId,
            alg: "ed25519",
            pubkey: goldenPubkey,
            notes: nil
        )

        let status = authenticate(
            chainEaPK: goldenEaPK,
            roundIdHex: goldenRoundId,
            rounds: [goldenRoundId: entry],
            trustedKeys: [trustedKey]
        )
        #expect(status == .authenticated)
    }

    // Golden byte layout from zcash_voting 3.0.0-rc.2
    // (`encoding_matches_round_auth_v2_wire_format`, round_auth.rs): round_id [1u8; 32],
    // ea_pk [2u8; 32], layout 19/12/7/4096, every u32 little-endian.
    @Test func signingPayloadV2MatchesCrateWireFormat() throws {
        let payload = try #require(RoundAuthenticator.signingPayloadV2(
            roundIdHex: String(repeating: "01", count: 32),
            eaPk: Data(repeating: 0x02, count: 32),
            pirLayout: pirLayout
        ))

        var expected = Data("zcash-shielded-vote:round-auth:v2".utf8)
        expected.append(Data(repeating: 0x01, count: 32))
        expected.append(Data(repeating: 0x02, count: 32))
        expected.append(Data([19, 0, 0, 0]))
        expected.append(Data([12, 0, 0, 0]))
        expected.append(Data([7, 0, 0, 0]))
        expected.append(Data([0x00, 0x10, 0x00, 0x00]))
        let matches = payload == expected
        #expect(matches)
        #expect(payload.count == 113)
    }

    @Test func authenticateAcceptsV2EntrySignedOverV2Payload() throws {
        let entry = try makeSignedEntry()

        let status = authenticate(rounds: [roundId: entry])
        #expect(status == .authenticated)
    }

    @Test func authenticateReportsMissingRound() {
        let status = authenticate(rounds: [:])
        #expect(status == .missingRound)
    }

    // v1 policy pin (MOB-1678, deliberate + overturnable — see `RoundAuthenticator`):
    // a *valid* v1-style signature over the raw `ea_pk` must no longer authenticate,
    // matching the crate's `dynamic_resolution_skips_legacy_auth_version_1_rounds`.
    @Test func authenticateRejectsLegacyV1Entry() throws {
        let v1Signature = try adminKey.signature(for: eaPK)
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 1,
            eaPk: eaPK,
            signatures: [.init(keyId: "valar-test", alg: "ed25519", sig: v1Signature)]
        )

        let status = authenticate(rounds: [roundId: entry])
        #expect(status == .unknownAuthVersion)
    }

    @Test func authenticateReportsInvalidSignatures() throws {
        var badSig = try makeSignedEntry().signatures[0].sig
        badSig[0] ^= 0xFF
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: eaPK,
            signatures: [.init(keyId: "valar-test", alg: "ed25519", sig: badSig)]
        )

        let status = authenticate(rounds: [roundId: entry])
        #expect(status == .invalidSignatures)
    }

    @Test func authenticateReportsEaPKMismatch() throws {
        var chainEaPK = eaPK
        chainEaPK[0] ^= 0xFF
        let entry = try makeSignedEntry()

        let status = authenticate(chainEaPK: chainEaPK, rounds: [roundId: entry])
        #expect(status == .eaPKMismatch)
    }

    @Test func authenticateReportsInvalidSignaturesWhenEntryEaPKIsShort() {
        let shortEaPK = Data(repeating: 0x01, count: 31)
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: shortEaPK,
            signatures: [.init(keyId: "valar-test", alg: "ed25519", sig: Data(repeating: 0x01, count: 64))]
        )

        let status = authenticate(chainEaPK: shortEaPK, rounds: [roundId: entry])
        #expect(status == .invalidSignatures)
    }

    // The v2 signature binds the round id: the crate's replay test
    // (`dynamic_resolution_skips_round_entry_replayed_under_different_round_id`).
    @Test func authenticateRejectsEntryReplayedUnderDifferentRoundId() throws {
        let entry = try makeSignedEntry() // signed for `roundId`

        let status = authenticate(roundIdHex: otherRoundId, rounds: [otherRoundId: entry])
        #expect(status == .invalidSignatures)
    }

    // The v2 signature binds the full PIR layout: a config host swapping poly_len (or any
    // tier) after signing invalidates the attestation
    // (`dynamic_resolution_skips_rounds_when_pir_layout_changed_after_signing`).
    @Test func authenticateRejectsWhenPolyLenChangedAfterSigning() throws {
        let entry = try makeSignedEntry() // signed over poly_len 4096
        let swappedLayout = VotingServiceConfig.PirLayout(
            pirDepth: 19,
            tier0Layers: 12,
            tier1Layers: 7,
            polyLen: 2048
        )

        let status = authenticate(rounds: [roundId: entry], pirLayout: swappedLayout)
        #expect(status == .invalidSignatures)
    }

    // A config that predates `pir_layout.poly_len` cannot carry v2 attestations: the
    // payload is unconstructible, so nothing authenticates (fail closed).
    @Test func authenticateRejectsWhenConfigLacksPolyLen() throws {
        let entry = try makeSignedEntry()
        let preBumpLayout = VotingServiceConfig.PirLayout(pirDepth: 19, tier0Layers: 12, tier1Layers: 7)

        let status = authenticate(rounds: [roundId: entry], pirLayout: preBumpLayout)
        #expect(status == .invalidSignatures)
    }

    // Crate parity (`verify_round_entry` decodes defensively): a round id that does not
    // strict-hex-decode to exactly 32 bytes can never authenticate.
    @Test func authenticateRejectsRoundIdsThatDoNotDecodeTo32Bytes() throws {
        let thirtyOneByteId = String(repeating: "ab", count: 31)
        let nonHexId = String(repeating: "zz", count: 32)
        for badId in [thirtyOneByteId, nonHexId] {
            let entry = try makeSignedEntry(roundIdHex: badId)

            let status = authenticate(roundIdHex: badId, rounds: [badId: entry])
            #expect(status == .invalidSignatures, "round id \(badId) must never authenticate")
        }
    }

    @Test func verifyEntrySignaturesRejectsUnknownKeyId() throws {
        let entry = try makeSignedEntry(keyId: "unknown-key")

        #expect(!verify(entry))
    }

    @Test func verifyEntrySignaturesRejectsSignatureAlgMismatch() throws {
        let entry = try makeSignedEntry(signatureAlg: "ed448")

        #expect(!verify(entry))
    }

    @Test func verifyEntrySignaturesRejectsTrustedKeyAlgMismatch() throws {
        let trustedKey = StaticVotingConfig.TrustedKey(
            keyId: "valar-test",
            alg: "ed448",
            pubkey: adminKey.publicKey.rawRepresentation,
            notes: nil
        )
        let entry = try makeSignedEntry()

        let valid = RoundAuthenticator.verifyEntrySignatures(
            entry: entry,
            roundIdHex: roundId,
            pirLayout: pirLayout,
            trustedKeys: [trustedKey]
        )
        #expect(!valid)
    }

    @Test func verifyEntrySignaturesRejectsShortSignature() {
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: eaPK,
            signatures: [.init(keyId: "valar-test", alg: "ed25519", sig: Data(repeating: 0x01, count: 63))]
        )

        #expect(!verify(entry))
    }

    @Test func verifyEntrySignaturesAcceptsWhenAnySignatureIsValid() throws {
        let validSignature = try makeSignedEntry().signatures[0].sig
        let entry = VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: eaPK,
            signatures: [
                .init(keyId: "valar-test", alg: "ed25519", sig: Data(repeating: 0x01, count: 64)),
                .init(keyId: "valar-test", alg: "ed25519", sig: validSignature)
            ]
        )

        #expect(verify(entry))
    }

    @Test func serviceConfigDropsOnlyRoundsWithoutValidSignatures() throws {
        // One entry validly signed for its own id; the same entry replayed verbatim under
        // another id (signature binds the round id → dropped); one legacy v1 entry (dropped).
        let validEntry = try makeSignedEntry()
        let v1Entry = VotingServiceConfig.RoundEntry(
            authVersion: 1,
            eaPk: eaPK,
            signatures: [.init(keyId: "valar-test", alg: "ed25519", sig: try adminKey.signature(for: eaPK))]
        )
        let v1RoundId = String(repeating: "b", count: 64)
        let config = VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://vote.example.com", label: "vote")],
            pirEndpoints: [.init(url: "https://pir.example.com", label: "pir")],
            supportedVersions: .init(pir: ["v0"], voteProtocol: "v0", tally: "v0", voteServer: "v1"),
            rounds: [
                roundId: validEntry,
                otherRoundId: validEntry,
                v1RoundId: v1Entry
            ],
            pirLayout: pirLayout
        )

        let filtered = serviceConfigRetainingRoundsWithValidSignatures(config, trustedKeys: [makeTrustedKey()])

        #expect(Set(filtered.rounds.keys) == [roundId])
    }

    /// Builds a registry entry signed exactly the way the crate's tests sign theirs:
    /// ed25519 over `signingPayloadV2` for this suite's round, ea_pk, and layout.
    private func makeSignedEntry(
        roundIdHex: String? = nil,
        keyId: String = "valar-test",
        signatureAlg: String = "ed25519"
    ) throws -> VotingServiceConfig.RoundEntry {
        // For undecodable round ids the canonical payload cannot exist; sign a stand-in so
        // the entry still carries a well-formed 64-byte signature for the verifier to refuse.
        let payload = RoundAuthenticator.signingPayloadV2(
            roundIdHex: roundIdHex ?? roundId,
            eaPk: eaPK,
            pirLayout: pirLayout
        ) ?? Data("undecodable-round-id-stand-in".utf8)
        return VotingServiceConfig.RoundEntry(
            authVersion: 2,
            eaPk: eaPK,
            signatures: [.init(keyId: keyId, alg: signatureAlg, sig: try adminKey.signature(for: payload))]
        )
    }

    /// `RoundAuthenticator.authenticate` with this suite's fixtures defaulted in.
    /// Kept as a plain function returning a local so `#expect` only ever compares
    /// two simple values — inlining the full call into the macro blows past the
    /// type-checker's expression budget.
    private func authenticate(
        chainEaPK: Data? = nil,
        roundIdHex: String? = nil,
        rounds: [String: VotingServiceConfig.RoundEntry],
        trustedKeys: [StaticVotingConfig.TrustedKey]? = nil,
        pirLayout: VotingServiceConfig.PirLayout? = nil
    ) -> RoundAuthStatus {
        RoundAuthenticator.authenticate(
            chainEaPK: chainEaPK ?? eaPK,
            roundIdHex: roundIdHex ?? roundId,
            rounds: rounds,
            trustedKeys: trustedKeys ?? [makeTrustedKey()],
            pirLayout: pirLayout ?? self.pirLayout
        )
    }

    private func verify(_ entry: VotingServiceConfig.RoundEntry) -> Bool {
        RoundAuthenticator.verifyEntrySignatures(
            entry: entry,
            roundIdHex: roundId,
            pirLayout: pirLayout,
            trustedKeys: [makeTrustedKey()]
        )
    }

    private func makeTrustedKey() -> StaticVotingConfig.TrustedKey {
        .init(keyId: "valar-test", alg: "ed25519", pubkey: adminKey.publicKey.rawRepresentation, notes: nil)
    }
}

@Suite struct VotingSessionParsingTests {
    @Test func parseVotingSessionAcceptsValidProposalBounds() {
        #expect(throws: Never.self) {
            try parseVotingSession(from: makeRound())
        }
    }

    @Test func parseVotingSessionAcceptsThirtySevenProposals() throws {
        let session = try parseVotingSession(from: makeRound(proposals: (1...37).map { makeProposal(id: $0) }))

        #expect(session.proposals.count == 37)
    }

    @Test func parseVotingSessionAcceptsProposalIdFifty() {
        #expect(throws: Never.self) {
            try parseVotingSession(from: makeRound(proposals: [makeProposal(id: 50)]))
        }
    }

    @Test func parseVotingSessionRejectsEmptyProposals() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: []))
        }
    }

    @Test func parseVotingSessionRejectsTooManyProposals() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: (1...51).map { makeProposal(id: $0) }))
        }
    }

    @Test func parseVotingSessionRejectsProposalIdOutsideRange() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [makeProposal(id: 51)]))
        }
    }

    @Test func parseVotingSessionRejectsProposalIdZero() {
        #expect(throws: (any Error).self) {
            try parseVotingSession(from: makeRound(proposals: [makeProposal(id: 0)]))
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

    @Test func parseVotingSessionsSkipsARoundThatFailsValidation() {
        let validRound = makeRound(roundIdByte: 0xAA)
        let invalidRound = makeRound(proposals: [makeProposal(id: 51)])
        let validRound2 = makeRound(roundIdByte: 0xBB)

        let sessions = parseVotingSessions(skippingInvalidRounds: [validRound, invalidRound, validRound2])

        #expect(sessions.map(\.voteRoundId) == [
            Data(repeating: 0xAA, count: 32),
            Data(repeating: 0xBB, count: 32)
        ])
    }

    @Test func parseVotingSessionsReturnsEmptyWhenEveryRoundIsInvalid() {
        let sessions = parseVotingSessions(skippingInvalidRounds: [
            makeRound(proposals: []),
            makeRound(proposals: [makeProposal(id: 51)])
        ])

        #expect(sessions.isEmpty)
    }

    private func makeRound(roundIdByte: UInt8 = 0xAA, proposals: [[String: Any]]? = nil) -> [String: Any] {
        [
            "vote_round_id": Data(repeating: roundIdByte, count: 32).base64EncodedString(),
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
#endif
