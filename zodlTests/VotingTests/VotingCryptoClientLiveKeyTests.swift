//
//  VotingCryptoClientLiveKeyTests.swift
//  zodlTests
//

#if VOTING_ENABLED
import Foundation
import Testing
import os
@testable import zodl_internal

/// Covers the cancellation wiring inside `VotingCryptoClient.makeDelegationProofStream`, the seam
/// `VotingCryptoClientLiveKey`'s `buildAndProveDelegation` closure delegates to. Before this, the
/// detached task backing the stream had no `onTermination` and no cancellation check, so leaving a
/// voting screen mid-proof left that proof running at proving priority in the background while the
/// next one started. These tests exercise the seam directly with a spy `prove`, standing in for the
/// real backend call, instead of driving the whole coordinator + Rust FFI.
@Suite struct VotingCryptoClientLiveKeyTests {
    @Test func uncancelledRunYieldsProgressThenCompletedInOrder() async throws {
        let spy = DelegationProofSpy(behavior: .succeedsImmediately(progress: [0.25, 0.75], proof: Data([1, 2, 3])))

        var received: [ProofEvent] = []
        for try await event in VotingCryptoClient.makeDelegationProofStream(prove: spy.prove) {
            received.append(event)
        }

        #expect(received == [.progress(0.25), .progress(0.75), .completed(Data([1, 2, 3]))])
    }

    @Test func cancellingWhileProveIsRunningIsObservedQuickly() async throws {
        let spy = DelegationProofSpy(behavior: .parksUntilCancelled)
        let stream = VotingCryptoClient.makeDelegationProofStream(prove: spy.prove)
        let consumer = Task<Void, Error> {
            for try await _ in stream { }
        }

        // Only cancel once `prove` has actually started, so this exercises cancellation reaching
        // code already past the seam's guard — the "abandoned proof already inside the FFI" case.
        await spy.invoked.wait()
        consumer.cancel()
        _ = try? await consumer.value

        let observedCancellation = await awaitSignal(spy.cancelledObserved, timeout: .milliseconds(100))
        #expect(observedCancellation)
    }

    @Test func cancellingBeforeProducerStartsNeverLeavesProveUncancelled() async throws {
        let spy = DelegationProofSpy(behavior: .parksUntilCancelled)
        let events = SignalledRecords<ProofEvent>()
        let consumer = Task<Void, Error> {
            // The stream (and the detached task it starts) is created only once this task's body
            // begins running, i.e. right as `cancel()` below races to mark it cancelled — so the
            // producer's dispatch races a cancellation that may land before or after the producer's
            // own `guard !Task.isCancelled` runs. Both orderings are legal Swift Concurrency
            // scheduling (neither is a language guarantee), so the assertions below tolerate either
            // outcome instead of assuming one — see the comment below for what must always hold.
            let stream = VotingCryptoClient.makeDelegationProofStream(prove: spy.prove)
            for try await event in stream {
                events.record(event)
            }
        }
        consumer.cancel()
        let consumerResult = await consumer.result
        if case .failure(let error) = consumerResult {
            #expect(error is CancellationError)
        }

        // Whichever way the two-hop race above lands, exactly one of two outcomes is legal:
        // `prove` is never invoked (the producer's own cancellation check won the race), or `prove`
        // is invoked and then observes cancellation via `withTaskCancellationHandler` (the
        // consumer's termination reached the producer before `prove` returned). What must never
        // happen is `prove` running to completion uncancelled — that's the bug this test guards
        // against (a producer without the `onTermination` wiring), and it still fails against that
        // regression: the spy would be invoked and never observe cancellation.
        let invoked = await awaitSignal(spy.invoked, timeout: .milliseconds(100))
        var observedCancellation = false
        if invoked {
            observedCancellation = await awaitSignal(spy.cancelledObserved, timeout: .milliseconds(100))
        }
        #expect(!invoked || observedCancellation)
        #expect(events.values.isEmpty)
    }
}

/// Spy standing in for the delegation-proving backend call inside `makeDelegationProofStream`.
/// `.succeedsImmediately` returns canned progress and a canned proof without ever suspending;
/// `.parksUntilCancelled` suspends until the task running it is cancelled, so a test can observe
/// whether that cancellation actually reaches code already inside the seam's `prove` closure.
private final class DelegationProofSpy: @unchecked Sendable {
    enum Behavior {
        case succeedsImmediately(progress: [Double], proof: Data)
        case parksUntilCancelled
    }

    /// Opens the instant `prove` starts running.
    let invoked = ResumableGate()
    /// Opens if and only if `prove`'s `withTaskCancellationHandler` observed cancellation.
    let cancelledObserved = ResumableGate()

    private let behavior: Behavior
    private let parkedContinuation = OSAllocatedUnfairLock<CheckedContinuation<Data, Error>?>(initialState: nil)

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func prove(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        invoked.open()
        switch behavior {
        case .succeedsImmediately(let progressValues, let proof):
            progressValues.forEach { progress($0) }
            return proof
        case .parksUntilCancelled:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    parkedContinuation.withLock { $0 = continuation }
                }
            } onCancel: {
                cancelledObserved.open()
                let pending = parkedContinuation.withLock { state -> CheckedContinuation<Data, Error>? in
                    let value = state
                    state = nil
                    return value
                }
                pending?.resume(throwing: CancellationError())
            }
        }
    }
}

/// Awaits `gate` and a `timeout` concurrently, returning `true` if the gate opened first and
/// `false` if the timeout elapsed first. Keeps a positive wait event-driven — it resolves the
/// instant the gate opens rather than always paying the full timeout — while still bounding how
/// long a genuine regression (cancellation never observed, or observed when it should not be) can
/// hang the test.
private func awaitSignal(_ gate: ResumableGate, timeout: Duration) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        let resumeOnce: @Sendable (Bool) -> Void = { value in
            let shouldResume = hasResumed.withLock { alreadyResumed -> Bool in
                guard !alreadyResumed else { return false }
                alreadyResumed = true
                return true
            }
            if shouldResume {
                continuation.resume(returning: value)
            }
        }
        Task {
            await gate.wait()
            resumeOnce(true)
        }
        Task {
            try? await Task.sleep(for: timeout)
            resumeOnce(false)
        }
    }
}
#endif
