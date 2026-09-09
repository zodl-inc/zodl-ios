//
//  TestSignals.swift
//  zodlTests
//
//  Event-driven wait primitives for test spies — the replacement for polling `LockIsolated`
//  spies against wall-clock deadlines (the retired `waitUntil` helpers), which lose to starved
//  CI runners: see MigrationSweepBannerFreshnessTests' header for the observed failures and the
//  pattern's history. `MigrationSyncCompleteEdgeTests`' AsyncStream spy is the same idea for a
//  first-occurrence wait; these types cover the general case — multiple sequential awaits over
//  one spy's whole history, and gates mocked closures park on.
//
//  The waits here have NO deadline, deliberately: they scale with however long the awaited work
//  actually takes under load. A suite adopting them should carry `.timeLimit` so a wait that
//  genuinely never fires is RECORDED as a failure instead of running until the CI job's own
//  timeout.
//

import Foundation
import os

/// Spy storage whose writes resume awaiting readers. `record(_:)` appends and resumes every
/// waiter whose predicate the updated history now satisfies; `recorded(where:)` checks and
/// registers under the SAME lock the writer takes, so a record landing between "check" and
/// "register" can never strand a waiter (the `awaitSnapshotRepublishIdle` discipline).
/// Predicates run under that lock — keep them cheap and side-effect free.
final class SignalledRecords<Element: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let predicate: @Sendable ([Element]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let state: OSAllocatedUnfairLock<(records: [Element], waiters: [Waiter])>

    init() {
        state = OSAllocatedUnfairLock(uncheckedState: (records: [], waiters: []))
    }

    var values: [Element] { state.withLockUnchecked { $0.records } }
    var count: Int { state.withLockUnchecked { $0.records.count } }
    var isEmpty: Bool { state.withLockUnchecked { $0.records.isEmpty } }

    /// Appends `element`, resumes every waiter the updated history now satisfies, and returns
    /// the new record count (this call's ordinal, for mocks that branch on it).
    @discardableResult
    func record(_ element: Element) -> Int {
        let (resumed, count) = state.withLockUnchecked { state -> ([CheckedContinuation<Void, Never>], Int) in
            state.records.append(element)
            let records = state.records
            var kept: [Waiter] = []
            var satisfied: [CheckedContinuation<Void, Never>] = []
            for waiter in state.waiters {
                if waiter.predicate(records) {
                    satisfied.append(waiter.continuation)
                } else {
                    kept.append(waiter)
                }
            }
            state.waiters = kept
            return (satisfied, records.count)
        }
        resumed.forEach { $0.resume() }
        return count
    }

    /// Suspends until the recorded history satisfies `predicate` — resumed by the `record` call
    /// that makes it true, immediately if it already does.
    func recorded(where predicate: @escaping @Sendable ([Element]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadySatisfied = state.withLockUnchecked { state -> Bool in
                if predicate(state.records) {
                    return true
                }
                state.waiters.append(Waiter(predicate: predicate, continuation: continuation))
                return false
            }
            if alreadySatisfied {
                continuation.resume()
            }
        }
    }

    /// Suspends until at least `threshold` records exist.
    func countReached(_ threshold: Int) async {
        await recorded(where: { $0.count >= threshold })
    }
}

extension SignalledRecords where Element == Void {
    /// Counter sugar for spies that only count calls — returns this call's ordinal.
    @discardableResult
    func recordCall() -> Int {
        record(())
    }
}

/// A latching gate mocked closures park on: `wait()` suspends until `open()`, and once opened,
/// later waits return immediately. Replaces `while !flag.value { try? await Task.sleep(...) }`
/// busy-polls inside mocks, which burn the very cooperative pool a loaded test run is starving.
final class ResumableGate: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>

    init() {
        state = OSAllocatedUnfairLock(uncheckedState: (isOpen: false, waiters: []))
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLockUnchecked { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if isOpen {
                continuation.resume()
            }
        }
    }

    func open() {
        let resumed = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        resumed.forEach { $0.resume() }
    }
}
