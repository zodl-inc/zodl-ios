#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import os
@preconcurrency import ZcashLightClientKit

// MARK: - API Configuration

/// Mutable runtime configuration for the Shielded-Vote chain REST API and helper server.
/// URLs are resolved from the CDN service config at startup.
actor SvAPIConfigStore {
    struct State: Equatable, Sendable {
        var voteServerURLs: [String] = []
        var pirServerURLs: [String] = []
        var staticConfig: StaticVotingConfig?
        var serviceConfig: VotingServiceConfig?
    }

    static let shared = SvAPIConfigStore()

    private var state = State()

    func configure(from config: VotingServiceConfig) {
        var updatedState = state
        updatedState.voteServerURLs = config.voteServers.map(\.url)
        updatedState.pirServerURLs = config.pirEndpoints.map(\.url)
        replaceState(with: updatedState)
    }

    func setConfiguration(staticConfig: StaticVotingConfig, serviceConfig: VotingServiceConfig) {
        var updatedState = state
        updatedState.staticConfig = staticConfig
        updatedState.serviceConfig = serviceConfig
        replaceState(with: updatedState)
    }

    func getConfiguration() -> (staticConfig: StaticVotingConfig, serviceConfig: VotingServiceConfig)? {
        guard let staticConfig = state.staticConfig,
              let serviceConfig = state.serviceConfig
        else {
            return nil
        }
        return (staticConfig, serviceConfig)
    }

    func currentState() -> State {
        state
    }

    func replaceState(with state: State) {
        self.state = state
    }

    func configuredVoteServerURLs() throws -> [String] {
        guard !state.voteServerURLs.isEmpty else {
            throw SvAPIError.invalidResponse("vote server URLs unavailable before dynamic config is loaded")
        }
        return state.voteServerURLs
    }
}

// MARK: - Errors

enum SvAPIError: LocalizedError {
    case httpError(statusCode: Int, message: String)
    case invalidResponse(String)
    case noActiveVotingSession

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .invalidResponse(let detail):
            return "Invalid API response: \(detail)"
        case .noActiveVotingSession:
            return "No active voting round"
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
                LoggerProxy.error("[VotingAPI] \(context) returned double-encoded JSON")
                return nested
            }
        }

        throw SvAPIError.invalidResponse(
            "\(context): expected JSON object, got \(describeJSONValue(object)) (\(responseMetadata(response))) — \(bodySnippet(data))"
        )
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

/// The short-timeout URLSession the `fast` flag picks on the direct transport: 5 s per
/// request, 10 s per resource, two connections per host. Nothing in this client asks for
/// `fast` any more — the callers that wanted to fail over quickly went with the app-side
/// submission path — so today it is reached only through `routeVotingRequest`'s `fast`
/// parameter, which the transport tests still exercise.
private let fastHttpSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 10
    config.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: config)
}()

/// Routes a request through Tor when the user enabled it in Settings
/// (`swapAPIAccess == .protected`), otherwise through the standard or fast
/// URLSession. Returning `URLResponse` keeps every call site uniform.
///
/// The "fast" policy is this 5 s request timeout, and it applies on the
/// non-Tor transports only. A per-request
/// `URLRequest.timeoutInterval` takes precedence over the session
/// configuration's `timeoutIntervalForRequest` (measured: a request-level
/// 3 s fails at 3.0 s on a session configured for 120 s). The Tor path is
/// different: `TorClient.httpRequest` hands the URL, headers, and body to
/// the Rust FFI and ignores `timeoutInterval` entirely. Poll loading uses the
/// SDK's bounded transport below; all other Tor requests retain the existing
/// `httpRequestOverTor` retry policy.
private let fastRequestTimeout: TimeInterval = 5

typealias VotingDirectRequest = @Sendable (_ request: URLRequest, _ fast: Bool) async throws -> (Data, URLResponse)

struct VotingPollLoadingBudget: Sendable {
    private let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
        deadline = now().advanced(by: .seconds(60))
    }

    func requestTimeoutMilliseconds() throws -> UInt64 {
        try Task.checkCancellation()
        let remaining = now().duration(to: deadline)
        let bounded = min(Duration.seconds(15), remaining)
        guard bounded >= .milliseconds(1) else {
            throw URLError(URLError.Code.timedOut)
        }
        let components = bounded.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return UInt64(milliseconds)
    }
}

