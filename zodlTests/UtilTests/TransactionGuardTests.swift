import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Several tests drive the shared `TransactionGuardClient.liveValue`, which is backed by a single
// process-global mutex actor. They must not run concurrently or they would contend on that guard,
// so the suite is serialized (matching XCTest's previous serial execution).
@Suite(.serialized) struct TransactionGuardTests {
    private var endpointA: LightWalletEndpoint { LightWalletEndpoint(address: "endpoint-a.test", port: 9067) }

    @Test func tryAcquireFailsWhileHeld() async {
        let guardActor = TransactionGuard()
        try? await guardActor.acquire()
        let acquired = await guardActor.tryAcquire()
        #expect(!acquired, "tryAcquire must fail while the guard is held")
        await guardActor.release()
        let acquiredAfter = await guardActor.tryAcquire()
        #expect(acquiredAfter, "tryAcquire must succeed after release")
    }

    @Test func switchIsSkippedWhileSubmissionActive() async {
        let client = TransactionGuardClient.liveValue
        let submissionStarted = AsyncBox()
        let releaseSubmission = AsyncBox()

        let submission = Task {
            try await client.withSubmission {
                await submissionStarted.signal()
                await releaseSubmission.wait()
            }
        }

        await submissionStarted.wait()
        let didSwitch = try? await client.switchIfIdle { /* would switch here */ }
        #expect(didSwitch == false, "Auto switch must skip while a submission is active")

        await releaseSubmission.signal()
        _ = try? await submission.value

        let didSwitchAfter = try? await client.switchIfIdle { }
        #expect(didSwitchAfter == true, "Auto switch must run once the submission finished")
    }

    @Test func manualSwitchWaitsForSubmission() async {
        let client = TransactionGuardClient.liveValue
        let order = OrderRecorder()
        let submissionStarted = AsyncBox()
        let releaseSubmission = AsyncBox()

        let submission = Task {
            try await client.withSubmission {
                await submissionStarted.signal()
                await releaseSubmission.wait()
                await order.record("submission-end")
            }
        }
        await submissionStarted.wait()

        let manual = Task {
            try await client.switchWaiting {
                await order.record("switch")
            }
        }

        // Give the manual switch a moment to park on the guard, then let the submission finish.
        try? await Task.sleep(for: .milliseconds(50))
        await releaseSubmission.signal()
        _ = try? await submission.value
        _ = try? await manual.value

        let recorded = await order.values
        #expect(recorded == ["submission-end", "switch"], "Manual switch must wait for the submission")
    }

    @Test func parkedSubmissionCancelledDoesNotRunBody() async {
        let client = TransactionGuardClient.liveValue
        let holderAcquired = AsyncBox()
        let releaseHolder = AsyncBox()
        let bodyRan = BoolBox()

        // A holder takes the guard and waits, forcing the next acquirer to park.
        let holder = Task {
            try await client.withSubmission {
                await holderAcquired.signal()
                await releaseHolder.wait()
            }
        }
        await holderAcquired.wait()

        // A second submission parks in acquire(); once cancelled its body must NOT run.
        let parked = Task {
            try await client.withSubmission {
                bodyRan.value = true
            }
        }

        // Let it park on the guard, then cancel it.
        try? await Task.sleep(for: .milliseconds(50))
        parked.cancel()

        // Release the holder; the parked task is resumed but should bail on cancellation.
        await releaseHolder.signal()
        _ = try? await holder.value
        _ = try? await parked.value

        #expect(!bodyRan.value, "A cancelled, parked submission must not run its body")
    }

