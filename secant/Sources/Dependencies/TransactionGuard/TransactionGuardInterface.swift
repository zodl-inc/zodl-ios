//
//  TransactionGuardInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture

extension DependencyValues {
    var transactionGuard: TransactionGuardClient {
        get { self[TransactionGuardClient.self] }
        set { self[TransactionGuardClient.self] = newValue }
    }
}

@DependencyClient
struct TransactionGuardClient {
    var acquire: @Sendable () async throws -> Void
    // Deliberately left without a default, exactly like `acquire`: the macro-synthesized default
    // throws, so an override that forgets to wire it fails the submission loudly instead of
    // silently running a broadcast outside the guard.
    var acquireWithTimeout: @Sendable (Duration) async throws -> Void
    // Default to `false` so a partial override that wires `acquire`/`release` but forgets
    // `tryAcquire` makes `switchIfIdle` a safe no-op rather than releasing a guard it never took.
    var tryAcquire: @Sendable () async -> Bool = { false }
    var release: @Sendable () async -> Void
}

extension TransactionGuardClient {
    /// Run a network submission with exclusive access. Blocks any server switch for its duration,
    /// and waits for an in-flight switch to finish first.
    func withSubmission<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        if Task.isCancelled {
            await release()
            throw CancellationError()
        }
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    /// Like `withSubmission(_:)`, but gives up waiting for the guard after `timeout` and throws
    /// `TransactionGuardBusyError` without running `body`. Used where an unbounded wait would look
    /// to the user like a frozen screen; the guard is released on every path that actually took it.
    func withSubmission<T>(timeout: Duration, _ body: () async throws -> T) async throws -> T {
        // A thrown acquisition error means the guard was never taken, so it must not be released.
        try await acquireWithTimeout(timeout)
        if Task.isCancelled {
            await release()
            throw CancellationError()
        }
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    /// Run a server switch only if nothing else holds the guard. Returns `true` if it ran,
    /// `false` if it was skipped because a submission/switch was active. Used by automatic refresh.
    func switchIfIdle(_ body: () async throws -> Void) async rethrows -> Bool {
        guard await tryAcquire() else { return false }
        do {
            try await body()
            await release()
            return true
        } catch {
            await release()
            throw error
        }
    }

    /// Run a server switch, waiting for any active submission/switch to finish first. Used by the
    /// manual Save so an explicit user choice always wins. Identical to `withSubmission` (the guard
    /// is symmetric); kept as a named alias so call sites read as a switch rather than a submission.
    func switchWaiting(_ body: () async throws -> Void) async throws {
        try await withSubmission(body)
    }
}
