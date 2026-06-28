//
//  DummyMigrationEngine.swift
//  zodl
//
//  Simulated implementation of the Orchard → Ironwood migration. This is the ONLY place that
//  fakes behaviour — `MigrationSDKClient.liveValue` wires its closures to this engine. Replacing the
//  dummy with the real (Rust-backed) SDK means swapping `liveValue`; nothing else changes.
//
//  Thread-safety: the snapshot is guarded by an unfair lock and the state subject is internally
//  synchronized, so the type is `@unchecked Sendable`.
//

import Foundation
import os
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit

final class DummyMigrationEngine: @unchecked Sendable {
    private enum Const {
        /// Simulates the ~288-block / 6h anchor bucket, compressed for the prototype.
        static let bucketBlocks: BlockHeight = 50
        static let expiryWindowBlocks: BlockHeight = 200
        /// Private/scheduled migrations split the balance into a random 5...8 transfers.
        static let minNotes = 5
        static let maxNotes = 8
        /// Cosmetic per-transfer fee (0.0001 ZEC).
        static let fee = Zatoshi(10_000)
        /// Simulated note-split confirmation wait (~1 block). The user watches this on the split screen.
        static let splitConfirmDelay: Duration = .seconds(15)
    }

    private let store: MigrationStateStore
    private let protected: OSAllocatedUnfairLock<MigrationSnapshot>
    private let stateSubject: CurrentValueSubject<MigrationState, Never>

    init(store: MigrationStateStore) {
        self.store = store
        let initial = store.load()
        self.protected = OSAllocatedUnfairLock(initialState: initial)
        self.stateSubject = CurrentValueSubject<MigrationState, Never>(initial.state)
    }

    // ── Lock helpers ───────────────────────────────────────────────────────

    @discardableResult
    private func mutate(_ body: (inout MigrationSnapshot) -> Void) -> MigrationSnapshot {
        // `withLockUnchecked`: the closures capture non-Sendable state intentionally; mutual
        // exclusion is guaranteed by the lock, so the type is `@unchecked Sendable`.
        let updated = protected.withLockUnchecked { snapshot -> MigrationSnapshot in
            body(&snapshot)
            return snapshot
        }
        store.save(updated)
        stateSubject.send(updated.state)
        return updated
    }

    private func read<T>(_ body: (MigrationSnapshot) -> T) -> T {
        protected.withLockUnchecked { body($0) }
    }

    // ── State reads ──────────────────────────────────────────────────────────

    func currentState() -> MigrationState { read { $0.state } }

    func statePublisher() -> AnyPublisher<MigrationState, Never> { stateSubject.eraseToAnyPublisher() }

    func progress() -> MigrationProgress? {
        read { snapshot in
            if case let .inProgress(progress) = snapshot.state { return progress }
            return nil
        }
    }

    func noteSplitNeeded() -> Bool {
        read { $0.mode == .privateScheduled && $0.state == .notStarted }
    }

    func syncRequiredBeforeNext() -> Bool { read { $0.syncRequired } }

    func overdue() -> Bool {
        read { snapshot in
            guard case .inProgress = snapshot.state else { return false }
            // A pending transfer is overdue once more than one bucket has elapsed past its window.
            return snapshot.transfers.contains {
                $0.status == .pending
                    && $0.proposal.nextExecutableAfterHeight + Const.bucketBlocks <= snapshot.currentHeight
            }
        }
    }

    func invalid() -> Bool {
        read { snapshot in
            if case .requiresAttention = snapshot.state { return true }
            return snapshot.transfers.contains { $0.status == .invalid || $0.status == .expired }
        }
    }

    func orchardBalance() -> Zatoshi { read { $0.orchard } }

    func summary() -> MigrationSummary {
        read { snapshot in
            let sentAmount = snapshot.transfers.reduce(Int64(0)) { acc, transfer in
                if case .sent = transfer.status {
                    return acc + transfer.proposal.amount.amount
                }
                return acc
            }
            let sentCount = snapshot.transfers.filter { transfer in
                if case .sent = transfer.status {
                    return true
                }
                return false
            }.count
            let total = snapshot.transfers.count
            return MigrationSummary(
                transferred: Zatoshi(sentAmount),
                dust: snapshot.orchard,
                transfersSent: sentCount,
                transfersTotal: total,
                estimatedDurationHours: max(0, (total - 1) * 6)
            )
        }
    }

