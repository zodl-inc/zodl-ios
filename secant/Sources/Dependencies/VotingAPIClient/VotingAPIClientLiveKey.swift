import ComposableArchitecture
import Foundation
import os

private let logger = Logger(subsystem: "co.zodl.voting", category: "VotingAPIClient")

// MARK: - API Configuration

/// Mutable runtime configuration for the Shielded-Vote chain REST API and helper server.
/// URLs are resolved from the CDN service config at startup.
actor SvAPIConfigStore {
    static let shared = SvAPIConfigStore()

    private var voteServerURLs: [String] = []
    private var pirServerURLs: [String] = []
    private var staticConfig: StaticVotingConfig?
    private var serviceConfig: VotingServiceConfig?

    func configure(from config: VotingServiceConfig) {
        voteServerURLs = config.voteServers.map(\.url)
        pirServerURLs = config.pirEndpoints.map(\.url)
    }

    func setConfiguration(staticConfig: StaticVotingConfig, serviceConfig: VotingServiceConfig) {
        self.staticConfig = staticConfig
        self.serviceConfig = serviceConfig
    }

    func getConfiguration() -> (staticConfig: StaticVotingConfig, serviceConfig: VotingServiceConfig)? {
        guard let staticConfig, let serviceConfig else { return nil }
        return (staticConfig, serviceConfig)
    }

    func configuredVoteServerURLs() throws -> [String] {
        guard !voteServerURLs.isEmpty else {
            throw SvAPIError.invalidResponse("vote server URLs unavailable before dynamic config is loaded")
        }
        return voteServerURLs
    }

}

// MARK: - Errors

enum SvAPIError: LocalizedError {
    case httpError(statusCode: Int, message: String)
    case invalidResponse(String)
    case noActiveVotingSession
    case txFailed(code: UInt32, log: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .invalidResponse(let detail):
            return "Invalid API response: \(detail)"
        case .noActiveVotingSession:
            return "No active voting round"
        case .txFailed(let code, let log):
            return "Transaction failed (code \(code)): \(log)"
        }
    }
}

enum SvAPIResponseParser {
    static func parseJSONObject(
        _ data: Data,
        response: HTTPURLResponse,
        context: String
    ) throws -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return try unwrapJSONObject(object, data: data, response: response, context: context)
        } catch {
            throw SvAPIError.invalidResponse(
                "\(context): JSON parse failed (\(responseMetadata(response))) — \(bodySnippet(data))"
            )
        }
    }

    static func parseTxResult(_ json: [String: Any]) throws -> TxResult {
        for candidate in txResultCandidates(from: json) {
            let hasResultFields =
                candidate["tx_hash"] != nil ||
                candidate["txhash"] != nil ||
                candidate["hash"] != nil ||
                candidate["code"] != nil ||
                candidate["log"] != nil ||
                candidate["raw_log"] != nil ||
                candidate["error"] != nil
            guard hasResultFields else { continue }

            let txHash =
                (candidate["tx_hash"] as? String) ??
                (candidate["txhash"] as? String) ??
                (candidate["hash"] as? String) ??
                ""
            let code = parseUInt32(candidate["code"])
            let log =
                (candidate["log"] as? String) ??
                (candidate["raw_log"] as? String) ??
                (candidate["error"] as? String) ??
                ""

            if code != 0 {
                throw SvAPIError.txFailed(code: code, log: log)
            }
            return TxResult(txHash: txHash, code: code, log: log)
        }

        if let error = json["error"] as? String, !error.isEmpty {
            throw SvAPIError.invalidResponse("tx submission returned error: \(error)")
        }
        throw SvAPIError.invalidResponse("missing tx result fields")
    }

    private static func unwrapJSONObject(
        _ object: Any,
        data: Data,
        response: HTTPURLResponse,
        context: String
    ) throws -> [String: Any] {
        if let json = object as? [String: Any] {
            return json
        }

        // Some upstreams double-encode JSON objects as a top-level JSON string.
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let nestedData = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: nestedData) as? [String: Any] {
                logger.error("[VotingAPI] \(context) returned double-encoded JSON")
                return nested
            }
        }

        throw SvAPIError.invalidResponse(
            "\(context): expected JSON object, got \(describeJSONValue(object)) (\(responseMetadata(response))) — \(bodySnippet(data))"
        )
    }

    private static func txResultCandidates(from json: [String: Any]) -> [[String: Any]] {
        [
            json,
            json["tx_response"] as? [String: Any],
            json["result"] as? [String: Any]
        ].compactMap { $0 }
    }

    private static func describeJSONValue(_ value: Any) -> String {
        switch value {
        case is [Any]:
            return "array"
        case is String:
            return "string"
        case is NSNumber:
            return "number"
        case is NSNull:
            return "null"
        default:
            return String(describing: type(of: value))
        }
    }

    private static func responseMetadata(_ response: HTTPURLResponse) -> String {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown content type"
        return "HTTP \(response.statusCode), Content-Type: \(contentType)"
    }

    private static func bodySnippet(_ data: Data, limit: Int = 512) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let snippet = String(data: data.prefix(limit), encoding: .utf8) ?? "<non-utf8>"
        return snippet.replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - HTTP Helpers

