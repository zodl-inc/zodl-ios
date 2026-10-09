#if VOTING_ENABLED
import Foundation
import Testing
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

/// What `sessionStream` promises about ending.
///
/// The one that matters is the asymmetry: a call that finishes on its own must
/// never reach the cancellation closure, because the SDK's session cancellation
/// is permanent and would finish a round that had just completed one run and
/// may still owe another. Only a consumer that walked away may trigger it, and
/// then exactly once.
@Suite struct VotingCryptoClientLiveKeyStreamTests {
    private enum Element: Equatable, Sendable {
        case event(Int)
        case report(Int)
    }

    @Test func aCallThatFinishesOnItsOwnNeverCancelsTheSession() async throws {
        let recorder = Recorder()

        // Repeated, because what this guards against is a scheduling race: a
        // termination handler installed after the call has already finished the
        // continuation is invoked at once, and with `.cancelled`. One pass can
        // miss the window; two hundred rarely do.
        for _ in 0..<200 {
            let stream = VotingCryptoClient.sessionStream(
                cancelling: { await recorder.recordCancellation() },
                call: { report in
                    report(1)
                    report(2)
                    return 7
                },
                event: Element.event,
                report: Element.report
            )

            var elements: [Element] = []
            for try await element in stream {
                elements.append(element)
            }

            #expect(elements == [.event(1), .event(2), .report(7)])
        }

        // The cancellation closure runs on a task of its own, so give any that
        // was wrongly triggered time to land before reading the tally.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.cancellations == 0)
    }

    @Test func aConsumerThatCancelsItsTaskCancelsTheSessionOnce() async throws {
        let recorder = Recorder()
        let stream = VotingCryptoClient.sessionStream(
            cancelling: { await recorder.recordCancellation() },
            call: { report in
                report(1)
                // Long enough that only the consumer's cancellation can end this.
                try await Task.sleep(for: .seconds(30))
                return 0
            },
            event: Element.event,
            report: Element.report
        )

        let consumer = Task {
            for try await _ in stream {
                await recorder.recordElement()
            }
        }

        try await VotingCryptoClientLiveKeyStreamTests.wait { await recorder.elements == 1 }
        consumer.cancel()

        try await VotingCryptoClientLiveKeyStreamTests.wait { await recorder.cancellations == 1 }
        // And it stays at one: a second termination must not reach the session.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.cancellations == 1)
    }

    @Test func anErrorFromTheCallReachesTheConsumerWithoutCancelling() async throws {
        let recorder = Recorder()
        let stream = VotingCryptoClient.sessionStream(
            cancelling: { await recorder.recordCancellation() },
            call: { (_: @Sendable (Int) -> Void) -> Int in
                throw VotingError(kind: .storage, message: "call refused")
            },
            event: Element.event,
            report: Element.report
        )

        var thrown: Error?
        do {
            for try await _ in stream {
                Issue.record("a refused call must yield nothing")
            }
        } catch {
            thrown = error
        }

        #expect((thrown as? VotingError)?.kind == .storage)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.cancellations == 0)
    }

    /// Polls `condition` until it holds, and fails the test rather than hanging
    /// if it never does.
    private static func wait(
        for condition: @Sendable () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("condition never held", sourceLocation: sourceLocation)
    }

    private actor Recorder {
        private(set) var cancellations = 0
        private(set) var elements = 0

        func recordCancellation() {
            cancellations += 1
        }

        func recordElement() {
            elements += 1
        }
    }
}
#endif