    func transferRows() -> [MigrationTransferRow] {
        read { snapshot in
            let height = snapshot.currentHeight
            var rows: [MigrationTransferRow] = []
            var firstPendingSeen = false
            for (index, transfer) in snapshot.transfers.enumerated() {
                let status: MigrationTransferRow.Status
                switch transfer.status {
                case .sent:
                    status = .sent
                case .invalid:
                    status = .invalid
                case .expired:
                    status = .expired
                case .pending:
                    let isOverdue = transfer.proposal.nextExecutableAfterHeight + Const.bucketBlocks <= height
                    if firstPendingSeen {
                        status = .pending
                    } else {
                        firstPendingSeen = true
                        status = isOverdue ? .overdue : .active
                    }
                }
                let blocksAway = max(0, transfer.proposal.nextExecutableAfterHeight - height)
                let hours = Int((Double(blocksAway) / Double(Const.bucketBlocks)).rounded()) * 6
                rows.append(
                    MigrationTransferRow(
                        id: transfer.proposal.id,
                        index: index,
                        amount: transfer.proposal.amount,
                        status: status,
                        hoursFromNow: hours
                    )
                )
            }
            return rows
        }
    }

    // ── Mutations ────────────────────────────────────────────────────────────

    func selectMode(_ mode: MigrationMode) {
        mutate { $0.mode = mode }
    }

    func initializePostUpgrade() {
        mutate { snapshot in
            if snapshot.minAnchorHeight == nil {
                snapshot.minAnchorHeight = snapshot.currentHeight
            }
        }
    }

    func prepareSplit() async -> NoteSplitProposal {
        let snapshot = read { $0 }
        let net = max(0, snapshot.orchard.amount - Const.fee.amount)
        let count = snapshot.noteCountOverride ?? Int.random(in: Const.minNotes...Const.maxNotes)
        let notes = splitAmount(net, into: count).map { Zatoshi($0) }
        return NoteSplitProposal(outputNotes: notes, fee: Const.fee)
    }

    func submitSplit(_ proposal: NoteSplitProposal) async -> TransferResult {
        mutate { snapshot in
            snapshot.notes = proposal.outputNotes
            snapshot.state = .splitPendingConfirmation
        }
        // Simulate ~1-block confirmation, then move to readyToPropose. Debug can force this sooner.
        Task { [weak self] in
            try? await Task.sleep(for: Const.splitConfirmDelay)
            self?.confirmSplit()
        }
        return TransferResult.success(txId: Self.makeTxId(prefix: "split"))
    }

    func confirmSplit() {
        mutate { snapshot in
            if snapshot.state == .splitPendingConfirmation {
                snapshot.state = .readyToPropose
            }
        }
    }

    func propose() async -> MigrationSchedule {
        read { buildSchedule(from: $0) }
    }

    func signAndStore(_ schedule: MigrationSchedule) async {
        mutate { snapshot in
            snapshot.transfers = schedule.transfers.map { StoredTransfer(proposal: $0, status: .pending) }
            snapshot.state = .inProgress(Self.progress(for: snapshot))
        }
    }

    func executeNext(_ options: NetworkPrivacyOptions) async -> TransferResult? {
        let hasPending = read { $0.transfers.contains { $0.status == .pending } }
        guard hasPending else { return nil }

        var result: TransferResult = .networkError(retryable: true)
        mutate { snapshot in
            snapshot.networkPrivacy = options
            guard let index = snapshot.transfers.firstIndex(where: { $0.status == .pending }) else { return }

            if let armed = snapshot.armedFailure {
                snapshot.armedFailure = nil
                switch armed {
                case .invalidNote:
                    snapshot.transfers[index].status = .invalid
                    snapshot.state = .requiresAttention(
                        .invalidTransfer(transferId: snapshot.transfers[index].proposal.id)
                    )
                    result = .invalidNote
                    return
                case .expired:
                    snapshot.transfers[index].status = .expired
                    snapshot.state = .requiresAttention(.transferExpired)
                    result = .expired
                    return
                case let .networkError(retryable):
                    result = .networkError(retryable: retryable)
                    return
                case .success:
                    break
                }
            }

            let txId = Self.makeTxId(prefix: "xfer")
            let amount = snapshot.transfers[index].proposal.amount
            snapshot.transfers[index].status = .sent(txId: txId)
            snapshot.orchard = Zatoshi(max(0, snapshot.orchard.amount - amount.amount))
            result = .success(txId: txId)

            if snapshot.transfers.contains(where: { $0.status == .pending }) {
                snapshot.state = .inProgress(Self.progress(for: snapshot))
            } else {
                // All transfers migrated — the remainder (reserved fees) is consumed on-chain.
                snapshot.orchard = Zatoshi.zero
                snapshot.state = .complete
            }
        }
        return result
    }