/// URLSession configured with a long timeout to accommodate ZKP verification (30-60s).
private let httpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    return URLSession(configuration: config)
}()

/// Fast URLSession for share POSTs and health probes (5s timeout).
/// Share delivery should fail fast so we can failover to another server.
private let fastHttpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 10
    config.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: config)
}()

private func shouldTryNextVoteServer(after error: Error) -> Bool {
    if error is URLError { return true }
    if let error = error as? SvAPIError,
       case SvAPIError.httpError(let statusCode, _) = error {
        return statusCode >= 400
    }
    if let error = error as? SvAPIError,
       case SvAPIError.invalidResponse = error {
        return true
    }
    return false
}

private func getJSON(_ path: String) async throws -> [String: Any] {
    let serverURLs = try await SvAPIConfigStore.shared.configuredVoteServerURLs()
    var lastError: Error?

    for base in serverURLs {
        do {
            return try await getJSON(path, baseURL: base)
        } catch {
            lastError = error
            guard shouldTryNextVoteServer(after: error) else {
                throw error
            }
            logger.warning("GET \(path, privacy: .public) failed on \(base, privacy: .public); trying next vote server")
        }
    }

    throw lastError ?? SvAPIError.invalidResponse("no vote servers configured")
}

private func getJSON(_ path: String, baseURL base: String) async throws -> [String: Any] {
    guard let url = URL(string: "\(base)\(path)") else {
        throw SvAPIError.invalidResponse("invalid URL: \(base)\(path)")
    }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await httpSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw SvAPIError.invalidResponse("not an HTTP response")
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw SvAPIError.httpError(statusCode: http.statusCode, message: body)
    }
    return try SvAPIResponseParser.parseJSONObject(data, response: http, context: "GET \(path)")
}

private func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
    let serverURLs = try await SvAPIConfigStore.shared.configuredVoteServerURLs()
    var lastError: Error?

    for base in serverURLs {
        do {
            return try await postJSON(path, body: body, baseURL: base)
        } catch {
            lastError = error
            guard shouldTryNextVoteServer(after: error) else {
                throw error
            }
            logger.warning("POST \(path, privacy: .public) failed on \(base, privacy: .public); trying next vote server")
        }
    }

    throw lastError ?? SvAPIError.invalidResponse("no vote servers configured")
}

