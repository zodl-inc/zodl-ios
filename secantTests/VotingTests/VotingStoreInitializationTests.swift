import ComposableArchitecture
import Foundation
import XCTest
@testable import secant_testnet

@MainActor
final class VotingStoreInitializationTests: XCTestCase {
    func testHowToVoteSeenFlagIsWalletTypeSpecific() {
        var state = Voting.State()

        state.hasSeenHowToVote = true
        state.hasSeenHowToVoteKeystone = false

        state.isKeystoneUser = false
        XCTAssertTrue(state.hasSeenHowToVoteForCurrentWallet)

        state.isKeystoneUser = true
        XCTAssertFalse(state.hasSeenHowToVoteForCurrentWallet)

        state.hasSeenHowToVoteKeystone = true
        XCTAssertTrue(state.hasSeenHowToVoteForCurrentWallet)
    }

    func testPinnedConfigSourceAllowsMissingChecksum() throws {
        let source = try PinnedConfigSource.parse("https://override.example.com/static-voting-config.json?foo=bar")

        XCTAssertEqual(source.url.absoluteString, "https://override.example.com/static-voting-config.json?foo=bar")
        XCTAssertNil(source.sha256)
    }

    func testPinnedConfigSourceStripsAndParsesChecksumWhenPresent() throws {
        let source = try PinnedConfigSource.parse(
            "https://override.example.com/static-voting-config.json" +
            "?foo=bar&checksum=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )

        XCTAssertEqual(source.url.absoluteString, "https://override.example.com/static-voting-config.json?foo=bar")
        XCTAssertEqual(source.sha256, Data(repeating: 0xAA, count: 32))
    }

    func testStaticVotingConfigDecodeSkipsHashCheckWhenChecksumIsMissing() throws {
        let data = """
        {
          "static_config_version": 1,
          "dynamic_config_url": "https://override.example.com/dynamic-voting-config.json",
          "trusted_keys": [
            {
              "key_id": "test-key",
              "alg": "ed25519",
              "pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            }
          ]
        }
        """.data(using: .utf8)!

        let config = try StaticVotingConfig.decodeAndVerify(data: data, expectedSHA256: nil)

        XCTAssertEqual(config.staticConfigVersion, 1)
        XCTAssertEqual(config.dynamicConfigURL.absoluteString, "https://override.example.com/dynamic-voting-config.json")
        XCTAssertEqual(config.trustedKeys.count, 1)
    }

    func testInitializeRefreshesConfigAndRoundsWhenReopeningPollsList() async {
        let callCounter = CallCounter()
        let config = makeConfig()
        let session = makeSession()
        var initialState = Voting.State()
        initialState.screenStack = [.pollsList]

        let store = TestStore(
            initialState: initialState
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchServiceConfig = { _ in
            await callCounter.incrementConfigFetches()
            return config
        }
        store.dependencies.votingAPI.configureURLs = { _ in
            await callCounter.incrementURLConfigurations()
        }
        store.dependencies.votingAPI.fetchAllRounds = {
            await callCounter.incrementRoundFetches()
            return [session]
        }
        store.dependencies.votingAPI.fetchZodlEndorsedRoundIds = {
            await callCounter.incrementEndorsementFetches()
            return [session.voteRoundId.hexString]
        }
        store.dependencies.votingCrypto.openDatabase = { _ in }
        store.dependencies.votingCrypto.setWalletId = { _ in }

        await store.send(.initialize) {
            $0.votingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: Date(timeIntervalSince1970: 0),
                votingStart: Date(timeIntervalSince1970: 0),
                votingEnd: Date(timeIntervalSince1970: 0),
                proposals: []
            )
            $0.screenStack = [.loading]
        }
        await store.receive(.serviceConfigLoaded(config)) {
            $0.serviceConfig = config
        }
        await store.receive(.allRoundsLoaded([session])) {
            $0.allRounds = [
                Voting.State.RoundListItem(roundNumber: 1, session: session)
            ]
            $0.screenStack = [.pollsList]
            $0.voteRecords = [:]
        }
        await store.receive(.fetchZodlEndorsements)
        await store.receive(.zodlEndorsementsLoaded([session.voteRoundId.hexString])) {
            $0.zodlEndorsedRoundIds = [session.voteRoundId.hexString]
        }

        await store.send(.initialize) {
            $0.serviceConfig = nil
            $0.activeSession = nil
            $0.allRounds = []
            $0.voteRecords = [:]
            $0.zodlEndorsedRoundIds = []
            $0.voteRecord = nil
            $0.roundId = ""
            $0.votingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: Date(timeIntervalSince1970: 0),
                votingStart: Date(timeIntervalSince1970: 0),
                votingEnd: Date(timeIntervalSince1970: 0),
                proposals: []
            )
            $0.votes = [:]
            $0.screenStack = [.loading]
        }
        await store.receive(.serviceConfigLoaded(config)) {
            $0.serviceConfig = config
        }
        await store.receive(.allRoundsLoaded([session])) {
            $0.allRounds = [
                Voting.State.RoundListItem(roundNumber: 1, session: session)
            ]
            $0.screenStack = [.pollsList]
            $0.voteRecords = [:]
        }
        await store.receive(.fetchZodlEndorsements)
        await store.receive(.zodlEndorsementsLoaded([session.voteRoundId.hexString])) {
            $0.zodlEndorsedRoundIds = [session.voteRoundId.hexString]
        }

        XCTAssertEqual(await callCounter.configFetches, 2)
        XCTAssertEqual(await callCounter.urlConfigurations, 2)
        XCTAssertEqual(await callCounter.roundFetches, 2)
        XCTAssertEqual(await callCounter.endorsementFetches, 2)
    }

