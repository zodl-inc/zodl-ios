//
//  MigrationSimulatorEngineDerivations.swift
//  zodl
//
//  Pure, table-testable derivation logic for `MigrationSimulatorEngine` (MOB-1480) — no locking,
//  no I/O, no `Date()` (the caller always supplies `now`/`simNow`). Factored out so
//  `MigrationSimulatorEngine` itself is left with only locking/orchestration, matching the
//  established house pattern (see `MigrationDerivations` in `MigrationManagerLiveKey.swift`).
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationSimulatorEngineDerivations {
    enum Constants {
        static let fee = Zatoshi(10_000)
        /// Spacing between successive scheduled transfers.
        static let transferSpacing: TimeInterval = 6 * 3600
        /// A pending transfer more than this far past its `dueAt` reads as `.overdue`.
        static let overdueGrace: TimeInterval = 3600
        /// A pending transfer more than this far past its `dueAt` reads as `.expired` and escalates
        /// the whole migration into `.requiresAttention(.transferExpired)`.
        static let expiryWindow: TimeInterval = 24 * 3600
        static let splitConfirmDelay: TimeInterval = 15
        /// Simulated network latency while a transfer is "broadcasting".
        static let broadcastLatency: TimeInterval = 1.5
        /// ≈ 12.458 ZEC, matching the Figma frames.
        static let defaultOrchardBalance = Zatoshi(1_245_800_000)
        static let defaultRNGSeed: UInt64 = 12_458
        static let presetTransferCount = 5
        /// ASCII header every fabricated PCZT blob starts with (`fabricatePczt`) — also the
        /// recognition marker `SDKSynchronizerClient+Simulated`'s `parseMigrationPCZTBatch`
        /// override checks for (MOB-1480).
        static let fabricatedPCZTHeader = "ZODL-SIM-PCZT"
        /// Real Zcash chain heights are ~3,000,000 (as of 2026); epoch-second timestamps are
        /// ~1.77e9 — any `BlockHeight` at or above this threshold is unambiguously synthetic, never
        /// a real chain height (MOB-1480, supersedes spec §9 flag #1 — see `isSyntheticHeight`).
        static let syntheticHeightThreshold: BlockHeight = 1_000_000_000
        /// One synthetic day, added to a transfer's synthetic `nextExecutableAfterHeight` to derive
        /// its `expiryHeight`. Synthetic heights ARE epoch-second timestamps, so this is literally
        /// `expiryWindow` expressed in the same "height" units (MOB-1480).
        static let syntheticExpiryOffset: BlockHeight = 86_400
    }

    // MARK: - Time-driven escalation

    /// Escalates `.inProgress`/`.requiresAttention(.transferStalled)` into
    /// `.requiresAttention(.transferExpired)` once any unsent transfer's own window has been past
    /// due for more than `expiryWindow`. Never demotes/resurrects any other state (`.complete`,
    /// `.notStarted`, `.invalidTransfer`, etc. are left untouched).
    static func recompute(_ snapshot: inout SimulatorSnapshot, now: Date) {
        guard !snapshot.transfers.isEmpty else { return }

        let hasNewlyExpired = snapshot.transfers.contains { transfer in
            transfer.sentAt == nil && now > transfer.dueAt.addingTimeInterval(Constants.expiryWindow)
        }
        guard hasNewlyExpired else { return }

        switch snapshot.state {
        case MigrationState.inProgress:
            snapshot.state = MigrationState.requiresAttention(AttentionReason.transferExpired)
        case MigrationState.requiresAttention(let reason):
            if case AttentionReason.transferStalled = reason {
                snapshot.state = MigrationState.requiresAttention(AttentionReason.transferExpired)
            }
        default:
            break
        }
    }

    // MARK: - Synthetic heights (MOB-1480, supersedes spec §9 flag #1)

    /// True for a `BlockHeight` fabricated from a wall-clock timestamp (`syntheticHeight(for:)`)
    /// rather than a real chain height — see `Constants.syntheticHeightThreshold`.
    static func isSyntheticHeight(_ height: BlockHeight) -> Bool {
        height >= Constants.syntheticHeightThreshold
    }

    /// Encodes `date` as a synthetic `BlockHeight` (its epoch-second timestamp, truncated).
    static func syntheticHeight(for date: Date) -> BlockHeight {
        BlockHeight(date.timeIntervalSince1970)
    }

    /// Inverse of `syntheticHeight(for:)` — recovers the original timestamp from a synthetic
    /// height. Only meaningful when `isSyntheticHeight(height)` is true; callers (the simulated
    /// `estimateTimestamp` override) always check that first.
    static func timestamp(forSyntheticHeight height: BlockHeight) -> TimeInterval {
        TimeInterval(height)
    }

    /// Shared due-time formula for both `propose()` (stamping synthetic heights on each
    /// `TransferProposal`) and `signAndStore()` (seeding each `SimulatorTransfer.dueAt`) — kept in
    /// one place so the two can never drift apart, which would desync a proposed transfer's
    /// stamped height from the `dueAt` it's actually signed/stored with. Immediate mode is always
    /// due `now`; scheduled mode spaces transfers `transferSpacing` apart starting one spacing
    /// unit out.
    static func dueAt(forTransferAt index: Int, isImmediate: Bool, now: Date) -> Date {
        isImmediate ? now : now.addingTimeInterval(Constants.transferSpacing * Double(index + 1))
    }

    // MARK: - Row derivation (transferRows / readout)

    /// Derives the full row list for display, in schedule order. Row `status` is always derived
    /// here (never stored) from `(sentAt, dueAt, now, state, broadcastingId)` — see spec §5.2.
    static func rows(for snapshot: SimulatorSnapshot, now: Date, broadcastingId: String?) -> [MigrationTransferRow] {
        var firstPendingSeen = false
        var result: [MigrationTransferRow] = []
        for transfer in snapshot.transfers.sorted(by: { $0.index < $1.index }) {
            let status = derivedStatus(for: transfer, state: snapshot.state, now: now, firstPendingSeen: &firstPendingSeen)
            let isBroadcasting = status == MigrationTransferRow.Status.active && transfer.id == broadcastingId
            let (hoursFromNow, sentMinutesAgo) = captionFields(transfer: transfer, status: status, now: now)
            result.append(
                MigrationTransferRow(
                    id: transfer.id,
                    index: transfer.index,
                    amount: transfer.amount,
                    status: status,
                    hoursFromNow: hoursFromNow,
                    sentMinutesAgo: sentMinutesAgo,
                    isBroadcasting: isBroadcasting
                )
            )
        }
        return result
    }

    /// Only the earliest not-yet-sent transfer can ever read `.active`/`.overdue` — everything
    /// behind it is blocked in the queue and always reads `.pending` regardless of its own window
    /// (matches the MOB-1451 prototype's round-4 semantics).
    private static func derivedStatus(
        for transfer: SimulatorTransfer,
        state: MigrationState,
        now: Date,
        firstPendingSeen: inout Bool
    ) -> MigrationTransferRow.Status {
        if transfer.sentAt != nil {
            return MigrationTransferRow.Status.sent
        }

        if case MigrationState.requiresAttention(let reason) = state {
            if case AttentionReason.invalidTransfer(let transferId) = reason, transferId == transfer.id {
                return MigrationTransferRow.Status.invalid
            }
            if case AttentionReason.transferExpired = reason, now > transfer.dueAt.addingTimeInterval(Constants.expiryWindow) {
                return MigrationTransferRow.Status.expired
            }
        }

        guard !firstPendingSeen else { return MigrationTransferRow.Status.pending }
        firstPendingSeen = true
        let isOverdue = now > transfer.dueAt.addingTimeInterval(Constants.overdueGrace)
        return isOverdue ? MigrationTransferRow.Status.overdue : MigrationTransferRow.Status.active
    }

    /// `hoursFromNow`/`sentMinutesAgo` are contextually overloaded per `MigrationStatusView`'s
    /// caption function: for `.sent` / `.overdue` rows they mean "hours ago"; for `.active`/
    /// `.pending` they mean "hours until due"; `.invalid`/`.expired` don't render an ETA caption
    /// today, so they default to `0`. ETA/overdue round to the nearest hour (matching the
    /// MOB-1451 prototype's convention) rather than flooring, so a row scheduled exactly "6h out"
    /// still reads as `6` a moment later instead of immediately dropping to `5`; `.sent` stays
    /// floor-based since sub-hour precision is already covered by `sentMinutesAgo`.
    private static func captionFields(
        transfer: SimulatorTransfer,
        status: MigrationTransferRow.Status,
        now: Date
    ) -> (hoursFromNow: Int, sentMinutesAgo: Int?) {
        switch status {
        case MigrationTransferRow.Status.sent:
            guard let sentAt = transfer.sentAt else { return (0, nil) }
            let elapsedMinutes = max(0, Int(now.timeIntervalSince(sentAt) / 60))
            let sentMinutesAgo = elapsedMinutes < 60 ? elapsedMinutes : nil
            return (elapsedMinutes / 60, sentMinutesAgo)

        case MigrationTransferRow.Status.overdue:
            let elapsedHours = max(0, Int((now.timeIntervalSince(transfer.dueAt) / 3600).rounded()))
            return (elapsedHours, nil)

        case MigrationTransferRow.Status.invalid, MigrationTransferRow.Status.expired:
            return (0, nil)

        case MigrationTransferRow.Status.active, MigrationTransferRow.Status.pending:
            let remainingHours = max(0, Int((transfer.dueAt.timeIntervalSince(now) / 3600).rounded()))
            return (remainingHours, nil)
        }
    }

    // MARK: - hasOverdue / hasInvalid

    /// Only the earliest not-yet-sent transfer can make the migration read as overdue — later
    /// transfers are simply blocked behind it (mirrors `derivedStatus`'s "first pending" rule).
    static func hasOverdue(snapshot: SimulatorSnapshot, now: Date) -> Bool {
        if case MigrationState.requiresAttention(let reason) = snapshot.state, case AttentionReason.transferStalled = reason {
            return true
        }
        guard let earliestPending = snapshot.transfers.filter({ $0.sentAt == nil }).min(by: { $0.index < $1.index }) else {
            return false
        }
        return now > earliestPending.dueAt.addingTimeInterval(Constants.overdueGrace)
    }

    /// A row only ever reads `.invalid`/`.expired` while `state` carries the matching attention
    /// reason (see `derivedStatus`), so checking `state` alone is equivalent to scanning rows.
    static func hasInvalid(snapshot: SimulatorSnapshot) -> Bool {
        guard case MigrationState.requiresAttention(let reason) = snapshot.state else { return false }
        switch reason {
        case AttentionReason.invalidTransfer, AttentionReason.transferExpired:
            return true
        case AttentionReason.transferStalled, AttentionReason.syncRequiredBeforeNext:
            return false
        }
    }

    // MARK: - isNextTransferDue

    /// True when the earliest unsent transfer is already due AND the migration is in the one
    /// state where "next transfer due" is a meaningful signal: `.inProgress` is the only state
    /// `computeProgress`/`progress()` ever return non-`nil` for, which is what
    /// `MigrationDerivations.bannerVariant`/`reentryRoute` pair this signal with (manual-delivery
    /// "transfer ready"/"review manual" rows). Supersedes the real SDK-facing derivation
    /// (`MigrationManagerLiveKey.isNextTransferDue()`), which compares a `BlockHeight` against the
    /// real chain's `latestBlockHeight` — a comparison that can never fire against our synthetic
    /// (epoch-seconds) heights (MOB-1480).
    static func isNextTransferDue(snapshot: SimulatorSnapshot, now: Date) -> Bool {
        guard case MigrationState.inProgress = snapshot.state else { return false }
        guard let earliestPending = snapshot.transfers.filter({ $0.sentAt == nil }).min(by: { $0.index < $1.index }) else {
            return false
        }
        return earliestPending.dueAt <= now
    }

    // MARK: - Progress / summary

    static func computeProgress(for snapshot: SimulatorSnapshot) -> MigrationProgress {
        let nextUnsent = snapshot.transfers.filter { $0.sentAt == nil }.min(by: { $0.index < $1.index })
        return MigrationProgress(
            completedTransfers: snapshot.transfers.filter { $0.sentAt != nil }.count,
            totalTransfers: snapshot.transfers.count,
            remainingOrchard: snapshot.orchardBalance,
            // Synthetic height of the next unsent transfer's `dueAt` (supersedes spec §9 flag #1,
            // as an improvement — see `syntheticHeight(for:)`); `nil` once every transfer is sent.
            nextTransferReadyAtHeight: nextUnsent.map { syntheticHeight(for: $0.dueAt) }
        )
    }

    static func computeSummary(for snapshot: SimulatorSnapshot) -> MigrationSummary {
        let sent = snapshot.transfers.filter { $0.sentAt != nil }
        let transferred = sent.reduce(Zatoshi.zero) { $0 + $1.amount }
        let isComplete = snapshot.state == MigrationState.complete
        let estimatedDurationHours = snapshot.mode == MigrationMode.immediate
            ? 0
            : snapshot.transfers.count * Int(Constants.transferSpacing / 3600)

        return MigrationSummary(
            transferred: transferred,
            dust: isComplete ? snapshot.dustRemainder : Zatoshi.zero,
            transfersSent: sent.count,
            transfersTotal: snapshot.transfers.count,
            estimatedDurationHours: estimatedDurationHours
        )
    }

    // MARK: - Note splitting

    /// Splits `net` into 3–5 (or `countOverride`) random-weighted notes summing EXACTLY to `net`,
    /// reproducible for a fixed `seed`. Weights are drawn from a fresh `SplitMix64(seed:)` every
    /// call (not evolved/persisted), so the same `(seed, net, countOverride)` always yields the
    /// same split — see spec §9 flag #3.
    static func splitNotes(net: Zatoshi, seed: UInt64, countOverride: Int? = nil) -> [Zatoshi] {
        guard net.amount > 0 else { return [] }

        var rng = SplitMix64(seed: seed)
        let count = countOverride ?? Int.random(in: 3...5, using: &rng)
        guard count > 1, net.amount >= Int64(count) else { return [net] }

        let weights = (0..<count).map { _ in Double.random(in: 0.5...1.5, using: &rng) }
        let totalWeight = weights.reduce(0, +)
        var amounts = weights.map { weight in Int64((Double(net.amount) * weight / totalWeight).rounded(.down)) }
        let allocated = amounts.reduce(0, +)
        amounts[amounts.count - 1] += net.amount - allocated
        return amounts.map { Zatoshi($0) }
    }

    // MARK: - Deterministic IDs / fabricated PCZTs

    static func makeTransferId(index: Int) -> String {
        "xfer-\(index)"
    }

    static func makeTxId(prefix: String, discriminator: String) -> String {
        "tx-\(prefix)-\(discriminator)"
    }

    /// Non-empty, deterministic fabricated PCZT blob: an ASCII header, then the index and amount
    /// as fixed-width little-endian bytes.
    static func fabricatePczt(index: Int, amount: Zatoshi) -> Pczt {
        var data = Data(Constants.fabricatedPCZTHeader.utf8)
        withUnsafeBytes(of: Int32(index).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: amount.amount.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func describeArmedResult(_ result: TransferResult?, splitFailureArmed: Bool) -> String? {
        if splitFailureArmed { return "splitFailure" }
        guard let result else { return nil }
        switch result {
        case TransferResult.success(let txId): return "success(txId: \(txId))"
        case TransferResult.networkError(let retryable): return "networkError(retryable: \(retryable))"
        case TransferResult.invalidNote: return "invalidNote"
        case TransferResult.expired: return "expired"
        }
    }

    // MARK: - Presets (spec §5.3)

    /// Seeds a whole, internally-consistent snapshot for `preset`. Always clears any armed
    /// result/split-failure first so presets are reliably reproducible regardless of prior state.
    static func applyPreset(_ preset: SimulatorPreset, to snapshot: inout SimulatorSnapshot, now: Date) {
        snapshot.armedTransferResult = nil
        snapshot.armedSplitFailure = false
        snapshot.lastBackgroundRunSummary = "applied preset \(preset.rawValue)"

        switch preset {
        case SimulatorPreset.freshRequired:
            snapshot.orchardBalance = Constants.defaultOrchardBalance
            snapshot.notes = [Constants.defaultOrchardBalance]
            snapshot.mode = MigrationMode.privateScheduled
            snapshot.transfers = []
            snapshot.syncRequired = false
            snapshot.dustRemainder = Zatoshi.zero
            snapshot.state = MigrationState.notStarted

        case SimulatorPreset.splitting:
            snapshot.orchardBalance = Constants.defaultOrchardBalance
            snapshot.mode = MigrationMode.privateScheduled
            snapshot.notes = splitNotes(net: netOfFee(Constants.defaultOrchardBalance), seed: snapshot.rngSeed)
            snapshot.transfers = []
            snapshot.splitSubmittedAt = now
            snapshot.state = MigrationState.splitPendingConfirmation

        case SimulatorPreset.readyToPropose:
            snapshot.orchardBalance = Constants.defaultOrchardBalance
            snapshot.mode = MigrationMode.privateScheduled
            snapshot.notes = splitNotes(net: netOfFee(Constants.defaultOrchardBalance), seed: snapshot.rngSeed)
            snapshot.transfers = []
            snapshot.state = MigrationState.readyToPropose

        case SimulatorPreset.inProgress:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            snapshot.state = MigrationState.inProgress(computeProgress(for: snapshot))

        case SimulatorPreset.transferReadyManual:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            if let index = firstPendingIndex(in: snapshot) {
                snapshot.transfers[index].dueAt = now
            }
            snapshot.state = MigrationState.inProgress(computeProgress(for: snapshot))

        case SimulatorPreset.transferStalled:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            if let index = firstPendingIndex(in: snapshot) {
                snapshot.transfers[index].dueAt = now.addingTimeInterval(-Constants.overdueGrace)
                snapshot.state = MigrationState.requiresAttention(
                    AttentionReason.transferStalled(transferNumber: snapshot.transfers[index].index + 1)
                )
            }

        case SimulatorPreset.updatePlanInvalid:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            if let index = firstPendingIndex(in: snapshot) {
                snapshot.state = MigrationState.requiresAttention(
                    AttentionReason.invalidTransfer(transferId: snapshot.transfers[index].id)
                )
            }

        case SimulatorPreset.transfersExpired:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            if let index = firstPendingIndex(in: snapshot) {
                snapshot.transfers[index].dueAt = now.addingTimeInterval(-(Constants.expiryWindow + 1))
            }
            snapshot.state = MigrationState.requiresAttention(AttentionReason.transferExpired)

        case SimulatorPreset.syncRequired:
            seedPresetSchedule(&snapshot, now: now, sentCount: 2)
            snapshot.state = MigrationState.inProgress(computeProgress(for: snapshot))
            snapshot.syncRequired = true

        case SimulatorPreset.complete:
            seedPresetSchedule(&snapshot, now: now, sentCount: Constants.presetTransferCount)
            snapshot.dustRemainder = Zatoshi.zero
            snapshot.orchardBalance = snapshot.dustRemainder
            snapshot.state = MigrationState.complete

        case SimulatorPreset.completeWithDust:
            seedPresetSchedule(&snapshot, now: now, sentCount: Constants.presetTransferCount)
            snapshot.dustRemainder = Zatoshi(5_000)
            snapshot.orchardBalance = snapshot.dustRemainder
            snapshot.state = MigrationState.complete
        }
    }

    static func netOfFee(_ balance: Zatoshi) -> Zatoshi {
        Zatoshi(max(0, balance.amount - Constants.fee.amount))
    }

    /// Common base for every multi-transfer preset: a fresh `presetTransferCount`-note scheduled
    /// migration, with the first `sentCount` transfers already sent (and the balance decremented
    /// to match) and the rest pending, 6h apart, starting from `now`.
    private static func seedPresetSchedule(_ snapshot: inout SimulatorSnapshot, now: Date, sentCount: Int) {
        snapshot.mode = MigrationMode.privateScheduled
        snapshot.orchardBalance = Constants.defaultOrchardBalance
        let notes = splitNotes(
            net: netOfFee(Constants.defaultOrchardBalance),
            seed: snapshot.rngSeed,
            countOverride: Constants.presetTransferCount
        )
        snapshot.notes = notes

        var remaining = Constants.defaultOrchardBalance
        var transfers: [SimulatorTransfer] = []
        for (index, note) in notes.enumerated() {
            let dueAt = now.addingTimeInterval(Constants.transferSpacing * Double(index + 1))
            let isSent = index < sentCount
            let sentAt = isSent ? now.addingTimeInterval(-Constants.transferSpacing * Double(notes.count - index)) : nil
            transfers.append(
                SimulatorTransfer(id: makeTransferId(index: index), index: index, amount: note, dueAt: dueAt, sentAt: sentAt)
            )
            if isSent {
                remaining = Zatoshi(max(0, remaining.amount - note.amount))
            }
        }
        snapshot.transfers = transfers
        snapshot.orchardBalance = remaining
    }

    private static func firstPendingIndex(in snapshot: SimulatorSnapshot) -> Int? {
        snapshot.transfers.enumerated()
            .filter { $0.element.sentAt == nil }
            .min(by: { $0.element.index < $1.element.index })
            .map { $0.offset }
    }
}