    @Test func parkedAcquireUnblocksOnCancellationEvenIfHolderNeverReleases() async {
        let guardActor = TransactionGuard()
        // Holder takes the guard and never releases — simulates a hung switch.
        try? await guardActor.acquire()

        let parkedStarted = AsyncBox()
        let parked = Task { () -> Bool in
            await parkedStarted.signal()
            do {
                try await guardActor.acquire()
                return false // acquired — must not happen while the guard is held
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await parkedStarted.wait()
        try? await Task.sleep(for: .milliseconds(50)) // let it park in acquire()
        parked.cancel()

        let unblockedByCancellation = await parked.value
        #expect(
            unblockedByCancellation,
            "A parked acquire() must throw CancellationError when cancelled, even if the holder never releases"
        )
        // Cancelling the waiter must not have released the holder's guard.
        let stillHeld = await guardActor.tryAcquire()
        #expect(!stillHeld, "Cancelling a waiter must not release the guard held by another task")
    }

    @Test func withTimeoutThrowsWhenOperationExceedsDeadline() async {
        // Cooperative case only: Task.sleep honors cancellation, so withTimeout can return and throw.
        // A non-cancellable operation would not surface the timeout (see withTimeout / serverSwitchTimeout).
        do {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
            }
            Issue.record("withTimeout should have thrown TransactionTimeoutError")
        } catch is TransactionTimeoutError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func withTimeoutReturnsValueWhenOperationFinishesInTime() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func switchWaitingReleasesGuardWhenSwitchTimesOut() async {
        let client = TransactionGuardClient.liveValue
        // A *cancellation-aware* switch body (Task.sleep) that overruns its timeout must release the
        // guard, not wedge it. This holds only because Task.sleep honors cancellation; a body that
        // ignored it would keep withTimeout (a structured task group) from returning and the guard
        // would stay held. See serverSwitchTimeout for why that trade-off is intentional.
        let timedOut: Void? = try? await client.switchWaiting {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
            }
        }
        #expect(timedOut == nil, "switchWaiting must rethrow the timeout")

        let didSwitch = try? await client.switchIfIdle { }
        #expect(didSwitch == true, "Guard must be free after a timed-out switch")
    }

    // MARK: - Acquisition timeout

    @Test func timedAcquireTakesAFreeGuardImmediately() async throws {
        let guardActor = TransactionGuard()
        try await guardActor.acquire(timeout: .milliseconds(50))
        let stillFree = await guardActor.tryAcquire()
        #expect(!stillFree, "A timed acquire on a free guard must take ownership")
        await guardActor.release()
        let freeAfterRelease = await guardActor.tryAcquire()
        #expect(freeAfterRelease, "The guard must be free again once the timed acquirer releases")
    }

    @Test func timedSubmissionThrowsBusyWhileTheGuardIsHeld() async {
        let guardActor = TransactionGuard()
        let client = Self.client(over: guardActor)
        let holderAcquired = AsyncBox()
        let releaseHolder = AsyncBox()
        let bodyRan = BoolBox()

        let holder = Task {
            try await client.withSubmission {
                await holderAcquired.signal()
                await releaseHolder.wait()
            }
        }
        await holderAcquired.wait()

        var caught: Error?
        do {
            try await client.withSubmission(timeout: .milliseconds(100)) {
                bodyRan.value = true
            }
        } catch {
            caught = error
        }

        #expect(caught is TransactionGuardBusyError, "A busy guard must surface TransactionGuardBusyError, got \(String(describing: caught))")
        #expect(!bodyRan.value, "The submission body must not run when the guard could not be acquired")

        // The timed-out acquirer must not have taken ownership it then dropped.
        await releaseHolder.signal()
        _ = try? await holder.value

        let secondAttempt: Void? = try? await client.withSubmission(timeout: .milliseconds(500)) { }
        #expect(secondAttempt != nil, "A fresh timed submission must succeed once the holder released")
    }