    func testInitializeClearsStaleRoundsAndShowsConfigErrorWhenConfigFails() async {
        let session = makeSession()
        let staleRound = Voting.State.RoundListItem(roundNumber: 1, session: session)
        var initialState = Voting.State()
        initialState.screenStack = [.pollsList]
        initialState.serviceConfig = makeConfig()
        initialState.allRounds = [staleRound]
        initialState.activeSession = session
        initialState.roundId = session.voteRoundId.hexString
        initialState.votingRound = VotingRound(
            id: session.voteRoundId.hexString,
            title: session.title,
            description: session.description,
            snapshotHeight: session.snapshotHeight,
            snapshotDate: .now,
            votingStart: .now,
            votingEnd: session.voteEndTime,
            proposals: session.proposals
        )
        initialState.votes = [1: .option(0)]
        initialState.voteRecords = [
            staleRound.id: VoteRecord(
                votedAt: Date(timeIntervalSince1970: 1),
                votingWeight: 1,
                proposalCount: 1
            )
        ]

        let store = TestStore(
            initialState: initialState
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchServiceConfig = { _ in
            throw TestConfigError()
        }

        await store.send(.initialize) {
            $0.serviceConfig = nil
            $0.activeSession = nil
            $0.allRounds = []
            $0.voteRecords = [:]
            $0.voteRecord = nil
            $0.roundId = ""
            $0.votingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: Date(timeIntervalSince1970: 0),
                votingStart: Date(timeIntervalSince1970: 0),
                votingEnd: Date(timeIntervalSince1970: 0),
                proposals: []
            )
            $0.votes = [:]
            $0.screenStack = [.loading]
        }
        await store.receive(.configUnsupported("Pinned config failed")) {
            $0.screenStack = [.configError("Pinned config failed")]
        }
    }

    func testInitializePassesPersistedConfigOverrideToServiceConfigFetch() async {
        let recorder = OverrideRecorder()
        let config = makeConfig()
        var initialState = Voting.State()
        initialState.screenStack = [.pollsList]
        initialState.votingConfigOverrideURL =
            "https://override.example.com/static-voting-config.json" +
            "?foo=bar&checksum=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        let store = TestStore(
            initialState: initialState
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchServiceConfig = { override in
            await recorder.record(override)
            return config
        }
        store.dependencies.votingAPI.configureURLs = { _ in }
        store.dependencies.votingAPI.fetchAllRounds = { [] }
        store.dependencies.votingAPI.fetchZodlEndorsedRoundIds = { [] }
        store.dependencies.votingCrypto.openDatabase = { _ in }
        store.dependencies.votingCrypto.setWalletId = { _ in }

        await store.send(.initialize) {
            $0.votingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: Date(timeIntervalSince1970: 0),
                votingStart: Date(timeIntervalSince1970: 0),
                votingEnd: Date(timeIntervalSince1970: 0),
                proposals: []
            )
            $0.screenStack = [.loading]
        }
        await store.receive(.serviceConfigLoaded(config)) {
            $0.serviceConfig = config
        }
        await store.receive(.allRoundsLoaded([])) {
            $0.allRounds = []
            $0.screenStack = [.noRounds]
            $0.voteRecords = [:]
        }