@Sendable
func routePollLoadingRequest(
    _ request: URLRequest,
    budget: VotingPollLoadingBudget,
    access: WalletStorage.SwapAPIAccess,
    sdkSynchronizer: SDKSynchronizerClient,
    directRequest: @escaping VotingDirectRequest
) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    if access == .protected {
        let timeout = try budget.requestTimeoutMilliseconds()
        let result: (Data, HTTPURLResponse)
        do {
            result = try await sdkSynchronizer.boundedTorGET(request, timeout)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return result
    }
    return try await directRequest(request, false)
}

@Sendable
func routeVotingRequest(
    _ request: URLRequest,
    fast: Bool,
    access: WalletStorage.SwapAPIAccess,
    sdkSynchronizer: SDKSynchronizerClient,
    directRequest: @escaping VotingDirectRequest
) async throws -> (Data, URLResponse) {
    var request = request
    if fast {
        request.timeoutInterval = fastRequestTimeout
    }

    if access == .protected {
        let (data, response) = try await sdkSynchronizer.httpRequestOverTor(request)
        return (data, response as URLResponse)
    }
    return try await directRequest(request, fast)
}

@Sendable
private func performVotingRequest(
    _ request: URLRequest,
    fast: Bool = false
) async throws -> (Data, URLResponse) {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

    return try await routeVotingRequest(
        request,
        fast: fast,
        access: swapAPIAccess,
        sdkSynchronizer: sdkSynchronizer,
        directRequest: { request, fast in
            let session = fast ? fastHttpSession : httpSession
            return try await session.data(for: request)
        }
    )
}

@Sendable
private func performPollLoadingRequest(
    _ request: URLRequest,
    budget: VotingPollLoadingBudget
) async throws -> (Data, URLResponse) {
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct

    return try await routePollLoadingRequest(
        request,
        budget: budget,
        access: swapAPIAccess,
        sdkSynchronizer: sdkSynchronizer,
        directRequest: { request, _ in
            try await httpSession.data(for: request)
        }
    )
}

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

private func shouldTryNextPollLoadingVoteServer(after error: Error) -> Bool {
    if shouldTryNextVoteServer(after: error) { return true }
    if case ZcashError.rustTorHttpRequest = error { return true }
    return false
}

private func getJSON(
    _ path: String,
    pollLoadingBudget: VotingPollLoadingBudget? = nil
) async throws -> [String: Any] {
    let serverURLs = try await SvAPIConfigStore.shared.configuredVoteServerURLs()
    var lastError: Error?

    for base in serverURLs {
        do {
            return try await getJSON(path, baseURL: base, pollLoadingBudget: pollLoadingBudget)
        } catch {
            if pollLoadingBudget != nil {
                try Task.checkCancellation()
            }
            lastError = error
            let shouldTryNext = if pollLoadingBudget == nil {
                shouldTryNextVoteServer(after: error)
            } else {
                shouldTryNextPollLoadingVoteServer(after: error)
            }
            guard shouldTryNext else {
                throw error
            }
            LoggerProxy.warn("GET \(path) failed on \(base); trying next vote server")
        }
    }

    throw lastError ?? SvAPIError.invalidResponse("no vote servers configured")
}

private func getJSON(
    _ path: String,
    baseURL base: String,
    pollLoadingBudget: VotingPollLoadingBudget? = nil
) async throws -> [String: Any] {
    guard let url = URL(string: "\(base)\(path)") else {
        throw SvAPIError.invalidResponse("invalid URL: \(base)\(path)")
    }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response): (Data, URLResponse)
    if let pollLoadingBudget {
        (data, response) = try await performPollLoadingRequest(request, budget: pollLoadingBudget)
    } else {
        (data, response) = try await performVotingRequest(request)
    }
    guard let http = response as? HTTPURLResponse else {
        throw SvAPIError.invalidResponse("not an HTTP response")
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw SvAPIError.httpError(statusCode: http.statusCode, message: body)
    }
    return try SvAPIResponseParser.parseJSONObject(data, response: http, context: "GET \(path)")
}

