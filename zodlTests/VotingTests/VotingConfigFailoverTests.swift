#if VOTING_ENABLED
import CryptoKit
import Foundation
import os
import Testing
@testable import zodl_internal

@Suite struct StaticConfigMirrorWalkTests {
    private let validConfigJSON = """
    {
      "static_config_version": 2,
      "dynamic_config_urls": ["https://voting.valargroup.dev/prod/dynamic-voting-config.json"],
      "trusted_keys": [
        {"key_id": "test", "alg": "ed25519", "pubkey": "\(Data(repeating: 0x01, count: 32).base64EncodedString())"}
      ]
    }
    """

    private func hexString(_ data: Data) -> String {
        data.map { byte in String(format: "%02x", byte) }.joined()
    }

    private func pinnedSource(host: String, for bytes: Data) throws -> PinnedConfigSource {
        let hex = hexString(Data(SHA256.hash(data: bytes)))
        return try PinnedConfigSource.parse("https://\(host)/pins/prod/\(hex)/v2-static-voting-config.json?checksum=sha256:\(hex)")
    }

    private func okResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func walkReturnsFirstHealthyMirrorWithoutTouchingTheSecond() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        let config = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
            requestedHosts.withLock { $0.append(request.url!.host!) }
            return (bytes, self.okResponse(request))
        }

        #expect(config.staticConfigVersion == 2)
        #expect(requestedHosts.withLock { $0 } == ["primary.example"])
    }

    @Test func walkFallsThroughOnTransportError() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        let config = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
            let host = request.url!.host!
            requestedHosts.withLock { $0.append(host) }
            if host == "primary.example" {
                throw URLError(URLError.Code.cannotFindHost)
            }
            return (bytes, self.okResponse(request))
        }

        #expect(config.staticConfigVersion == 2)
        #expect(requestedHosts.withLock { $0 } == ["primary.example", "mirror.example"])
    }

    @Test func walkFallsThroughOnHTTPFailureStatus() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]

        let config = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
            if request.url!.host! == "primary.example" {
                return (Data(), self.okResponse(request, status: 503))
            }
            return (bytes, self.okResponse(request))
        }

        #expect(config.staticConfigVersion == 2)
    }

    @Test func walkFallsThroughOnHashMismatch() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]

        let config = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
            if request.url!.host! == "primary.example" {
                return (Data("tampered".utf8), self.okResponse(request))
            }
            return (bytes, self.okResponse(request))
        }

        #expect(config.staticConfigVersion == 2)
    }

    @Test func walkStopsOnDecodeFailureAfterHashMatch() async throws {
        // The pin matches the garbage bytes, so the failure is authoritative:
        // every mirror serves the same pinned bytes, trying more cannot help.
        let garbage = Data("{\"static_config_version\": 2}".utf8)
        let goodBytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: garbage),
            try pinnedSource(host: "mirror.example", for: goodBytes)
        ]
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        await #expect(throws: VotingConfigError.self) {
            _ = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
                requestedHosts.withLock { $0.append(request.url!.host!) }
                if request.url!.host! == "primary.example" {
                    return (garbage, self.okResponse(request))
                }
                return (goodBytes, self.okResponse(request))
            }
        }
        #expect(requestedHosts.withLock { $0 } == ["primary.example"])
    }

    @Test func walkReportsFirstErrorWhenAllMirrorsFail() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]

        // Both mirrors fail with the same case but distinguishable payloads
        // (HTTP 503 vs 502), so asserting the exact detail proves first-error
        // retention rather than last-error retention.
        let error = await #expect(throws: VotingConfigError.self) {
            _ = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
                if request.url!.host! == "primary.example" {
                    return (Data(), self.okResponse(request, status: 503))
                }
                return (Data(), self.okResponse(request, status: 502))
            }
        }
        guard case .staticConfigFetchFailed(let detail)? = error else {
            Issue.record("expected the primary's fetch failure, got \(String(describing: error))")
            return
        }
        #expect(detail == "HTTP 503")
    }

    @Test func walkRejectsEmptySourceList() async throws {
        let fetchInvoked = OSAllocatedUnfairLock(initialState: false)

        let error = await #expect(throws: VotingConfigError.self) {
            _ = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: []) { request in
                fetchInvoked.withLock { $0 = true }
                return (Data(), self.okResponse(request))
            }
        }
        guard case .staticConfigSourceMalformed? = error else {
            Issue.record("expected staticConfigSourceMalformed for an empty source list, got \(String(describing: error))")
            return
        }
        #expect(!fetchInvoked.withLock { $0 })
    }

    @Test func walkStampsPerAttemptTimeout() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [try pinnedSource(host: "primary.example", for: bytes)]
        let observedTimeout = OSAllocatedUnfairLock(initialState: TimeInterval(0))

        _ = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
            observedTimeout.withLock { $0 = request.timeoutInterval }
            return (bytes, self.okResponse(request))
        }

        #expect(observedTimeout.withLock { $0 } == StaticVotingConfig.configRequestTimeout)
    }

    @Test func bundledSourcesPinTheSameV2Hash() throws {
        let expectedHex = "28fc9b631091ae8bc2f8635d8930489238ce144174cbd15a03efb0530b301ebe"
        let parsed = StaticVotingConfig.bundledParsedSources

        #expect(StaticVotingConfig.bundledPinnedSources.count == 2)
        #expect(parsed.count == StaticVotingConfig.bundledPinnedSources.count)
        #expect(parsed.first?.url.host == "voting.valargroup.dev")
        #expect(parsed.last?.url.host == "raw.githubusercontent.com")
        for source in parsed {
            let digest = try #require(source.sha256)
            #expect(self.hexString(digest) == expectedHex)
            #expect(source.url.path.contains("v2-static-voting-config.json"))
        }
    }

    @Test func walkPropagatesCancellationWithoutTryingNextMirror() async throws {
        let bytes = Data(validConfigJSON.utf8)
        let sources = [
            try pinnedSource(host: "primary.example", for: bytes),
            try pinnedSource(host: "mirror.example", for: bytes)
        ]
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        await #expect(throws: CancellationError.self) {
            _ = try await StaticVotingConfig.loadFromNetworkWithFailover(sources: sources) { request in
                requestedHosts.withLock { $0.append(request.url!.host!) }
                throw CancellationError()
            }
        }
        #expect(requestedHosts.withLock { $0 } == ["primary.example"])
    }
}