        let overrides = await recorder.snapshot()
        XCTAssertEqual(overrides.count, 1)
        guard let override = overrides.first ?? nil else {
            XCTFail("Expected initialize to pass a parsed config override")
            return
        }
        XCTAssertEqual(
            override.url.absoluteString,
            "https://override.example.com/static-voting-config.json?foo=bar"
        )
        XCTAssertEqual(override.sha256, Data(repeating: 0xAA, count: 32))
    }

    func testInitializeFallsBackToBundledConfigWhenPersistedOverrideIsMalformed() async {
        let recorder = OverrideRecorder()
        let config = makeConfig()
        var initialState = Voting.State()
        initialState.screenStack = [.pollsList]
        initialState.votingConfigOverrideURL = "http://override.example.com/static-voting-config.json"

        let store = TestStore(
            initialState: initialState
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchServiceConfig = { override in
            await recorder.record(override)
            return config
        }
        store.dependencies.votingAPI.configureURLs = { _ in }
        store.dependencies.votingAPI.fetchAllRounds = { [] }
        store.dependencies.votingAPI.fetchZodlEndorsedRoundIds = { [] }
        store.dependencies.votingCrypto.openDatabase = { _ in }
        store.dependencies.votingCrypto.setWalletId = { _ in }

        await store.send(.initialize) {
            $0.votingRound = VotingRound(
                id: "",
                title: "",
                description: "",
                snapshotHeight: 0,
                snapshotDate: Date(timeIntervalSince1970: 0),
                votingStart: Date(timeIntervalSince1970: 0),
                votingEnd: Date(timeIntervalSince1970: 0),
                proposals: []
            )
            $0.screenStack = [.loading]
        }
        await store.receive(.serviceConfigLoaded(config)) {
            $0.serviceConfig = config
        }
        await store.receive(.allRoundsLoaded([])) {
            $0.allRounds = []
            $0.screenStack = [.noRounds]
            $0.voteRecords = [:]
        }

        let overrides = await recorder.snapshot()
        XCTAssertEqual(overrides.count, 1)
        XCTAssertNil(overrides.first ?? nil)
    }

    func testFetchZodlEndorsementsStoresLoadedRoundIds() async {
        let roundId = Data(repeating: 0xAB, count: 32).hexString
        let store = TestStore(
            initialState: Voting.State()
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchZodlEndorsedRoundIds = {
            [roundId]
        }

        await store.send(.fetchZodlEndorsements)
        await store.receive(.zodlEndorsementsLoaded([roundId])) {
            $0.zodlEndorsedRoundIds = [roundId]
        }
    }

    func testFetchZodlEndorsementsFailureClearsToEmptySet() async {
        var initialState = Voting.State()
        initialState.zodlEndorsedRoundIds = ["stale"]
        let store = TestStore(
            initialState: initialState
        ) {
            Voting()
        }
        store.dependencies.votingAPI.fetchZodlEndorsedRoundIds = {
            throw TestEndorsementError()
        }

        await store.send(.fetchZodlEndorsements)
        await store.receive(.zodlEndorsementsLoaded([])) {
            $0.zodlEndorsedRoundIds = []
        }
    }

    private func makeConfig() -> VotingServiceConfig {
        VotingServiceConfig(
            configVersion: 1,
            voteServers: [.init(url: "https://vote.example.com", label: "vote")],
            pirEndpoints: [.init(url: "https://pir.example.com", label: "pir")],
            supportedVersions: .init(
                pir: ["v0"],
                voteProtocol: "v0",
                tally: "v0",
                voteServer: "v1"
            ),
            rounds: [:]
        )
    }

    private func makeSession() -> VotingSession {
        VotingSession(
            voteRoundId: Data(repeating: 0xAA, count: 32),
            snapshotHeight: 1,
            snapshotBlockhash: Data(repeating: 0x01, count: 32),
            proposalsHash: Data(repeating: 0x02, count: 32),
            voteEndTime: Date(timeIntervalSince1970: 1),
            ceremonyStart: Date(timeIntervalSince1970: 0),
            eaPK: Data(repeating: 0x03, count: 32),
            vkZkp1: Data(repeating: 0x04, count: 32),
            vkZkp2: Data(repeating: 0x05, count: 32),
            vkZkp3: Data(repeating: 0x06, count: 32),
            ncRoot: Data(repeating: 0x07, count: 32),
            nullifierIMTRoot: Data(repeating: 0x08, count: 32),
            creator: "creator",
            proposals: [
                VotingProposal(
                    id: 1,
                    title: "Chain proposal",
                    description: "Fetched from chain",
                    options: [
                        VoteOption(index: 0, label: "Support"),
                        VoteOption(index: 1, label: "Oppose")
                    ]
                )
            ],
            status: .active,
            createdAtHeight: 1,
            title: "Round"
        )
    }
}

private struct TestConfigError: LocalizedError {
    var errorDescription: String? {
        "Pinned config failed"
    }
}

private struct TestEndorsementError: Error {}

private actor OverrideRecorder {
    private var overrides: [PinnedConfigSource?] = []

    func record(_ override: PinnedConfigSource?) {
        overrides.append(override)
    }

    func snapshot() -> [PinnedConfigSource?] {
        overrides
    }
}

private actor CallCounter {
    private(set) var configFetches = 0
    private(set) var urlConfigurations = 0
    private(set) var roundFetches = 0
    private(set) var endorsementFetches = 0

    func incrementConfigFetches() {
        configFetches += 1
    }

    func incrementURLConfigurations() {
        urlConfigurations += 1
    }

    func incrementRoundFetches() {
        roundFetches += 1
    }

    func incrementEndorsementFetches() {
        endorsementFetches += 1
    }
}