    @Test func timeoutRacingAReleaseNeverLeavesTheGuardHeld() async {
        let guardActor = TransactionGuard()
        let client = Self.client(over: guardActor)
        let holderAcquired = AsyncBox()

        // The holder releases at 90 ms while the contender's deadline is 100 ms: the hand-off and
        // the deadline are deliberately close enough that either can win.
        let holder = Task {
            try await client.withSubmission {
                await holderAcquired.signal()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
        await holderAcquired.wait()

        let contended: Void? = try? await client.withSubmission(timeout: .milliseconds(100)) { }
        _ = try? await holder.value
        _ = contended

        let free = await guardActor.tryAcquire()
        #expect(free, "Whichever of the deadline and the hand-off wins, the guard must end up free")
    }

    @Test func timedSubmissionReleasesTheGuardWhenItsBodyThrows() async {
        let guardActor = TransactionGuard()
        let client = Self.client(over: guardActor)

        let failed: Void? = try? await client.withSubmission(timeout: .seconds(1)) {
            throw TestFailure()
        }
        #expect(failed == nil, "withSubmission(timeout:) must rethrow the body's error")

        let free = await guardActor.tryAcquire()
        #expect(free, "A throwing body must still release the guard")
    }

    @Test func parkedTimedAcquireUnblocksOnCancellationBeforeItsDeadline() async {
        let guardActor = TransactionGuard()
        // Holder takes the guard and never releases — simulates a hung switch.
        try? await guardActor.acquire()

        let parkedStarted = AsyncBox()
        let parked = Task { () -> Bool in
            await parkedStarted.signal()
            do {
                try await guardActor.acquire(timeout: .seconds(10))
                return false // acquired — must not happen while the guard is held
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await parkedStarted.wait()
        try? await Task.sleep(for: .milliseconds(50)) // let it park in acquire(timeout:)
        parked.cancel()

        let unblockedByCancellation = await parked.value
        #expect(
            unblockedByCancellation,
            "A parked acquire(timeout:) must throw CancellationError when cancelled, well before its deadline"
        )
        let stillHeld = await guardActor.tryAcquire()
        #expect(!stillHeld, "Cancelling a timed waiter must not release the guard held by another task")
    }


    // MARK: - Guard scope on the send paths

    @Test func provingRunsToCompletionBeforeTheGuardIsAcquired() async throws {
        let log = OrderRecorder()
        let client = Self.recordingClient(into: log)

        let result = try await SDKSynchronizerClient.createThenSubmitUnderGuard(
            transactionGuard: client,
            timeout: .seconds(30),
            logPrefix: "[MultiSubmit]",
            intendedEndpoints: [],
            prove: {
                await log.record("prove-start")
                try await Task.sleep(for: .milliseconds(20))
                await log.record("prove-end")
                return []
            },
            submit: { _ in
                await log.record("submit")
                return SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: ["abc"])
            },
            release: { _, _ in await log.record("released") }
        )

        #expect(result == SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: ["abc"]))
        let recorded = await log.values
        #expect(
            recorded == ["prove-start", "prove-end", "acquire-timed", "submit", "release"],
            "Proving must finish before the guard is taken and the guard released after the broadcast; got \(recorded)"
        )
    }

    @Test func aBusyGuardFailsTheSendWithoutBroadcasting() async throws {
        let log = OrderRecorder()
        let client = TransactionGuardClient(
            acquire: { throw TransactionGuardBusyError() },
            acquireWithTimeout: { _ in throw TransactionGuardBusyError() },
            tryAcquire: { false },
            release: { await log.record("release") }
        )

        let result = try await SDKSynchronizerClient.createThenSubmitUnderGuard(
            transactionGuard: client,
            timeout: .milliseconds(10),
            logPrefix: "[MultiSubmit]",
            intendedEndpoints: [],
            prove: {
                await log.record("prove")
                return []
            },
            submit: { _ in
                await log.record("submit")
                return SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: [])
            },
            release: { _, _ in await log.record("released") }
        )

        #expect(
            result == SDKSynchronizerClient.CreateProposedTransactionsResult.failure(
                txIds: [],
                code: SDKSynchronizerClient.MultiServerSubmission.guardBusyCode,
                description: String(localizable: .transactionGuardBusy)
            ),
            "A busy guard must fail the send definitively, carrying the localized busy text; got \(result)"
        )
        let recorded = await log.values
        #expect(recorded == ["prove"], "Nothing may be broadcast, and no guard released, when the acquisition failed; got \(recorded)")
    }

    @Test func aFailedProofNeverTouchesTheGuard() async {
        let log = OrderRecorder()
        let client = Self.recordingClient(into: log)

        let result = try? await SDKSynchronizerClient.createThenSubmitUnderGuard(
            transactionGuard: client,
            timeout: .seconds(30),
            logPrefix: "[MultiSubmit]",
            intendedEndpoints: [],
            prove: { throw TestFailure() },
            submit: { _ in
                await log.record("submit")
                return SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: [])
            },
            release: { _, _ in await log.record("released") }
        )

        #expect(result == nil, "A proving failure must keep propagating to the caller")
        let recorded = await log.values
        #expect(recorded.isEmpty, "A send that never got past proving must not touch the guard; got \(recorded)")
    }

    // MARK: - Missed broadcast: release to background resubmission

    @Test func busyGuardAfterProvingReleasesTheCreatedTransactionsAndReportsThemPending() async throws {
        let created = [CreatedTransaction.fixture(0xAB), CreatedTransaction.fixture(0xCD)]
        let released = LockIsolated<[(txIds: [Data], endpoints: [LightWalletEndpoint])]>([])
        let submits = LockIsolated(0)

        let result = try await SDKSynchronizerClient.createThenSubmitUnderGuard(
            transactionGuard: Self.busyGuardClient(),
            timeout: .milliseconds(50),
            logPrefix: "[Test]",
            intendedEndpoints: [endpointA],
            prove: { created },
            submit: { _ in
                submits.withValue { $0 += 1 }
                return SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: [])
            },
            release: { transactions, endpoints in
                released.withValue { $0.append((transactions.map(\.txId), endpoints)) }
            }
        )

        #expect(submits.value == 0, "A guard that never granted access must not run the broadcast")
        #expect(released.value.count == 1)
        #expect(released.value.first?.txIds == created.map(\.txId))
        #expect(released.value.first?.endpoints == [endpointA])
        #expect(
            result == SDKSynchronizerClient.CreateProposedTransactionsResult.grpcFailure(
                txIds: created.map { $0.txId.toHexStringTxId() },
                reason: .guardBusy
            ),
            "A missed broadcast must report the created transactions as pending, not a plain failure; got \(result)"
        )
    }

    @Test func cancellationAfterProvingReleasesTheCreatedTransactions() async throws {
        // `CreatedTransaction` carries no Sendable guarantee across the module boundary, so it is
        // constructed fresh inside the unstructured `Task` below rather than captured from an
        // outer `let` — a value crossing into `Task.init`'s `@Sendable` closure must not alias a
        // non-Sendable capture. The expected txId (`Data([0xEF])`) mirrors `.fixture(0xEF)`.
        let released = LockIsolated<[[Data]]>([])
        let parked = AsyncBox()

        // `acquireWithTimeout` never returns on its own; only cancelling the surrounding Task can
        // unblock it, via `Task.sleep`'s own cancellation handling.
        let client = TransactionGuardClient(
            acquire: {
                Issue.record("The submission seam must acquire the guard with a timeout, never the unbounded acquire.")
            },
            acquireWithTimeout: { _ in
                await parked.signal()
                try await Task.sleep(for: .seconds(999))
            },
            tryAcquire: { true },
            release: { }
        )

        let task = Task {
            try await SDKSynchronizerClient.createThenSubmitUnderGuard(
                transactionGuard: client,
                timeout: .seconds(30),
                logPrefix: "[Test]",
                intendedEndpoints: [],
                prove: { [CreatedTransaction.fixture(0xEF)] },
                submit: { _ in SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: []) },
                release: { transactions, _ in released.withValue { $0.append(transactions.map(\.txId)) } }
            )
        }

        await parked.wait()
        task.cancel()
        _ = try? await task.value

        #expect(
            released.value == [[Data([0xEF])]],
            "A send cancelled while parked on the guard must still hand its created transactions to background resubmission"
        )
    }

    @Test func emptyProveResultKeepsTheFailureShape() async throws {
        let releaseCallCount = LockIsolated(0)

        let result = try await SDKSynchronizerClient.createThenSubmitUnderGuard(
            transactionGuard: Self.busyGuardClient(),
            timeout: .milliseconds(50),
            logPrefix: "[Test]",
            intendedEndpoints: [endpointA],
            prove: { [] },
            submit: { _ in SDKSynchronizerClient.CreateProposedTransactionsResult.success(txIds: []) },
            release: { _, _ in releaseCallCount.withValue { $0 += 1 } }
        )

        #expect(
            result == SDKSynchronizerClient.CreateProposedTransactionsResult.failure(
                txIds: [],
                code: SDKSynchronizerClient.MultiServerSubmission.guardBusyCode,
                description: String(localizable: .transactionGuardBusy)
            ),
            "With nothing created there is nothing to release, so the definitive failure shape is unchanged; got \(result)"
        )
        #expect(releaseCallCount.value == 0, "An empty prove result must never call release")
    }

    /// A pass-through client that logs every guard interaction, so a test can assert *when* the
    /// guard is taken relative to the work around it. `acquire` and `acquireWithTimeout` record
    /// distinct labels so a test can tell which one the seam actually called — without that, a
    /// seam that regressed to the unbounded `withSubmission(_:)` (and so the plain `acquire`)
    /// would still satisfy an ordering assertion written against a single shared "acquire" label.
    /// The submission seam must never call the unbounded `acquire`, so that closure also records
    /// an `Issue` — a belt-and-braces signal alongside the ordering mismatch it also causes.
    private static func recordingClient(into log: OrderRecorder) -> TransactionGuardClient {
        TransactionGuardClient(
            acquire: {
                Issue.record("The submission seam must acquire the guard with a timeout, never the unbounded acquire.")
                await log.record("acquire")
            },
            acquireWithTimeout: { _ in await log.record("acquire-timed") },
            tryAcquire: { true },
            release: { await log.record("release") }
        )
    }

    /// A client wired over a test-local actor, so a timing-sensitive test never contends with the
    /// process-global `liveValue` guard.
    private static func client(over guardActor: TransactionGuard) -> TransactionGuardClient {
        TransactionGuardClient(
            acquire: { try await guardActor.acquire() },
            acquireWithTimeout: { try await guardActor.acquire(timeout: $0) },
            tryAcquire: { await guardActor.tryAcquire() },
            release: { await guardActor.release() }
        )
    }

    /// A client whose timed acquire always reports the guard as busy without ever taking it —
    /// matches what a real `TransactionGuard` does once `acquire(timeout:)`'s deadline passes.
    private static func busyGuardClient() -> TransactionGuardClient {
        TransactionGuardClient(
            acquire: { throw TransactionGuardBusyError() },
            acquireWithTimeout: { _ in throw TransactionGuardBusyError() },
            tryAcquire: { false },
            release: { }
        )
    }
}

/// Minimal async one-shot signal for ordering test steps.
private actor AsyncBox {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signaled = true
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class BoolBox: @unchecked Sendable {
    var value = false
}

private struct TestFailure: Error {}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private extension CreatedTransaction {
    /// A minimal, distinguishable transaction for seam tests: `txId` and `raw` both derive from
    /// `byte` so a test can tell fixtures apart without caring about real transaction encoding.
    static func fixture(_ byte: UInt8) -> CreatedTransaction {
        CreatedTransaction(txId: Data([byte]), raw: Data([byte, byte]), expiryHeight: nil)
    }
}
