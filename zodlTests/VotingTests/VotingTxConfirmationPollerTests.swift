#if VOTING_ENABLED
//
//  VotingTxConfirmationPollerTests.swift
//  zodlTests
//
//  The clock-driven tests run on `SignalledClock` (`TestSupport/SignalledClock.swift`), not
//  `TestClock`: every `TestClock.advance` spends two to three `Task.megaYield`s -- 20 detached
//  background-priority tasks each -- and on the shared CI runner one megaYield was measured at
//  ~7 s, so the four-advance sweep test below ran 62-76 s of wall time against this suite's
//  one-minute limit while its clock never passed its twentieth logical second. `SignalledClock`
//  parks a sleep and then records its deadline, so `sleepDeadlines.countReached(n)` is the
//  event-driven positive wait for "the n-th sleep is parked" and `advance(to:)` resumes it with
//  no yield at all. Nothing here waits on wall time; the `.timeLimit` only turns a wait that never
//  fires into a recorded failure.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(3)))
struct VotingTxConfirmationPollerTests {
    private static let preferredServer = "https://vote-a.example"
    private static let mined = TxConfirmation(height: 100, code: 0)

    @Test func aSlowPreferredServerTriggersAnElapsedSweepWellBeforeTheDeadline() async throws {
        let clock = SignalledClock()
        let preferences = SignalledRecords<String?>()
        let fetchTimes = SignalledRecords<SignalledClock.Instant>()

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

        // The slow preferred fetch (6 s), the cadence sleep, the second preferred fetch and its
        // cadence sleep: each parks before its deadline is recorded, so advancing just past that
        // deadline resumes exactly that sleep.
        for sleepCount in 1...4 {
            await clock.sleepDeadlines.countReached(sleepCount)
            clock.advance(to: clock.sleepDeadlines.values[sleepCount - 1].advanced(by: .nanoseconds(1)))
        }
        await preferences.countReached(3)
        if preferences.values[2] != nil {
            task.cancel()
            _ = try? await task.value
            Issue.record(
                "a full sweep was not selected after nine elapsed seconds; "
                    + "preferences=\(preferences.values), fetchTimes=\(fetchTimes.values), "
                    + "sleepDeadlines=\(clock.sleepDeadlines.values), now=\(clock.now)"
            )
            return
        }
        let result = try await task.value

        #expect(result.confirmation == Self.mined)
        #expect(result.attempts == 3)
        #expect(preferences.values == [Self.preferredServer, Self.preferredServer, nil])
        #expect(clock.now < SignalledClock.Instant(offset: .seconds(20)))
    }

    @Test func aFetchFinishingAtExpiryStartsNoFurtherFetchOrSleep() async throws {
        let clock = SignalledClock()
        let fetches = SignalledRecords<Void>()

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
        await clock.sleepDeadlines.countReached(1)
        clock.advance(to: clock.sleepDeadlines.values[0].advanced(by: .nanoseconds(1)))
        let result = try await task.value

        #expect(result.confirmation == nil)
        #expect(result.attempts == 1)
        #expect(fetches.count == 1)
        #expect(clock.sleepDeadlines.count == 1, "the fetch's own sleep must be the only one")
        #expect(clock.pendingSleeps == 0)
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
        let clock = SignalledClock()
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
        // The poller is parked in its cadence sleep when the cancel lands.
        await clock.sleepDeadlines.countReached(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(fetches.count == 1)
        #expect(clock.pendingSleeps == 0, "a cancelled sleep must leave nothing parked")
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
        let clock = SignalledClock()
        let fetches = SignalledRecords<Void>()

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
        await clock.sleepDeadlines.countReached(1)
        clock.advance(to: clock.sleepDeadlines.values[0].advanced(by: .nanoseconds(1)))
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
#endif