/// Strictly decodes a hex string to `Data`: the input must have even length and every
/// 2-character pair must be a valid hex byte, or this returns `nil`. A lenient decoder
/// that silently drops any pair it cannot parse — the exact pattern behind campaign
/// finding #3 — would yield a truncated or garbage result instead; here any deviation
/// fails the whole decode. Internal (not private) for its sole remaining caller,
/// `RoundAuthenticator.signingPayloadV2`, which decodes round ids with this strictness
/// for auth v2 signing.
func strictHexData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var idx = hex.startIndex
    while idx < hex.endIndex {
        guard
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex),
            let byte = UInt8(hex[idx..<next], radix: 16)
        else {
            return nil
        }
        data.append(byte)
        idx = next
    }
    return data
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

private func hexString(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Response Parsers

/// Proposal ids the vote circuit accepts. `zcash_voting` 4.0 raised the circuit's limit from 15
/// to 50 (`MAX_PROPOSAL_ID`); the count bound follows because every proposal in a round needs
/// its own id in this range.
let votingProposalIdRange: ClosedRange<UInt32> = 1...50

private func validateProposals(_ proposals: [VotingProposal]) throws {
    guard (1...Int(votingProposalIdRange.upperBound)).contains(proposals.count) else {
        throw SvAPIError.invalidResponse(
            "proposals must contain between 1 and \(votingProposalIdRange.upperBound) entries"
        )
    }

    var proposalIds = Set<UInt32>()
    for proposal in proposals {
        guard votingProposalIdRange.contains(proposal.id) else {
            throw SvAPIError.invalidResponse(
                "proposal id must be in the range \(votingProposalIdRange.lowerBound) to \(votingProposalIdRange.upperBound)"
            )
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
                label: o["label"] as? String ?? "Option \(parseUInt32(o["index"]))",
                description: o["description"] as? String
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

/// Parses every round entry the server returned, dropping an entry that fails validation so one
/// malformed or not-yet-supported round hides only itself instead of emptying the whole list.
func parseVotingSessions(skippingInvalidRounds rounds: [[String: Any]]) -> [VotingSession] {
    rounds.compactMap { round in
        do {
            return try parseVotingSession(from: round)
        } catch {
            LoggerProxy.error("Skipping a round that failed validation: \(error)")
            return nil
        }
    }
}

/// Authenticate a chain-sourced round before the wallet treats it as usable.
///
/// Vote servers are endpoint-discovery targets from the dynamic config, not
/// trust anchors. The wallet trusts the bundled static config's admin keys,
/// verifies the dynamic config's signed `ea_pk` for this round id, then checks
/// that the chain response is bound to the same `ea_pk`.
private func authenticateVotingSession(_ session: VotingSession) async throws -> VotingSession {
    guard let configuration = await SvAPIConfigStore.shared.getConfiguration() else {
        LoggerProxy.error("Round auth failed: trust material unavailable")
        throw SvAPIError.noActiveVotingSession
    }

    let roundIdHex = hexString(from: session.voteRoundId)
    // `rounds` and `pirLayout` intentionally come from the same stored dynamic config:
    // the v2 attestation signs the round id together with that config's PIR layout.
    let status = RoundAuthenticator.authenticate(
        chainEaPK: session.eaPK,
        roundIdHex: roundIdHex,
        rounds: configuration.serviceConfig.rounds,
        trustedKeys: configuration.staticConfig.trustedKeys,
        pirLayout: configuration.serviceConfig.pirLayout
    )
    guard status == .authenticated else {
        LoggerProxy.error(
            "Round auth failed: status=\(String(describing: status)) round=\(roundIdHex)"
        )
        // Per current UX, unauthenticated rounds are hidden behind the same
        // surface as "no active round" rather than shown as a separate warning.
        throw SvAPIError.noActiveVotingSession
    }
    return session
}

private func authenticatedVotingSessions(from rounds: [[String: Any]]) async throws -> [VotingSession] {
    var authenticated: [VotingSession] = []
    for session in parseVotingSessions(skippingInvalidRounds: rounds) {
        do {
            authenticated.append(try await authenticateVotingSession(session))
        } catch SvAPIError.noActiveVotingSession {
            LoggerProxy.error("Skipping unauthenticated round \(hexString(from: session.voteRoundId))")
        }
    }
    return authenticated
}

/// Return a copy containing only round entries with at least one trusted signature.
///
/// Round authentication is intentionally per-round: one broken historical
/// signature must hide only that round, while still allowing other active
/// or finalized rounds to render. Verification is v2 (MOB-1678): each signature
/// covers the round id and this config's own top-level `pir_layout`, so entries
/// signed for another round id or another layout generation drop here.
func serviceConfigRetainingRoundsWithValidSignatures(
    _ config: VotingServiceConfig,
    trustedKeys: [StaticVotingConfig.TrustedKey]
) -> VotingServiceConfig {
    let authenticatedRounds = config.rounds.filter { roundIdHex, entry in
        RoundAuthenticator.verifyEntrySignatures(
            entry: entry,
            roundIdHex: roundIdHex,
            pirLayout: config.pirLayout,
            trustedKeys: trustedKeys
        )
    }
    return VotingServiceConfig(
        configVersion: config.configVersion,
        voteServers: config.voteServers,
        pirEndpoints: config.pirEndpoints,
        supportedVersions: config.supportedVersions,
        rounds: authenticatedRounds,
        pirLayout: config.pirLayout
    )
}

@Sendable
func fetchVotingServiceConfig(
    override: PinnedConfigSource?,
    pollLoadingBudget: VotingPollLoadingBudget
) async throws -> VotingServiceConfig {
    let staticConfig = try await StaticVotingConfig.loadFromNetworkWithFailover(
        sources: StaticVotingConfig.resolveConfigSources(override: override),
        fetch: { request in
            try await performPollLoadingRequest(request, budget: pollLoadingBudget)
        }
    )

    // Fetch and decode the CDN config. Any failure (transport, HTTP, decode,
    // or version-validation) surfaces as a VotingConfigError — no silent fallback.
    let (data, origin) = try await VotingConfigMirrorWalk.fetchDynamicConfig(
        urls: staticConfig.dynamicConfigURLs,
        fetch: { request in
            try await performPollLoadingRequest(request, budget: pollLoadingBudget)
        }
    )
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
    LoggerProxy.info(
        """
        Loaded config from \(origin.host ?? "<unknown origin>"): \(authenticatedConfig.voteServers.count) vote servers, \
        \(authenticatedConfig.rounds.count) authenticated rounds, \(droppedRounds) dropped rounds
        """
    )
    return authenticatedConfig
}

// MARK: - Live Implementation

extension VotingAPIClient: DependencyKey {
    static var liveValue: Self {
        Self(
            fetchServiceConfig: { override in
                try await fetchVotingServiceConfig(
                    override: override,
                    pollLoadingBudget: VotingPollLoadingBudget()
                )
            },
            configureURLs: { config in
                await SvAPIConfigStore.shared.configure(from: config)
                let base = config.voteServers.first?.url
                let pir = config.pirEndpoints.first?.url
                LoggerProxy.info(
                    """
                    URLs configured: base=\(base ?? "<none>"), \
                    voteServers=\(config.voteServers.count), pir=\(pir ?? "<none>"), \
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
                let json = try await getJSON(
                    "/shielded-vote/v1/rounds",
                    pollLoadingBudget: VotingPollLoadingBudget()
                )
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
                    let json = try await getJSON(
                        "/shielded-vote/v1/endorsed-rounds/zodl",
                        pollLoadingBudget: VotingPollLoadingBudget()
                    )
                    guard let ids = json["vote_round_ids"] as? [String] else {
                        return []
                    }
                    // The chain returns ids either as base64-encoded 32-byte
                    // values or as 64-char hex strings depending on the
                    // deployment. Hex digits are also valid base64 chars, so
                    // we can't tell by parse success alone — accept a base64
                    // decode only if it yields exactly 32 bytes, otherwise
                    // fall back to treating the value as already hex. App
                    // keys rounds by lowercase hex.
                    return Set(ids.compactMap { raw -> String? in
                        if let data = Data(base64Encoded: raw), data.count == 32 {
                            return hexString(from: data)
                        }
                        let normalized = raw.lowercased()
                        let isHex = normalized.count == 64
                            && normalized.allSatisfy(\.isHexDigit)
                        return isHex ? normalized : nil
                    })
                } catch SvAPIError.httpError(let statusCode, _) where statusCode == 400 || statusCode == 404 {
                    // Endorser not configured on this chain. Treat as no endorsements.
                    return []
                }
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
            }
        )
    }
}
#endif