@Suite struct DynamicConfigMirrorWalkTests {
    private let primary = URL(string: "https://voting.valargroup.dev/prod/dynamic-voting-config.json")!
    private let mirror = URL(string: "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/prod/dynamic-voting-config.json")!
    private let payload = Data("{\"config_version\": 1}".utf8)

    private func okResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func walkUsesFirstHealthyURLAndStampsTimeout() async throws {
        let requested = OSAllocatedUnfairLock(initialState: [URLRequest]())

        let (data, origin) = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, mirror]) { request in
            requested.withLock { $0.append(request) }
            return (self.payload, self.okResponse(request))
        }

        #expect(data == payload)
        #expect(origin == primary)
        let requests = requested.withLock { $0 }
        #expect(requests.map(\.url) == [primary])
        #expect(requests.first?.timeoutInterval == StaticVotingConfig.configRequestTimeout)
        #expect(requests.first?.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }

    @Test func walkFallsThroughOnTransportErrorAnd5xx() async throws {
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())
        let third = URL(string: "https://third.example/dynamic-voting-config.json")!

        let (_, origin) = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, third, mirror]) { request in
            let host = request.url!.host!
            requestedHosts.withLock { $0.append(host) }
            switch host {
            case "voting.valargroup.dev":
                throw URLError(URLError.Code.timedOut)
            case "third.example":
                return (Data(), self.okResponse(request, status: 503))
            default:
                return (self.payload, self.okResponse(request))
            }
        }

        #expect(origin == mirror)
        #expect(requestedHosts.withLock { $0 } == ["voting.valargroup.dev", "third.example", "raw.githubusercontent.com"])
    }

    @Test func walkTreatsPlain4xxAsAuthoritative() async throws {
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        let error = await #expect(throws: VotingConfigError.self) {
            _ = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, mirror]) { request in
                requestedHosts.withLock { $0.append(request.url!.host!) }
                return (Data(), self.okResponse(request, status: 404))
            }
        }

        #expect(requestedHosts.withLock { $0 } == ["voting.valargroup.dev"])
        guard case .dynamicConfigFetchFailed(let detail, let statusCode)? = error else {
            Issue.record("expected dynamicConfigFetchFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("404"))
        #expect(statusCode == 404)
    }

    @Test(arguments: [403, 407, 429, 451])
    func walkFallsThroughOnMiddleboxStatus(status: Int) async throws {
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        let (data, origin) = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, mirror]) { request in
            let host = request.url!.host!
            requestedHosts.withLock { $0.append(host) }
            if host == "voting.valargroup.dev" {
                return (Data(), self.okResponse(request, status: status))
            }
            return (self.payload, self.okResponse(request))
        }

        #expect(data == payload)
        #expect(origin == mirror)
        #expect(requestedHosts.withLock { $0 } == ["voting.valargroup.dev", "raw.githubusercontent.com"])
    }

    @Test func walkReportsFirstErrorWhenAllURLsFail() async throws {
        let error = await #expect(throws: VotingConfigError.self) {
            _ = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, mirror]) { request in
                if request.url!.host! == "voting.valargroup.dev" {
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
                return (Data(), self.okResponse(request, status: 500))
            }
        }

        guard case .dynamicConfigFetchFailed(let detail, let statusCode)? = error else {
            Issue.record("expected dynamicConfigFetchFailed, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("CDN fetch failed"))
        #expect(statusCode == nil)
    }

    @Test func walkRejectsEmptyURLList() async throws {
        await #expect(throws: VotingConfigError.self) {
            _ = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: []) { request in
                (self.payload, self.okResponse(request))
            }
        }
    }

    @Test func walkPropagatesCancelledURLErrorWithoutTryingNextMirror() async throws {
        let requestedHosts = OSAllocatedUnfairLock(initialState: [String]())

        await #expect(throws: URLError.self) {
            _ = try await VotingConfigMirrorWalk.fetchDynamicConfig(urls: [primary, mirror]) { request in
                requestedHosts.withLock { $0.append(request.url!.host!) }
                throw URLError(URLError.Code.cancelled)
            }
        }
        #expect(requestedHosts.withLock { $0 } == ["voting.valargroup.dev"])
    }

}
#endif
