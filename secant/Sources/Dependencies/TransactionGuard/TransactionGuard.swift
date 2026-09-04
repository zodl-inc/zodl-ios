//
//  TransactionGuard.swift
//  Zashi
//

import Foundation

/// A fair (FIFO) async mutex shared between server switches and transaction submissions so the two
/// can never overlap. The SDK's `switchTo(endpoint:)` tears down and rebuilds the synchronizer and
/// is unsafe while a transaction is being broadcast, so a submission and a switch must be exclusive.
actor TransactionGuard {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    /// Wait until the guard is free, then take it. Callers must `release()` when done.
    /// Cancellation-aware: a task cancelled while parked here is removed from the queue and
    /// resumes by throwing `CancellationError` without taking the guard — so a hung holder can
    /// never wedge a waiter indefinitely.
    func acquire() async throws {
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before we parked: don't enqueue a doomed waiter.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
            // Ownership was handed to us by `release()`; `isBusy` is already true.
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Wait until the guard is free, but give up after `timeout` and throw `TransactionGuardBusyError`
    /// instead of parking indefinitely. Used by the send paths, where an unbounded wait behind an
    /// unrelated network operation reads to the user as a frozen app.
    ///
    /// The deadline is enforced from *inside* the actor rather than by racing `acquire()` against
    /// `withTimeout` from outside: every state change (enqueue, hand-off, deadline, cancellation)
    /// happens under actor isolation, so the deadline can only ever observe a waiter that is still
    /// queued or one that is already gone. It can never see a half-completed hand-off, and so can
    /// never abandon ownership that `release()` has just transferred to it.
    func acquire(timeout: Duration) async throws {
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        // Unstructured on purpose: it must outlive the continuation below and does not inherit the
        // caller's cancellation, which `withTaskCancellationHandler` already handles separately.
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // Cancelled because the acquisition already settled; nothing to time out.
                return
            }
            await self.timeOutWaiter(id)
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before we parked: don't enqueue a doomed waiter.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
            // Ownership was handed to us by `release()`; `isBusy` is already true.
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Take the guard only if it is free right now; never waits. Returns `false` if busy.
    func tryAcquire() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    /// Release the guard, handing ownership to the next waiter (FIFO) if there is one.
    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume() // `isBusy` stays true — ownership transfers to the resumed waiter.
        }
    }

    /// Resume a still-parked waiter that was cancelled, throwing `CancellationError`. A no-op if
    /// `release()` already handed it ownership (it is no longer in the queue), so the guard's
    /// `isBusy` state is left untouched — the cancelled waiter never owned it.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Resume a still-parked waiter whose deadline expired, throwing `TransactionGuardBusyError`.
    /// A no-op when the waiter is no longer queued, which means `release()` won the race and already
    /// handed it ownership — that acquirer proceeds normally and releases as usual, so an expired
    /// deadline can never strand the guard. Removing the waiter here leaves `isBusy` untouched
    /// because the timed-out waiter never owned the guard.
    private func timeOutWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: TransactionGuardBusyError())
    }
}

/// Thrown by `acquire(timeout:)` when the guard could not be taken within its deadline. Surfaced to
/// the user, so its description comes from the string catalogue rather than being hard-coded.
struct TransactionGuardBusyError: LocalizedError {
    var errorDescription: String? {
        String(localizable: .transactionGuardBusy)
    }
}

/// Error thrown by `withTimeout` when `operation` does not finish within the deadline.
struct TransactionTimeoutError: Error {}

/// Default deadline for a server switch. `switchTo` does stop → validate-over-Tor → start; the
/// validation has its own 5s single-call timeout, but `start()` and Tor circuit setup have no
/// Swift-level deadline. On expiry `withTimeout` *cancels* `switchTo`; the guard is released only
/// once `switchTo` actually returns. If `switchTo` ignored cancellation and hung, the guard would
/// stay held — a deliberate trade-off that favours switch/submission exclusivity over liveness:
/// abandoning a half-applied switch could race a submission against a synchronizer still being rebuilt.
let serverSwitchTimeout: Duration = .seconds(60)

/// Deadline for *taking* the guard on a send. Only the acquisition is bounded — a broadcast that
/// already owns the guard is never cut short. Long enough to queue behind a normal broadcast, short
/// enough that a wedged holder surfaces as a failed send the user can retry instead of a screen that
/// appears to have frozen. Nothing has been broadcast when it expires, so retrying is always safe.
let submissionGuardTimeout: Duration = .seconds(30)

/// Race `operation` against a `duration` timer; whichever finishes first wins and the loser is
/// *cancelled* (a cancellation request, not a forced stop). Throws `TransactionTimeoutError` when
/// the timer wins.
///
/// Caveat: this is a structured task group, so it returns only once *both* children have finished.
/// If `operation` ignores cancellation and never returns, neither does this call — a hard deadline
/// is only achievable when `operation` is cancellation-aware.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TransactionTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TransactionTimeoutError()
        }
        return result
    }
}
