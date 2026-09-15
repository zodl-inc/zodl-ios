#if VOTING_ENABLED
//
//  VotingTxConfirmationWalkTests.swift
//  zodlTests
//

import Foundation
import ComposableArchitecture
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(1)))
struct VotingTxConfirmationWalkTests {
    private static let servers = ["https://vote-a.example", "https://vote-b.example", "https://vote-c.example"]
    private static let mined = TxConfirmation(height: 100, code: 0)

    @Test func theAcceptingServersConfirmationIsTakenWithoutAskingAnyoneElse() async {
        let asked = SignalledRecords<String>()

        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: "https://vote-b.example",
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { server, _ in
            asked.record(server)
            return .confirmed(Self.mined)
        }

        #expect(result == Self.mined)
        #expect(asked.values == ["https://vote-b.example"])
    }

    @Test func aNotIndexedAnswerFromTheAcceptingServerEndsTheAttempt() async {
        let asked = SignalledRecords<String>()

        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: "https://vote-b.example",
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { server, _ in
            asked.record(server)
            return server == "https://vote-b.example" ? .notIndexed : .confirmed(Self.mined)
        }

        #expect(result == nil)
        #expect(asked.values == ["https://vote-b.example"])
    }

    @Test func anUnavailableAcceptingServerFallsThroughToTheOthersInOrder() async {
        let asked = SignalledRecords<String>()

        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: "https://vote-b.example",
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { server, _ in
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

        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: nil,
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { server, _ in
            asked.record(server)
            return server == "https://vote-c.example" ? .confirmed(Self.mined) : .notIndexed
        }

        #expect(result == Self.mined)
        #expect(asked.values == Self.servers)
    }

    @Test func nobodyConfirmingReturnsNil() async {
        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: nil,
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { _, _ in .unavailable }
        #expect(result == nil)
    }

    @Test func aRejectionCarriesItsCodeAsAConfirmation() async {
        let rejected = TxConfirmation(height: 0, code: 5, log: "nullifier already spent")

        let result = try? await VotingTxConfirmationWalk.run(
            servers: Self.servers,
            preferredServerURL: "https://vote-a.example",
            remainingBudget: nil,
            clock: ContinuousClock()
        ) { _, _ in
            .confirmed(rejected)
        }

        #expect(result == rejected)
    }

    @Test func thePollPlanSchedulesSweepsFromElapsedCompletionTime() {
        let server = "https://vote-a.example"
        var plan = TxConfirmationPollPlan()

        #expect(plan.preferredServer(acceptedBy: server, elapsed: .milliseconds(8_999)) == server)
        #expect(plan.preferredServer(acceptedBy: server, elapsed: .seconds(9)) == nil)

        plan.fullSweepCompleted(at: .seconds(15))

        #expect(plan.preferredServer(acceptedBy: server, elapsed: .milliseconds(17_999)) == server)
        #expect(plan.preferredServer(acceptedBy: server, elapsed: .seconds(18)) == nil)
    }

    @Test func thePollPlanHasNoPreferenceWithoutAnAcceptingServer() {
        var plan = TxConfirmationPollPlan()
        #expect(plan.preferredServer(acceptedBy: nil, elapsed: .zero) == nil)
        #expect(plan.preferredServer(acceptedBy: nil, elapsed: .seconds(30)) == nil)
    }

    @Test func eachServerReceivesTheBudgetRemainingAfterEarlierLookups() async throws {
        let clock = TestClock()
        let budgets = SignalledRecords<Duration>()

        let task = Task {
            try await VotingTxConfirmationWalk.run(
                servers: Self.servers,
                preferredServerURL: nil,
                remainingBudget: .seconds(10),
                clock: clock
            ) { server, remainingBudget in
                budgets.record(remainingBudget)
                if server == Self.servers[0] {
                    try await clock.sleep(for: .seconds(6))
                    return .notIndexed
                }
                return .confirmed(Self.mined)
            }
        }

        await budgets.countReached(1)
        await clock.advance(by: .seconds(6))
        let result = try await task.value

        #expect(result == Self.mined)
        #expect(budgets.values == [.seconds(10), .seconds(4)])
    }

    @Test func budgetExpiryAfterOneLookupStartsNoFurtherServer() async throws {
        let clock = TestClock()
        let asked = SignalledRecords<String>()

        let task = Task {
            try await VotingTxConfirmationWalk.run(
                servers: Self.servers,
                preferredServerURL: nil,
                remainingBudget: .seconds(5),
                clock: clock
            ) { server, _ in
                asked.record(server)
                try await clock.sleep(for: .seconds(5))
                return .unavailable
            }
        }

        await asked.countReached(1)
        await clock.advance(by: .seconds(5))
        let result = try await task.value

        #expect(result == nil)
        #expect(asked.values == [Self.servers[0]])
    }

    @Test func cancellationBetweenServerLookupsStopsTheWalk() async {
        let firstLookupStarted = SignalledRecords<Void>()
        let releaseFirstLookup = ResumableGate()
        let asked = SignalledRecords<String>()

        let task = Task {
            try await VotingTxConfirmationWalk.run(
                servers: Self.servers,
                preferredServerURL: nil,
                remainingBudget: .seconds(10),
                clock: ContinuousClock()
            ) { server, _ in
                asked.record(server)
                firstLookupStarted.recordCall()
                await releaseFirstLookup.wait()
                return .unavailable
            }
        }

        await firstLookupStarted.countReached(1)
        task.cancel()
        releaseFirstLookup.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(asked.values == [Self.servers[0]])
    }
}
#endif