    func restart() async -> MigrationSchedule {
        mutate { snapshot in
            snapshot.transfers.removeAll {
                $0.status == .invalid || $0.status == .expired || $0.status == .pending
            }
            // Re-split the remaining Orchard balance into a fresh 5...8-transfer plan.
            let net = max(0, snapshot.orchard.amount - Const.fee.amount)
            if net > 0 {
                let count = snapshot.noteCountOverride ?? Int.random(in: Const.minNotes...Const.maxNotes)
                snapshot.notes = splitAmount(net, into: count).map { Zatoshi($0) }
            } else {
                snapshot.notes = []
            }
            snapshot.armedFailure = nil
            snapshot.syncRequired = false
            snapshot.state = .readyToPropose
        }
        return await propose()
    }

    // ── Debug ────────────────────────────────────────────────────────────────

    func debugReset() async {
        store.clear()
        let fresh = MigrationSnapshot.seededDefault
        protected.withLockUnchecked { $0 = fresh }
        store.save(fresh)
        stateSubject.send(fresh.state)
    }

    func debugSeed(orchard: Zatoshi, noteCount: Int) async {
        mutate { snapshot in
            snapshot.orchard = orchard
            snapshot.notes = [orchard]
            snapshot.transfers = []
            snapshot.armedFailure = nil
            snapshot.syncRequired = false
            snapshot.minAnchorHeight = nil
            snapshot.noteCountOverride = noteCount > 0 ? noteCount : nil
            snapshot.state = .notStarted
        }
    }

    func debugAdvanceHeight(_ blocks: Int) async {
        mutate { snapshot in
            snapshot.currentHeight += BlockHeight(blocks)
            if case .inProgress = snapshot.state {
                snapshot.state = .inProgress(Self.progress(for: snapshot))
            }
        }
    }

    func debugConfirmSplit() async { confirmSplit() }

    func debugArm(_ result: TransferResult) async {
        mutate { $0.armedFailure = result }
    }

    func debugJump(_ target: MigrationDebugTarget) async {
        mutate { snapshot in
            switch target {
            case .overdue:
                if snapshot.transfers.isEmpty {
                    let schedule = buildSchedule(from: snapshot)
                    snapshot.transfers = schedule.transfers.map { StoredTransfer(proposal: $0, status: .pending) }
                }
                let maxWindow = snapshot.transfers.map { $0.proposal.nextExecutableAfterHeight }.max()
                    ?? snapshot.currentHeight
                snapshot.currentHeight = maxWindow + Const.bucketBlocks + 1
                snapshot.state = .inProgress(Self.progress(for: snapshot))
            case .invalidTransfer:
                if let index = snapshot.transfers.firstIndex(where: { $0.status == .pending }) {
                    snapshot.transfers[index].status = .invalid
                    snapshot.state = .requiresAttention(
                        .invalidTransfer(transferId: snapshot.transfers[index].proposal.id)
                    )
                } else {
                    snapshot.state = .requiresAttention(.invalidTransfer(transferId: "none"))
                }
            case .syncRequired:
                snapshot.syncRequired = true
                snapshot.state = .requiresAttention(.syncRequiredBeforeNext)
            case .complete:
                for index in snapshot.transfers.indices where snapshot.transfers[index].status == .pending {
                    snapshot.transfers[index].status = .sent(txId: Self.makeTxId(prefix: "xfer"))
                }
                snapshot.orchard = Zatoshi.zero
                snapshot.state = .complete
            case .completeWithDust:
                for index in snapshot.transfers.indices where snapshot.transfers[index].status == .pending {
                    snapshot.transfers[index].status = .sent(txId: Self.makeTxId(prefix: "xfer"))
                }
                snapshot.orchard = Zatoshi(snapshot.dustThreshold.amount / 2)
                snapshot.state = .complete
            }
        }
    }

