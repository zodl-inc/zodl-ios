#if VOTING_ENABLED
//
//  VotingTxConfirmationWalkTests.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(1)))
struct VotingTxConfirmationWalkTests {
    private static let servers = ["https://vote-a.example", "https://vote-b.example", "https://vote-c.example"]
    private static let mined = TxConfirmation(height: 100, code: 0)

    @Test func theAcceptingServersConfirmationIsTakenWithoutAskingAnyoneElse() async {
        let asked = SignalledRecords<String>()

        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: "https://vote-b.example") { server in
            asked.record(server)
            return .confirmed(Self.mined)
        }

        #expect(result == Self.mined)
        #expect(asked.values == ["https://vote-b.example"])
    }

    @Test func aNotIndexedAnswerFromTheAcceptingServerEndsTheAttempt() async {
        let asked = SignalledRecords<String>()

        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: "https://vote-b.example") { server in
            asked.record(server)
            return server == "https://vote-b.example" ? .notIndexed : .confirmed(Self.mined)
        }

        #expect(result == nil)
        #expect(asked.values == ["https://vote-b.example"])
    }

    @Test func anUnavailableAcceptingServerFallsThroughToTheOthersInOrder() async {
        let asked = SignalledRecords<String>()

        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: "https://vote-b.example") { server in
            asked.record(server)
            switch server {
            case "https://vote-b.example": return .unavailable
            case "https://vote-a.example": return .notIndexed
            default: return .confirmed(Self.mined)
            }
        }

        #expect(result == Self.mined)
        #expect(asked.values == ["https://vote-b.example", "https://vote-a.example", "https://vote-c.example"])
    }

    @Test func withoutAnAcceptingServerEveryServerIsAskedInOrderUntilOneConfirms() async {
        let asked = SignalledRecords<String>()

        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: nil) { server in
            asked.record(server)
            return server == "https://vote-c.example" ? .confirmed(Self.mined) : .notIndexed
        }

        #expect(result == Self.mined)
        #expect(asked.values == Self.servers)
    }

    @Test func nobodyConfirmingReturnsNil() async {
        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: nil) { _ in .unavailable }
        #expect(result == nil)
    }

    @Test func aRejectionCarriesItsCodeAsAConfirmation() async {
        let rejected = TxConfirmation(height: 0, code: 5, log: "nullifier already spent")

        let result = await VotingTxConfirmationWalk.run(servers: Self.servers, preferredServerURL: "https://vote-a.example") { _ in
            .confirmed(rejected)
        }

        #expect(result == rejected)
    }

    @Test func thePollPlanKeepsTheAcceptingServerAuthoritativeThenSweepsEveryFourthAttempt() {
        let server = "https://vote-a.example"
        for attempt in 1...TxConfirmationPollPlan.authoritativeAttempts {
            #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: server, attempt: attempt) == server)
        }
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: server, attempt: 13) == server)
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: server, attempt: 16) == nil)
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: server, attempt: 17) == server)
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: server, attempt: 20) == nil)
    }

    @Test func thePollPlanHasNoPreferenceWithoutAnAcceptingServer() {
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: nil, attempt: 1) == nil)
        #expect(TxConfirmationPollPlan.preferredServer(acceptedBy: nil, attempt: 16) == nil)
    }
}
#endif
