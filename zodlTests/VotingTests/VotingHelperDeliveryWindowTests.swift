#if VOTING_ENABLED
import Foundation
import os
import Testing
@testable import zodl_internal

@Suite(.timeLimit(.minutes(3)))
struct VotingHelperDeliveryWindowTests {
    @Test func thirdAdmissionWaitsForOldestAndNeverExceedsCapacity() async throws {
        let tracker = DeliveryActivityTracker()
        let firstGate = ResumableGate()
        let secondGate = ResumableGate()
        let thirdGate = ResumableGate()
        let thirdAttempted = SignalledRecords<Void>()
        let identities = deliveryIdentities(count: 3)
        let window = VotingHelperDeliveryWindow<String>()

        try await window.enqueue(identity: identities[0]) {
            try await tracker.run(identities[0], gate: firstGate)
        }
        try await window.enqueue(identity: identities[1]) {
            try await tracker.run(identities[1], gate: secondGate)
        }
        await tracker.started.countReached(2)
        let thirdAdmission = Task {
            thirdAttempted.recordCall()
            try await window.enqueue(identity: identities[2]) {
                try await tracker.run(identities[2], gate: thirdGate)
            }
        }
        await thirdAttempted.countReached(1)
        #expect(Set(tracker.started.values) == Set([identities[0], identities[1]]))

        firstGate.open()
        await tracker.started.countReached(3)
        try await thirdAdmission.value
        #expect(tracker.started.values.last == identities[2])
        #expect(tracker.maximumActive == 2)

        secondGate.open()
        thirdGate.open()
        let reports = try await window.drain()
        #expect(Set(reports.keys) == Set(identities))
    }

    @Test func olderFailureIsAttributedToItsIdentityWithoutRejectingNewAdmission() async throws {
        let firstGate = ResumableGate()
        let secondGate = ResumableGate()
        let thirdEntered = SignalledRecords<Void>()
        let identities = deliveryIdentities(count: 3)
        let window = VotingHelperDeliveryWindow<String>()

        try await window.enqueue(identity: identities[0]) {
            await firstGate.wait()
            throw DeliveryTestError.rejected
        }
        try await window.enqueue(identity: identities[1]) {
            await secondGate.wait()
            return acceptedReport(for: identities[1])
        }
        let thirdAdmission = Task {
            try await window.enqueue(identity: identities[2]) {
                thirdEntered.recordCall()
                return acceptedReport(for: identities[2])
            }
        }

        firstGate.open()
        await thirdEntered.countReached(1)
        try await thirdAdmission.value
        secondGate.open()

        do {
            _ = try await window.drain()
            Issue.record("Expected the older delivery failure to be retained")
        } catch let error as VotingShareDeliveryAggregateError<String> {
            #expect(Set(error.failures.keys) == Set([identities[0]]))
            #expect(error.failures[identities[0]] as? DeliveryTestError == .rejected)
            #expect(Set(error.successfulReports.keys) == Set([identities[1], identities[2]]))
        }
    }

