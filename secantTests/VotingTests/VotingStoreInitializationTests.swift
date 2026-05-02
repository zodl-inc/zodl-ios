import ComposableArchitecture
import Foundation
import XCTest
@testable import secant_testnet

@MainActor
final class VotingStoreInitializationTests: XCTestCase {
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
        store.dependencies.votingAPI.fetchServiceConfig = {
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
        store.dependencies.votingCrypto.openDatabase = { _ in }
        store.dependencies.votingCrypto.setWalletId = { _ in }

        await store.send(.initialize)
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

        await store.send(.initialize)
        await store.receive(.serviceConfigLoaded(config))
        await store.receive(.allRoundsLoaded([session]))

        XCTAssertEqual(await callCounter.configFetches, 2)
        XCTAssertEqual(await callCounter.urlConfigurations, 2)
        XCTAssertEqual(await callCounter.roundFetches, 2)
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

private actor CallCounter {
    private(set) var configFetches = 0
    private(set) var urlConfigurations = 0
    private(set) var roundFetches = 0

    func incrementConfigFetches() {
        configFetches += 1
    }

    func incrementURLConfigurations() {
        urlConfigurations += 1
    }

    func incrementRoundFetches() {
        roundFetches += 1
    }
}