private func postJSON(_ path: String, body: [String: Any], baseURL base: String) async throws -> [String: Any] {
    guard let url = URL(string: "\(base)\(path)") else {
        throw SvAPIError.invalidResponse("invalid URL: \(base)\(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await httpSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw SvAPIError.invalidResponse("not an HTTP response")
    }
    guard http.statusCode == 200 else {
        // 422 = chain processed the request but rejected the TX (non-zero CheckTx code).
        // Parse the structured body for code/log instead of returning a raw HTTP error.
        if http.statusCode == 422,
           let json = try? SvAPIResponseParser.parseJSONObject(data, response: http, context: "POST \(path)") {
            let code = (json["code"] as? NSNumber)?.uint32Value ?? 0
            let log = json["log"] as? String ?? ""
            if code != 0 {
                throw SvAPIError.txFailed(code: code, log: log)
            }
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw SvAPIError.httpError(statusCode: http.statusCode, message: body)
    }
    return try SvAPIResponseParser.parseJSONObject(data, response: http, context: "POST \(path)")
}

/// POST JSON to a specific vote server URL. Returns parsed JSON response.
private func postServerJSON(_ serverURL: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: "\(serverURL)\(path)") else {
        throw SvAPIError.invalidResponse("invalid URL: \(serverURL)\(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await fastHttpSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw SvAPIError.invalidResponse("not an HTTP response")
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw SvAPIError.httpError(statusCode: http.statusCode, message: body)
    }
    return try SvAPIResponseParser.parseJSONObject(data, response: http, context: "POST \(path)")
}

typealias SharePost = @Sendable (_ serverURL: String, _ body: [String: Any]) async throws -> Void
typealias ShareTargetSelector = @Sendable (_ serverURLs: [String], _ targetCount: Int) -> [String]

func sharePostBody(
    for payload: SharePayload,
    roundIdHex: String,
    submitAt: UInt64? = nil
) -> [String: Any] {
    [
        "shares_hash": payload.sharesHash.base64EncodedString(),
        "proposal_id": payload.proposalId,
        "vote_decision": payload.voteDecision,
        "enc_share": [
            "c1": payload.encShare.c1.base64EncodedString(),
            "c2": payload.encShare.c2.base64EncodedString(),
            "share_index": payload.encShare.shareIndex
        ],
        "share_index": payload.encShare.shareIndex,
        "tree_position": payload.treePosition,
        "vote_round_id": roundIdHex,
        "all_enc_shares": payload.allEncShares.map { share -> [String: Any] in
            [
                "c1": share.c1.base64EncodedString(),
                "c2": share.c2.base64EncodedString(),
                "share_index": share.shareIndex
            ]
        },
        "share_comms": payload.shareComms.map { $0.base64EncodedString() },
        "primary_blind": payload.primaryBlind.base64EncodedString(),
        "submit_at": submitAt ?? payload.submitAt
    ]
}

func delegateSharePayloads(
    _ payloads: [SharePayload],
    roundIdHex: String,
    initialServerURLs: [String],
    postShare: @escaping SharePost,
    selectTargets: @escaping ShareTargetSelector = { Array($0.shuffled().prefix($1)) }
) async throws -> ShareDelegationResult {
    var availableServers = initialServerURLs
    var lastError: Error?
    var results: [DelegatedShareInfo] = []

    for (shareOffset, payload) in payloads.enumerated() {
        let body = sharePostBody(for: payload, roundIdHex: roundIdHex)

        let targetCount = max(1, (availableServers.count + 1) / 2)
        var acceptedServers: [String] = []
        var triedServers = Set<String>()

        while acceptedServers.count < targetCount {
            let candidates = availableServers.filter { !triedServers.contains($0) }
            guard !candidates.isEmpty else { break }

            let needed = max(1, targetCount - acceptedServers.count)
            let targets = selectTargets(candidates, needed).filter { candidates.contains($0) }
            guard !targets.isEmpty else { break }

            triedServers.formUnion(targets)
            var failedServers = Set<String>()

            await withTaskGroup(of: (String, Bool).self) { group in
                for server in targets {
                    group.addTask {
                        do {
                            try await postShare(server, body)
                            return (server, true)
                        } catch {
                            return (server, false)
                        }
                    }
                }

                for await (server, ok) in group {
                    if ok {
                        acceptedServers.append(server)
                    } else {
                        logger.warning("Share \(shareOffset) failed on \(server, privacy: .public)")
                        failedServers.insert(server)
                    }
                }
            }

            if !failedServers.isEmpty {
                availableServers.removeAll { failedServers.contains($0) }
            }
        }

        if acceptedServers.isEmpty {
            logger.warning("Share \(shareOffset) failed on all configured vote servers")
            lastError = ShareDelegationError.noReachableVoteServers
            break
        }

        results.append(DelegatedShareInfo(
            shareIndex: payload.encShare.shareIndex,
            proposalId: payload.proposalId,
            acceptedByServers: acceptedServers
        ))
    }

    if let lastError {
        throw lastError
    }

    return ShareDelegationResult(
        delegatedShares: results,
        remainingServerURLs: availableServers
    )
}

func resubmitSharePayload(
    _ payload: SharePayload,
    roundIdHex: String,
    configuredServerURLs: [String],
    sentToURLs: [String],
    postShare: @escaping SharePost,
    orderServers: @escaping @Sendable ([String]) -> [String] = { $0.shuffled() }
) async -> [String] {
    let sentSet = Set(sentToURLs)
    let untried = orderServers(configuredServerURLs.filter { !sentSet.contains($0) })
    let alreadySent = orderServers(configuredServerURLs.filter { sentSet.contains($0) })
    let body = sharePostBody(for: payload, roundIdHex: roundIdHex, submitAt: 0)

    for server in untried + alreadySent {
        do {
            try await postShare(server, body)
            return [server]
        } catch {
            logger.warning(
                "Share resubmission failed on \(server, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    return []
}

/// Parse a broadcast TX response into TxResult. Throws on non-zero code.
private func parseTxResult(_ json: [String: Any]) throws -> TxResult {
    try SvAPIResponseParser.parseTxResult(json)
}

// MARK: - Broadcast Retry

/// Whether a broadcast error is transient and worth retrying.
/// Network failures and 502/503 (CometBFT gateway errors) are retryable.
/// Deterministic failures like 422 (CheckTx rejection) and 400 (bad request) are not.
private func isBroadcastRetryable(_ error: Error) -> Bool {
    if error is URLError { return true }
    if case SvAPIError.httpError(let status, _) = error {
        return status == 502 || status == 503
    }
    return false
}

/// Retry an async operation with exponential backoff.
/// Only retries when `isRetryable` returns true for the thrown error.
private func retryWithBackoff<T>(
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 2,
    factor: Double = 2,
    isRetryable: (Error) -> Bool,
    operation: () async throws -> T
) async throws -> T {
    var delay = initialDelay
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            let isLast = attempt == maxAttempts
            if isLast || !isRetryable(error) { throw error }
            logger.warning(
                """
                Broadcast attempt \(attempt)/\(maxAttempts) failed \
                (\(error.localizedDescription, privacy: .public)); retrying in \(delay)s
                """
            )
            try await Task.sleep(for: .seconds(delay))
            delay *= factor
        }
    }
    fatalError("unreachable")
}

// MARK: - Protobuf JSON Parsing Helpers

/// Parse a uint64 value that may come as a string (protobuf JSON) or number.
private func parseUInt64(_ value: Any?) -> UInt64 {
    if let str = value as? String, let n = UInt64(str) { return n }
    if let num = value as? NSNumber { return num.uint64Value }
    return 0
}

/// Parse a uint32 value from JSON (number or string).
private func parseUInt32(_ value: Any?) -> UInt32 {
    if let str = value as? String, let n = UInt32(str) { return n }
    if let num = value as? NSNumber { return num.uint32Value }
    return 0
}

/// Decode base64-encoded bytes, returning empty Data on failure.
private func parseBase64(_ value: Any?) -> Data {
    guard let str = value as? String, let data = Data(base64Encoded: str) else { return Data() }
    return data
}

/// Convert hex string to Data.
private func dataFromHex(_ hex: String) -> Data {
    var data = Data()
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let byte = UInt8(hex[idx..<next], radix: 16) {
            data.append(byte)
        }
        idx = next
    }
    return data
}

private func hexString(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Response Parsers

private func validateProposals(_ proposals: [VotingProposal]) throws {
    guard (1...15).contains(proposals.count) else {
        throw SvAPIError.invalidResponse("proposals must contain between 1 and 15 entries")
    }

    var proposalIds = Set<UInt32>()
    for proposal in proposals {
        guard (1...15).contains(proposal.id) else {
            throw SvAPIError.invalidResponse("proposal id must be in the range 1 to 15")
        }
        guard proposalIds.insert(proposal.id).inserted else {
            throw SvAPIError.invalidResponse("proposal ids must be unique")
        }
        guard (2...8).contains(proposal.options.count) else {
            throw SvAPIError.invalidResponse("proposal options must contain between 2 and 8 entries")
        }

        let optionIndices = proposal.options.map(\.index)
        guard Set(optionIndices).count == optionIndices.count else {
            throw SvAPIError.invalidResponse("option index values within a proposal must be unique")
        }
        let expectedIndices = Array(UInt32(0)..<UInt32(proposal.options.count))
        guard optionIndices.sorted() == expectedIndices else {
            throw SvAPIError.invalidResponse("option index values within a proposal must be 0-indexed contiguous")
        }
    }
}

/// Parse a VotingSession from the "round" JSON object returned by GET /shielded-vote/v1/round/{id}.
func parseVotingSession(from round: [String: Any]) throws -> VotingSession {
    let voteEndTimeUnix = parseUInt64(round["vote_end_time"])
    let voteEndTime = Date(timeIntervalSince1970: TimeInterval(voteEndTimeUnix))
    let ceremonyStartUnix = parseUInt64(round["ceremony_phase_start"])
    let ceremonyStart = Date(timeIntervalSince1970: TimeInterval(ceremonyStartUnix))
    let statusRaw = parseUInt32(round["status"])

    // Proposal metadata is authoritative chain state. The CDN config only
    // provides endpoint discovery, so malformed proposal arrays should fail the
    // round query instead of rendering empty fallback ballots.
    guard let proposalsJSON = round["proposals"] as? [[String: Any]] else {
        throw SvAPIError.invalidResponse("missing proposals in round")
    }
    let proposals: [VotingProposal] = try proposalsJSON.map { p in
        guard let optionsJSON = p["options"] as? [[String: Any]] else {
            throw SvAPIError.invalidResponse("missing options in proposal")
        }
        let options = optionsJSON.map { o in
            VoteOption(
                index: parseUInt32(o["index"]),
                label: o["label"] as? String ?? "Option \(parseUInt32(o["index"]))"
            )
        }
        let forumURLString = p["forum_url"] as? String
        return VotingProposal(
            id: parseUInt32(p["id"]),
            title: p["title"] as? String ?? "",
            description: p["description"] as? String ?? "",
            options: options,
            zipNumber: (p["zip_number"] ?? p["zipNumber"] ?? p["zip"]) as? String,
            forumURL: forumURLString.flatMap { URL(string: $0) }
        )
    }
    try validateProposals(proposals)

    let discussionURLString = round["discussion_url"] as? String
    return VotingSession(
        voteRoundId: parseBase64(round["vote_round_id"]),
        snapshotHeight: parseUInt64(round["snapshot_height"]),
        snapshotBlockhash: parseBase64(round["snapshot_blockhash"]),
        proposalsHash: parseBase64(round["proposals_hash"]),
        voteEndTime: voteEndTime,
        ceremonyStart: ceremonyStart,
        eaPK: parseBase64(round["ea_pk"]),
        vkZkp1: parseBase64(round["vk_zkp1"]),
        vkZkp2: parseBase64(round["vk_zkp2"]),
        vkZkp3: parseBase64(round["vk_zkp3"]),
        ncRoot: parseBase64(round["nc_root"]),
        nullifierIMTRoot: parseBase64(round["nullifier_imt_root"]),
        creator: round["creator"] as? String ?? "",
        description: round["description"] as? String ?? "",
        discussionURL: discussionURLString.flatMap { URL(string: $0) },
        proposals: proposals,
        status: SessionStatus(rawValue: statusRaw) ?? .unspecified,
        createdAtHeight: parseUInt64(round["created_at_height"]),
        title: round["title"] as? String ?? ""
    )
}

/// Authenticate a chain-sourced round before the wallet treats it as usable.
///
/// Vote servers are endpoint-discovery targets from the dynamic config, not
/// trust anchors. The wallet trusts the bundled static config's admin keys,
/// verifies the dynamic config's signed `ea_pk` for this round id, then checks
/// that the chain response is bound to the same `ea_pk`.
private func authenticateVotingSession(_ session: VotingSession) async throws -> VotingSession {
    guard let configuration = await SvAPIConfigStore.shared.getConfiguration() else {
        logger.error("Round auth failed: trust material unavailable")
        throw SvAPIError.noActiveVotingSession
    }

    let roundIdHex = hexString(from: session.voteRoundId)
    let status = RoundAuthenticator.authenticate(
        chainEaPK: session.eaPK,
        roundIdHex: roundIdHex,
        rounds: configuration.serviceConfig.rounds,
        trustedKeys: configuration.staticConfig.trustedKeys
    )
    guard status == .authenticated else {
        logger.error(
            "Round auth failed: status=\(String(describing: status), privacy: .public) round=\(roundIdHex, privacy: .public)"
        )
        // Per current UX, unauthenticated rounds are hidden behind the same
        // surface as "no active round" rather than shown as a separate warning.
        throw SvAPIError.noActiveVotingSession
    }
    return session
}

private func authenticatedVotingSessions(from rounds: [[String: Any]]) async throws -> [VotingSession] {
    var authenticated: [VotingSession] = []
    for round in rounds {
        let session = try parseVotingSession(from: round)
        do {
            authenticated.append(try await authenticateVotingSession(session))
        } catch SvAPIError.noActiveVotingSession {
            logger.error("Skipping unauthenticated round \(hexString(from: session.voteRoundId), privacy: .public)")
        }
    }
    return authenticated
}

/// Return a copy containing only round entries with at least one trusted signature.
///
/// Round authentication is intentionally per-round: one broken historical
/// signature must hide only that round, while still allowing other active
/// or finalized rounds to render.
func serviceConfigRetainingRoundsWithValidSignatures(
    _ config: VotingServiceConfig,
    trustedKeys: [StaticVotingConfig.TrustedKey]
) -> VotingServiceConfig {
    let authenticatedRounds = config.rounds.filter { _, entry in
        RoundAuthenticator.verifyEntrySignatures(entry: entry, trustedKeys: trustedKeys)
    }
    return VotingServiceConfig(
        configVersion: config.configVersion,
        voteServers: config.voteServers,
        pirEndpoints: config.pirEndpoints,
        supportedVersions: config.supportedVersions,
        rounds: authenticatedRounds
    )
}

// MARK: - Live Implementation

extension VotingAPIClient: DependencyKey {
    static var liveValue: Self {
        Self(
            fetchServiceConfig: { override in
                let source: PinnedConfigSource
                if let override {
                    source = override
                } else {
                    source = try PinnedConfigSource.parse(StaticVotingConfig.bundledPinnedSource)
                }
                let staticConfig = try await StaticVotingConfig.loadFromNetwork(
                    source: source,
                    session: httpSession
                )

                // Fetch and decode the CDN config. Any failure (transport, HTTP, decode,
                // or version-validation) surfaces as a VotingConfigError — no silent fallback.
                let configURL = staticConfig.dynamicConfigURL
                let data: Data
                let response: URLResponse
                do {
                    // Always re-fetch the config from the network instead of trusting
                    // a persisted URLCache entry. GitHub Pages serves a short TTL, but
                    // mobile restarts during a round rollover can otherwise keep an old
                    // round binding alive long enough to brick voting on launch.
                    var request = URLRequest(
                        url: configURL,
                        cachePolicy: .reloadIgnoringLocalCacheData
                    )
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                    (data, response) = try await httpSession.data(for: request)
                } catch {
                    throw VotingConfigError.decodeFailed("CDN fetch failed: \(error.localizedDescription)")
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw VotingConfigError.decodeFailed("CDN returned HTTP \(http.statusCode)")
                }
                let config: VotingServiceConfig
                do {
                    config = try JSONDecoder().decode(VotingServiceConfig.self, from: data)
                } catch {
                    throw VotingConfigError.decodeFailed("CDN decode failed: \(error.localizedDescription)")
                }
                try config.validate()
                let authenticatedConfig = serviceConfigRetainingRoundsWithValidSignatures(
                    config,
                    trustedKeys: staticConfig.trustedKeys
                )
                let droppedRounds = config.rounds.count - authenticatedConfig.rounds.count
                await SvAPIConfigStore.shared.setConfiguration(
                    staticConfig: staticConfig,
                    serviceConfig: authenticatedConfig
                )
                logger.info(
                    """
                    Loaded config from CDN: \(authenticatedConfig.voteServers.count) vote servers, \
                    \(authenticatedConfig.rounds.count) authenticated rounds, \(droppedRounds) dropped rounds
                    """
                )
                return authenticatedConfig
            },
            configureURLs: { config in
                await SvAPIConfigStore.shared.configure(from: config)
                await ServerHealthTracker.shared.initialize(
                    serverURLs: config.voteServers.map(\.url)
                )
                let base = config.voteServers.first?.url
                let pir = config.pirEndpoints.first?.url
                logger.info(
                    """
                    URLs configured: base=\(base ?? "<none>", privacy: .public), \
                    voteServers=\(config.voteServers.count), pir=\(pir ?? "<none>", privacy: .public), \
                    pirEndpoints=\(config.pirEndpoints.count)
                    """
                )
            },
            fetchActiveVotingSession: {
                let json: [String: Any]
                do {
                    json = try await getJSON("/shielded-vote/v1/rounds/active")
                } catch SvAPIError.httpError(let statusCode, _) where statusCode == 404 {
                    throw SvAPIError.noActiveVotingSession
                }
                if json["round"] == nil || json["round"] is NSNull {
                    throw SvAPIError.noActiveVotingSession
                }
                guard let round = json["round"] as? [String: Any] else {
                    throw SvAPIError.invalidResponse("missing 'round' in response")
                }
                return try await authenticateVotingSession(try parseVotingSession(from: round))
            },
            fetchAllRounds: {
                let json = try await getJSON("/shielded-vote/v1/rounds")
                guard let roundsArray = json["rounds"] as? [[String: Any]] else {
                    // No rounds — return empty
                    return []
                }
                return try await authenticatedVotingSessions(from: roundsArray)
            },
            fetchRoundById: { roundIdHex in
                let json = try await getJSON("/shielded-vote/v1/round/\(roundIdHex)")
                guard let round = json["round"] as? [String: Any] else {
                    throw SvAPIError.invalidResponse("missing 'round' in response")
                }
                return try await authenticateVotingSession(try parseVotingSession(from: round))
            },
            fetchTallyResults: { roundIdHex in
                let json = try await getJSON("/shielded-vote/v1/tally-results/\(roundIdHex)")
                guard let results = json["results"] as? [[String: Any]] else {
                    return [:]
                }
                // Group by proposal_id
                var grouped: [UInt32: [TallyResult.Entry]] = [:]
                for entry in results {
                    let proposalId = parseUInt32(entry["proposal_id"])
                    let tallyEntry = TallyResult.Entry(
                        decision: parseUInt32(entry["vote_decision"]),
                        amount: parseUInt64(entry["total_value"])
                    )
                    grouped[proposalId, default: []].append(tallyEntry)
                }
                return grouped.mapValues { TallyResult(entries: $0) }
            },
            fetchZodlEndorsedRoundIds: {
                do {
                    let json = try await getJSON("/shielded-vote/v1/endorsed-rounds/zodl")
                    guard let ids = json["vote_round_ids"] as? [String] else {
                        return []
                    }
                    // Chain returns base64-encoded 32-byte round ids; the app
                    // keys rounds by lowercase hex.
                    return Set(ids.compactMap { encoded in
                        Data(base64Encoded: encoded).map(hexString(from:))
                    })
                } catch SvAPIError.httpError(let statusCode, _) where statusCode == 400 || statusCode == 404 {
                    // Endorser not configured on this chain. Treat as no endorsements.
                    return []
                }
            },
            submitDelegation: { registration in
                let body: [String: Any] = [
                    "rk": registration.rk.base64EncodedString(),
                    "spend_auth_sig": registration.spendAuthSig.base64EncodedString(),
                    "sighash": registration.sighash.base64EncodedString(),
                    "signed_note_nullifier": registration.signedNoteNullifier.base64EncodedString(),
                    "cmx_new": registration.cmxNew.base64EncodedString(),
                    "van_cmx": registration.vanCmx.base64EncodedString(),
                    "gov_nullifiers": registration.govNullifiers.map { $0.base64EncodedString() },
                    "proof": registration.proof.base64EncodedString(),
                    "vote_round_id": registration.voteRoundId.base64EncodedString()
                ]
                return try await retryWithBackoff(isRetryable: isBroadcastRetryable) {
                    let json = try await postJSON("/shielded-vote/v1/delegate-vote", body: body)
                    return try parseTxResult(json)
                }
            },
            submitVoteCommitment: { bundle, signature in
                // voteRoundId is a hex string; chain expects base64-encoded bytes
                let roundIdBytes = dataFromHex(bundle.voteRoundId)
                let body: [String: Any] = [
                    "van_nullifier": bundle.vanNullifier.base64EncodedString(),
                    "vote_authority_note_new": bundle.voteAuthorityNoteNew.base64EncodedString(),
                    "vote_commitment": bundle.voteCommitment.base64EncodedString(),
                    "proposal_id": bundle.proposalId,
                    "proof": bundle.proof.base64EncodedString(),
                    "vote_round_id": roundIdBytes.base64EncodedString(),
                    "vote_comm_tree_anchor_height": bundle.anchorHeight,
                    "r_vpk": bundle.rVpkBytes.base64EncodedString(),
                    "vote_auth_sig": signature.voteAuthSig.base64EncodedString()
                ]
                return try await retryWithBackoff(isRetryable: isBroadcastRetryable) {
                    let json = try await postJSON("/shielded-vote/v1/cast-vote", body: body)
                    return try parseTxResult(json)
                }
            },
            delegateShares: { payloads, roundIdHex, serverURLs in
                // Active foreground delivery uses the submission-local server set.
                // POST failures prune that local set immediately; cached helper
                // health and /status probes are intentionally not consulted here.
                // Successful/failed foreground POSTs still update the tracker for
                // later background recovery decisions.
                let tracker = ServerHealthTracker.shared
                return try await delegateSharePayloads(
                    payloads,
                    roundIdHex: roundIdHex,
                    initialServerURLs: serverURLs,
                    postShare: { server, body in
                        do {
                            _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                            await tracker.recordSuccess(for: server)
                        } catch {
                            await tracker.recordFailure(for: server)
                            throw error
                        }
                    }
                )
            },
            fetchShareStatus: { helperBaseURL, roundIdHex, nullifierHex in
                let path = "/shielded-vote/v1/share-status/\(roundIdHex)/\(nullifierHex)"
                guard let url = URL(string: "\(helperBaseURL)\(path)") else {
                    throw SvAPIError.invalidResponse("invalid URL: \(helperBaseURL)\(path)")
                }
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                // Use the same X-Helper-Token header as share submission
                request.setValue("voting-helper", forHTTPHeaderField: "X-Helper-Token")

                let (data, response) = try await fastHttpSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SvAPIError.invalidResponse("not an HTTP response")
                }
                guard http.statusCode == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw SvAPIError.httpError(statusCode: http.statusCode, message: body)
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? String
                else {
                    throw SvAPIError.invalidResponse("expected JSON with 'status' field")
                }
                switch status {
                case "confirmed":
                    return .confirmed
                default:
                    return .pending
                }
            },
            resubmitShare: { payload, roundIdHex, excludeURLs in
                let configuredServerURLs = try await SvAPIConfigStore.shared.configuredVoteServerURLs()
                let tracker = ServerHealthTracker.shared
                return await resubmitSharePayload(
                    payload,
                    roundIdHex: roundIdHex,
                    configuredServerURLs: configuredServerURLs,
                    sentToURLs: excludeURLs,
                    postShare: { server, body in
                        do {
                            _ = try await postServerJSON(server, "/shielded-vote/v1/shares", body: body)
                            await tracker.recordSuccess(for: server)
                        } catch {
                            await tracker.recordFailure(for: server)
                            throw error
                        }
                    }
                )
            },
            fetchProposalTally: { roundId, proposalId in
                let roundIdHex = roundId.map { String(format: "%02x", $0) }.joined()
                let json = try await getJSON("/shielded-vote/v1/tally-results/\(roundIdHex)")
                guard let results = json["results"] as? [[String: Any]] else {
                    // No results yet — return empty tally
                    return TallyResult(entries: [])
                }
                let entries = results
                    .filter { parseUInt32($0["proposal_id"]) == proposalId }
                    .map { entry in
                        TallyResult.Entry(
                            decision: parseUInt32(entry["vote_decision"]),
                            amount: parseUInt64(entry["total_value"])
                        )
                    }
                return TallyResult(entries: entries)
            },
            fetchTxConfirmation: { txHash in
                let serverURLs: [String]
                do {
                    serverURLs = try await SvAPIConfigStore.shared.configuredVoteServerURLs()
                } catch {
                    logger.error("fetchTxConfirmation: vote server URLs unavailable: \(error.localizedDescription, privacy: .public)")
                    return nil
                }

                for base in serverURLs {
                    let urlString = "\(base)/shielded-vote/v1/tx/\(txHash)"
                    guard let url = URL(string: urlString) else {
                        logger.error("fetchTxConfirmation: invalid URL: \(urlString)")
                        continue
                    }

                    let data: Data
                    let response: URLResponse
                    do {
                        (data, response) = try await httpSession.data(from: url)
                    } catch {
                        logger.debug(
                            "fetchTxConfirmation: network error on \(base, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        continue
                    }

                    guard let http = response as? HTTPURLResponse else {
                        logger.error("fetchTxConfirmation: not an HTTP response from \(base, privacy: .public)")
                        continue
                    }

                    // 404 = TX not yet in a block (normal during polling).
                    // Try the remaining configured servers before reporting pending.
                    if http.statusCode == 404 {
                        logger.debug("fetchTxConfirmation: 404 (not yet in block) on \(base, privacy: .public) for \(txHash)")
                        continue
                    }

                    // 422 = TX included but execution failed (non-zero code).
                    // Parse the response to extract the error code/log.
                    guard http.statusCode == 200 || http.statusCode == 422 else {
                        let body = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8>"
                        logger.debug(
                            "fetchTxConfirmation: HTTP \(http.statusCode) on \(base, privacy: .public) for \(txHash) — \(body, privacy: .public)"
                        )
                        continue
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        let snippet = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8>"
                        logger.error("fetchTxConfirmation: JSON parse failed on \(base, privacy: .public) — \(snippet, privacy: .public)")
                        continue
                    }

                    let height = parseUInt64(json["height"])
                    let code = parseUInt32(json["code"])
                    let log = json["log"] as? String ?? ""

                    var parsedEvents: [TxEvent] = []
                    if let events = json["events"] as? [[String: Any]] {
                        for event in events {
                            guard let evType = event["type"] as? String,
                                  let attrs = event["attributes"] as? [[String: Any]]
                            else { continue }
                            let parsed = attrs.compactMap { attr -> TxEventAttribute? in
                                guard let key = attr["key"] as? String,
                                      let value = attr["value"] as? String
                                else { return nil }
                                return TxEventAttribute(key: key, value: value)
                            }
                            parsedEvents.append(TxEvent(type: evType, attributes: parsed))
                        }
                    }

                    let eventSummary = parsedEvents.map { ev in
                        let keys = ev.attributes.map(\.key).joined(separator: ",")
                        return "\(ev.type)[\(keys)]"
                    }.joined(separator: "; ")
                    logger.debug("fetchTxConfirmation: height=\(height) code=\(code) events=\(eventSummary)")

                    return TxConfirmation(height: height, code: code, log: log, events: parsedEvents)
                }

                return nil
            }
        )
    }
}
