#if VOTING_ENABLED
//
//  VotingHelperDeliveryWindow.swift
//  Zashi
//

import Foundation

/// Identifies one helper-share delivery within a batch: which round and bundle it belongs to,
/// and which proposal it carries a tally share for.
struct VotingShareDeliveryIdentity: Hashable, Sendable {
    let roundId: String
    let bundleIndex: UInt32
    let proposalId: UInt32
}

/// Thrown by `VotingHelperDeliveryWindow.drain()` when at least one enqueued delivery failed.
/// Carries both the reports that did succeed and, per identity, the error each failure threw —
/// nothing is discarded, so a caller can retry or surface exactly the failing identities.
struct VotingShareDeliveryAggregateError<Report: Sendable>: Error {
    let successfulReports: [VotingShareDeliveryIdentity: Report]
    let failures: [VotingShareDeliveryIdentity: Error]
}

/// Bounds how many helper-share delivery operations run at once while one batch of proposals is
/// being submitted to helper servers.
///
/// **Capacity & FIFO admission.** At most `capacity` deliveries run concurrently. `enqueue` hands
/// out admission tickets in call order: a caller that arrives while the window is already full
/// waits for its own ticket to be served, which only happens once the oldest still-pending
/// delivery settles — callers are admitted strictly in the order they called `enqueue`, never
/// reordered.
///
/// **Attribution.** Every delivery's outcome is attributed to the `VotingShareDeliveryIdentity`
/// it was enqueued under: a successful `Report` lands in the drained results, a thrown error is
/// recorded against that same identity — one delivery's failure never rejects or blocks a later
/// admission.
///
/// **Drain.** `drain()` closes the window to further admissions, waits for every still-pending
/// delivery to settle, and either returns the successful reports or throws
/// `VotingShareDeliveryAggregateError` carrying both the successful reports and the per-identity
/// failures collected so far.
///
/// **Cancel.** `cancelAndDrain()` also closes the window, but first cancels every owned `Task`
/// before waiting for each of them to finish — used to unwind a batch early without leaking
/// in-flight work.
actor VotingHelperDeliveryWindow<Report: Sendable> {
    private struct PendingDelivery {
        let sequence: Int
        let identity: VotingShareDeliveryIdentity
        let task: Task<Report, Error>
    }

    private let capacity: Int
    private var pending: [PendingDelivery] = []
    private var successfulReports: [VotingShareDeliveryIdentity: Report] = [:]
    private var failures: [VotingShareDeliveryIdentity: Error] = [:]
    private var nextSequence = 0
    private var nextAdmissionTicket = 0
    private var servingAdmissionTicket = 0
    private var admissionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var isClosed = false

    init(capacity: Int = 2) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func enqueue(
        identity: VotingShareDeliveryIdentity,
        operation: @escaping @Sendable () async throws -> Report
    ) async throws {
        let ticket = nextAdmissionTicket
        nextAdmissionTicket += 1
        if ticket != servingAdmissionTicket {
            await withCheckedContinuation { continuation in
                admissionWaiters[ticket] = continuation
            }
        }
        defer { finishAdmission(ticket: ticket) }

        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        if pending.count == capacity, let oldest = pending.first {
            await settle(oldest)
        }

        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        let sequence = nextSequence
        nextSequence += 1
        let task = Task { try await operation() }
        pending.append(PendingDelivery(sequence: sequence, identity: identity, task: task))
    }

    func drain() async throws -> [VotingShareDeliveryIdentity: Report] {
        isClosed = true
        while let oldest = pending.first {
            await settle(oldest)
        }
        guard failures.isEmpty else {
            throw VotingShareDeliveryAggregateError(
                successfulReports: successfulReports,
                failures: failures
            )
        }
        return successfulReports
    }

    func cancelAndDrain() async {
        isClosed = true
        pending.forEach { $0.task.cancel() }
        while let oldest = pending.first {
            await settle(oldest)
        }
    }

    private func finishAdmission(ticket: Int) {
        guard ticket == servingAdmissionTicket else { return }
        servingAdmissionTicket += 1
        admissionWaiters.removeValue(forKey: servingAdmissionTicket)?.resume()
    }

    private func settle(_ delivery: PendingDelivery) async {
        let result = await delivery.task.result
        guard let index = pending.firstIndex(where: { $0.sequence == delivery.sequence }) else { return }
        pending.remove(at: index)
        switch result {
        case .success(let report):
            successfulReports[delivery.identity] = report
        case .failure(let error):
            failures[delivery.identity] = error
        }
    }
}

/// The helper servers still worth contacting during one batch. Deliveries read the current set
/// when they start and prune it when a server proved unreachable, so a later delivery does not
/// retry a dead server.
///
/// The set only ever shrinks. A delivery's remaining list was computed from the set it read at its
/// own start, and two deliveries overlap, so it is applied as an intersection: a late success can
/// never put back a server an earlier failure removed, and once the pool is empty it stays empty
/// for the rest of the batch.
actor VotingShareServerPool {
    private var urls: [String]

    init(urls: [String]) {
        self.urls = urls
    }

    func current() -> [String] {
        urls
    }

    /// Keeps only the servers `remaining` still lists, in the pool's current order.
    func prune(to remaining: [String]) {
        urls = urls.filter { remaining.contains($0) }
    }

    var isExhausted: Bool {
        urls.isEmpty
    }
}
#endif