    @Test func cancelAndDrainCancelsAndJoinsEveryOwnedOperation() async throws {
        let identities = deliveryIdentities(count: 3)
        let entered = SignalledRecords<VotingShareDeliveryIdentity>()
        let cancelled = SignalledRecords<VotingShareDeliveryIdentity>()
        let finished = SignalledRecords<VotingShareDeliveryIdentity>()
        let thirdAdmissionAttempted = SignalledRecords<Void>()
        let gates = [ResumableGate(), ResumableGate()]
        let window = VotingHelperDeliveryWindow<String>()

        for (index, identity) in identities.prefix(2).enumerated() {
            try await window.enqueue(identity: identity) {
                entered.record(identity)
                defer { finished.record(identity) }
                await withTaskCancellationHandler {
                    await gates[index].wait()
                } onCancel: {
                    cancelled.record(identity)
                    gates[index].open()
                }
                try Task.checkCancellation()
                return acceptedReport(for: identity)
            }
        }
        await entered.countReached(2)
        let thirdAdmission = Task {
            thirdAdmissionAttempted.recordCall()
            try await window.enqueue(identity: identities[2]) {
                Issue.record("A fenced admission started after cancellation")
                return acceptedReport(for: identities[2])
            }
        }
        await thirdAdmissionAttempted.countReached(1)

        await window.cancelAndDrain()

        #expect(Set(cancelled.values) == Set(identities.prefix(2)))
        #expect(Set(finished.values) == Set(identities.prefix(2)))
        await #expect(throws: CancellationError.self) { try await thirdAdmission.value }
        await #expect(throws: CancellationError.self) {
            try await window.enqueue(identity: identities[0]) {
                acceptedReport(for: identities[0])
            }
        }
    }

    @Test func serverPoolTracksCurrentURLsAndIsExhaustedOnlyWhenEmpty() async {
        let pool = VotingShareServerPool(urls: ["https://helper-a.example", "https://helper-b.example"])

        #expect(await pool.current() == ["https://helper-a.example", "https://helper-b.example"])
        #expect(await pool.isExhausted == false)

        await pool.prune(to: ["https://helper-b.example"])
        #expect(await pool.current() == ["https://helper-b.example"])
        #expect(await pool.isExhausted == false)

        await pool.prune(to: [])
        #expect(await pool.current().isEmpty)
        #expect(await pool.isExhausted == true)
    }

    /// A delivery's remaining list is a snapshot of the pool it read when it started, so a late
    /// result must never put back what a later failure removed — least of all refill a pool that
    /// ran dry, which would reopen bundle admission and the broadcast gate against servers the
    /// batch already gave up on.
    @Test func aStaleResultCannotRefillAnExhaustedPool() async {
        let pool = VotingShareServerPool(urls: ["https://helper-a.example", "https://helper-b.example"])

        await pool.prune(to: [])
        #expect(await pool.isExhausted == true)

        await pool.prune(to: ["https://helper-a.example", "https://helper-b.example"])
        #expect(await pool.current().isEmpty)
        #expect(await pool.isExhausted == true)
    }

    @Test func aStaleResultCannotRestoreARemovedServer() async {
        let pool = VotingShareServerPool(urls: ["https://helper-a.example", "https://helper-b.example"])

        await pool.prune(to: ["https://helper-b.example"])
        await pool.prune(to: ["https://helper-a.example", "https://helper-b.example"])

        #expect(await pool.current() == ["https://helper-b.example"])
        #expect(await pool.isExhausted == false)
    }

    @Test func pruningKeepsThePoolsOwnOrder() async {
        let pool = VotingShareServerPool(urls: [
            "https://helper-a.example", "https://helper-b.example", "https://helper-c.example"
        ])

        await pool.prune(to: ["https://helper-c.example", "https://helper-a.example"])

        #expect(await pool.current() == ["https://helper-a.example", "https://helper-c.example"])
    }

    private func deliveryIdentities(count: Int) -> [VotingShareDeliveryIdentity] {
        (0..<count).map { index in
            VotingShareDeliveryIdentity(roundId: "round", bundleIndex: 0, proposalId: UInt32(index))
        }
    }
}

private func acceptedReport(for identity: VotingShareDeliveryIdentity) -> String {
    "accepted-\(identity.proposalId)"
}

private enum DeliveryTestError: Error, Equatable {
    case rejected
}

private final class DeliveryActivityTracker: @unchecked Sendable {
    let started = SignalledRecords<VotingShareDeliveryIdentity>()
    private let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0))

    var maximumActive: Int { state.withLock { $0.maximum } }

    func run(
        _ identity: VotingShareDeliveryIdentity,
        gate: ResumableGate
    ) async throws -> String {
        state.withLock { value in
            value.active += 1
            value.maximum = max(value.maximum, value.active)
        }
        started.record(identity)
        await gate.wait()
        state.withLock { $0.active -= 1 }
        return acceptedReport(for: identity)
    }
}
#endif
