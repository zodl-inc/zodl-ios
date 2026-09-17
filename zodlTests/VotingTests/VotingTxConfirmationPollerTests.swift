#if VOTING_ENABLED
//
//  VotingTxConfirmationPollerTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(1)))
struct VotingTxConfirmationPollerTests {
    private static let preferredServer = "https://vote-a.example"
    private static let mined = TxConfirmation(height: 100, code: 0)

    @Test func aSlowPreferredServerTriggersAnElapsedSweepWellBeforeTheDeadline() async throws {
        let testClock = TestClock()
        let preferences = SignalledRecords<String?>()
        let fetchTimes = SignalledRecords<TestClock<Swift.Duration>.Instant>()
        let sleepDeadlines = SignalledRecords<TestClock<Swift.Duration>.Instant>()
        let clock = RecordingClock(base: testClock, sleepDeadlines: sleepDeadlines)

        let task = Task {
            try await VotingTxConfirmationPoller.wait(
                preferredServerURL: Self.preferredServer,
                timeout: .seconds(90),
                clock: clock
            ) { preference, _ in
                preferences.record(preference)
                fetchTimes.record(clock.now)
                if preference == Self.preferredServer {
                    try await clock.sleep(for: .seconds(6))
                    return nil
                }
                return Self.mined
            }
        }

        for sleepCount in 1...4 {
            await sleepDeadlines.countReached(sleepCount)
            await testClock.advance(to: sleepDeadlines.values[sleepCount - 1].advanced(by: .nanoseconds(1)))
        }
        await preferences.countReached(3)
        if preferences.values[2] != nil {
            task.cancel()
            _ = try? await task.value
            Issue.record(
                "a full sweep was not selected after nine elapsed seconds; "
                    + "preferences=\(preferences.values), fetchTimes=\(fetchTimes.values), "
                    + "sleepDeadlines=\(sleepDeadlines.values), now=\(testClock.now)"
            )
            return
        }
        let result = try await task.value

        #expect(result.confirmation == Self.mined)
        #expect(result.attempts == 3)
        #expect(preferences.values == [Self.preferredServer, Self.preferredServer, nil])
        #expect(testClock.now < TestClock<Swift.Duration>.Instant(offset: .seconds(20)))
    }

    @Test func aFetchFinishingAtExpiryStartsNoFurtherFetchOrSleep() async throws {
        let testClock = TestClock()
        let fetches = SignalledRecords<Void>()
        let sleepDeadlines = SignalledRecords<TestClock<Swift.Duration>.Instant>()
        let clock = RecordingClock(base: testClock, sleepDeadlines: sleepDeadlines)

        let task = Task {
            try await VotingTxConfirmationPoller.wait(
                preferredServerURL: Self.preferredServer,
                timeout: .seconds(5),
                clock: clock
            ) { _, _ in
                fetches.recordCall()
                try await clock.sleep(for: .seconds(5))
                return nil
            }
        }

        await fetches.countReached(1)
        await sleepDeadlines.countReached(1)
        await testClock.advance(to: sleepDeadlines.values[0].advanced(by: .nanoseconds(1)))
        let result = try await task.value

        #expect(result.confirmation == nil)
        #expect(result.attempts == 1)
        #expect(fetches.count == 1)
        try await testClock.checkSuspension()
    }

    @Test func cancellationBeforeLookupStartsNoFetch() async {
        let fetches = SignalledRecords<Void>()

        let task = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await VotingTxConfirmationPoller.wait(
                preferredServerURL: Self.preferredServer,
                timeout: .seconds(90),
                clock: ContinuousClock()
            ) { _, _ in
                fetches.recordCall()
                return nil
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(fetches.isEmpty)
    }

    @Test func cancellationDuringCadenceSleepStopsPolling() async {
        let clock = TestClock()
        let fetches = SignalledRecords<Void>()

        let task = Task {
            try await VotingTxConfirmationPoller.wait(
                preferredServerURL: Self.preferredServer,
                timeout: .seconds(90),
                clock: clock
            ) { _, _ in
                fetches.recordCall()
                return nil
            }
        }

        await fetches.countReached(1)
        try? await clock.checkSuspension()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(fetches.count == 1)
    }

    @Test func cancellationErrorFromFetchIsNeverRetried() async {
        let fetches = SignalledRecords<Void>()

        await #expect(throws: CancellationError.self) {
            try await VotingTxConfirmationPoller.wait(
                preferredServerURL: Self.preferredServer,
                timeout: .seconds(90),
                clock: ContinuousClock()
            ) { _, _ in
                fetches.recordCall()
                throw CancellationError()
            }
        }
        #expect(fetches.count == 1)
    }

    @Test func retryableFetchErrorsCountAsAttempts() async throws {
        let testClock = TestClock()
        let fetches = SignalledRecords<Void>()
        let sleepDeadlines = SignalledRecords<TestClock<Swift.Duration>.Instant>()
        let clock = RecordingClock(base: testClock, sleepDeadlines: sleepDeadlines)

        let task = Task {
            try await VotingTxConfirmationPoller.wait(
                preferredServerURL: nil,
                timeout: .seconds(5),
                retryDelay: .milliseconds(750),
                clock: clock
            ) { preference, _ in
                #expect(preference == nil)
                let attempt = fetches.recordCall()
                if attempt == 1 {
                    throw URLError(URLError.Code.notConnectedToInternet)
                }
                return Self.mined
            }
        }

        await fetches.countReached(1)
        await sleepDeadlines.countReached(1)
        await testClock.advance(to: sleepDeadlines.values[0].advanced(by: .nanoseconds(1)))
        let result = try await task.value

        #expect(result == VotingTxConfirmationPollResult(confirmation: Self.mined, attempts: 2))
    }

    @Test func aConfirmedRejectionIsReturnedImmediately() async throws {
        let rejected = TxConfirmation(height: 0, code: 5, log: "rejected")

        let result = try await VotingTxConfirmationPoller.wait(
            preferredServerURL: Self.preferredServer,
            timeout: .seconds(90),
            clock: ContinuousClock()
        ) { _, _ in rejected }

        #expect(result == VotingTxConfirmationPollResult(confirmation: rejected, attempts: 1))
    }

    @Test func anExhaustedBudgetStartsNoFetch() async throws {
        let fetches = SignalledRecords<Void>()

        let result = try await VotingTxConfirmationPoller.wait(
            preferredServerURL: Self.preferredServer,
            timeout: .zero,
            clock: ContinuousClock()
        ) { _, _ in
            fetches.recordCall()
            return Self.mined
        }

        #expect(result == VotingTxConfirmationPollResult(confirmation: nil, attempts: 0))
        #expect(fetches.isEmpty)
    }
}

private struct RecordingClock<Base: Clock>: Clock where Base.Duration == Swift.Duration {
    let base: Base
    let sleepDeadlines: SignalledRecords<Base.Instant>

    var now: Base.Instant { base.now }
    var minimumResolution: Swift.Duration { base.minimumResolution }

    func sleep(until deadline: Base.Instant, tolerance: Swift.Duration?) async throws {
        sleepDeadlines.record(deadline)
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}
#endif
