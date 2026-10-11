//
//  SignalledClock.swift
//  zodlTests
//
//  A `Clock` for driving clock-parameterised code by hand WITHOUT the yields `TestClock` spends on
//  every advance. `TestClock.advance` calls `Task.megaYield()` two to three times per resumed
//  sleep -- each one 20 detached background-priority tasks awaited in sequence -- so that the
//  awoken code can run up to its next suspension before the test continues. On the shared CI
//  runner, where ~30 suites saturate the cooperative pool, background-priority tasks starve and
//  one megaYield was measured at ~7 s: `VotingTxConfirmationPollerTests`' four-advance sweep test
//  took 62-76 s of wall time against its one-minute limit while the clock it drove never passed
//  its twentieth logical second (unit_tests jobs 104801731182, 104819496663, 104825210677).
//
//  Here nothing yields. A sleep parks its continuation and only THEN records its deadline on
//  `sleepDeadlines`, so a test resumed by `sleepDeadlines.countReached(n)` knows the n-th sleep is
//  parked and `advance(to:)` will resume it -- the same event-driven positive wait
//  `SignalledRecords` gives every other spy (`TestSignals.swift`). Waiting for the awoken code to
//  reach its NEXT sleep is the test's job, through the same records; there is no "let it settle"
//  step to lose under load, and no deadline anywhere: a suite using this clock carries `.timeLimit`
//  so a wait that never fires is recorded instead of hanging the run.
//

import Foundation
import os

final class SignalledClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Hashable, Sendable {
        var offset: Swift.Duration

        init(offset: Swift.Duration = .zero) {
            self.offset = offset
        }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Suspension {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let state: OSAllocatedUnfairLock<(now: Instant, suspensions: [Suspension])>

    /// Every deadline a sleep has parked on, in parking order. Recorded AFTER the sleep is parked,
    /// so a waiter resumed by the n-th record can `advance(to:)` that deadline at once.
    let sleepDeadlines = SignalledRecords<Instant>()

    init(now: Instant = Instant()) {
        state = OSAllocatedUnfairLock(uncheckedState: (now: now, suspensions: []))
    }

    var now: Instant { state.withLockUnchecked { $0.now } }
    var minimumResolution: Swift.Duration { .zero }
    /// Sleeps parked and not yet resumed: the yield-free stand-in for `TestClock.checkSuspension()`.
    var pendingSleeps: Int { state.withLockUnchecked { $0.suspensions.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let settle: () -> Void = state.withLockUnchecked { state in
                    guard deadline >= state.now else {
                        return { continuation.resume() }
                    }
                    state.suspensions.append(Suspension(id: id, deadline: deadline, continuation: continuation))
                    // A cancellation that landed between the check at the top and this append ran
                    // its handler against a list without this sleep; the flag is already set, so
                    // honour it here, under the same lock the handler takes.
                    if Task.isCancelled {
                        state.suspensions.removeAll { $0.id == id }
                        return { continuation.resume(throwing: CancellationError()) }
                    }
                    return { self.sleepDeadlines.record(deadline) }
                }
                settle()
            }
        } onCancel: {
            let continuation = state.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.suspensions.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.suspensions.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` to `instant` and resumes every sleep parked at or before it, earliest first.
    /// Synchronous and yield-free: the resumed code runs on its own executor, and a test that
    /// needs it to have reached its next sleep waits for that on `sleepDeadlines`. Several sleeps
    /// resumed by one call run concurrently from there, so a test must not infer their execution
    /// order from their deadlines -- advance to one deadline at a time if the order matters.
    func advance(to instant: Instant) {
        let resumed = state.withLockUnchecked { state -> [CheckedContinuation<Void, any Error>] in
            state.now = instant
            let due = state.suspensions
                .filter { $0.deadline <= instant }
                .sorted { $0.deadline < $1.deadline }
            state.suspensions.removeAll { $0.deadline <= instant }
            return due.map(\.continuation)
        }
        resumed.forEach { $0.resume() }
    }

    func advance(by duration: Swift.Duration) {
        advance(to: now.advanced(by: duration))
    }
}