    func debugSnapshotDescription() -> String {
        read { snapshot in
            var lines: [String] = []
            lines.append("state: \(snapshot.state)")
            lines.append("mode: \(snapshot.mode.rawValue)")
            lines.append("orchard: \(snapshot.orchard.amount) zats")
            lines.append("height: \(snapshot.currentHeight)")
            for (index, transfer) in snapshot.transfers.enumerated() {
                lines.append(
                    "  [\(index)] \(transfer.proposal.amount.amount) zats · \(transfer.status) · execAt=\(transfer.proposal.nextExecutableAfterHeight)"
                )
            }
            return lines.joined(separator: "\n")
        }
    }

    // ── Pure helpers ─────────────────────────────────────────────────────────

    private func buildSchedule(from snapshot: MigrationSnapshot) -> MigrationSchedule {
        let height = snapshot.currentHeight
        if snapshot.mode == .immediate {
            let transfer = TransferProposal(
                id: Self.makeTxId(prefix: "xfer"),
                amount: snapshot.orchard,
                anchorHeight: height,
                nextExecutableAfterHeight: height,
                expiryHeight: height + Const.expiryWindowBlocks
            )
            return MigrationSchedule(transfers: [transfer], estimatedDurationHours: 0)
        }

        // Private/scheduled: one transfer per split note. If the split was somehow skipped (notes
        // empty), fall back to a fresh 5...8-way random division so the plan is never a single transfer.
        let notes: [Zatoshi]
        if snapshot.notes.count >= 2 {
            notes = snapshot.notes
        } else {
            let net = max(0, snapshot.orchard.amount - Const.fee.amount)
            let count = snapshot.noteCountOverride ?? Int.random(in: Const.minNotes...Const.maxNotes)
            notes = splitAmount(net, into: count).map { Zatoshi($0) }
        }
        var transfers: [TransferProposal] = []
        for (index, note) in notes.enumerated() {
            // Transfer 1 is executable now; each subsequent transfer is one bucket (~6h) later.
            let executableAt = height + Const.bucketBlocks * BlockHeight(index)
            let anchor = executableAt - (executableAt % Const.bucketBlocks)
            transfers.append(
                TransferProposal(
                    id: Self.makeTxId(prefix: "xfer"),
                    amount: note,
                    anchorHeight: anchor,
                    nextExecutableAfterHeight: executableAt,
                    expiryHeight: executableAt + Const.expiryWindowBlocks
                )
            )
        }
        let durationHours = max(0, (notes.count - 1) * 6)
        return MigrationSchedule(transfers: transfers, estimatedDurationHours: durationHours)
    }

    /// Randomly divides `total` into `count` positive amounts that sum **exactly** to `total`.
    /// Every part is ≥ 1; the last part absorbs the rounding remainder.
    private func splitAmount(_ total: Int64, into count: Int) -> [Int64] {
        guard count > 1 else { return total > 0 ? [total] : [] }
        guard total >= Int64(count) else {
            // Not enough to give every part ≥ 1 (never happens for prototype balances) — degrade gracefully.
            var parts = Array(repeating: Int64(1), count: count)
            parts[count - 1] = max(1, total - Int64(count - 1))
            return parts
        }
        let weights = (0..<count).map { _ in Double.random(in: 0.5...1.5) }
        let weightSum = weights.reduce(0, +)
        var parts: [Int64] = []
        var allocated: Int64 = 0
        for index in 0..<(count - 1) {
            // Reserve at least 1 for each remaining part so the final remainder stays positive.
            let remainingParts = Int64(count - 1 - index)
            let maxForThis = total - allocated - remainingParts
            var part = Int64((Double(total) * weights[index] / weightSum).rounded())
            part = max(1, min(part, maxForThis))
            parts.append(part)
            allocated += part
        }
        parts.append(total - allocated)
        return parts
    }

    private static func progress(for snapshot: MigrationSnapshot) -> MigrationProgress {
        let total = snapshot.transfers.count
        let completed = snapshot.transfers.filter {
            if case .sent = $0.status { return true }
            return false
        }.count
        let next = snapshot.transfers.first { $0.status == .pending }?.proposal.nextExecutableAfterHeight
        return MigrationProgress(
            completedTransfers: completed,
            totalTransfers: total,
            remainingOrchard: snapshot.orchard,
            nextTransferReadyAtHeight: next
        )
    }

    private static func makeTxId(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
