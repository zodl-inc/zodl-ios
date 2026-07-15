//
//  MigrationSimulatorEngine.swift
//  zodl
//
//  Stateful simulated implementation of the Orchard -> Ironwood migration SDK surface (MOB-1480).
//  `MigrationSimulatorClient.liveValue` (Phase B) wires its closures to the shared instance of
//  this engine so the whole migration UI is walkable end-to-end before the real SDK exists
//  (MOB-1455). Every piece of actual derivation logic is factored into
//  `MigrationSimulatorEngineDerivations` (pure, table-testable); this type is left with locking,
//  persistence, the state stream, and the one real timer (the note-split confirm delay).
//
//  Thread-safety: the snapshot is guarded by an `OSAllocatedUnfairLock` and the state subject is
//  internally synchronized, so the type is `@unchecked Sendable`. The transient "currently
//  broadcasting" transfer id is intentionally NOT persisted (see `SimulatorTransfer`'s doc) — it's
//  guarded by its own lock.
//

import Foundation
import os
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit

final class MigrationSimulatorEngine: @unchecked Sendable {
    private let store: MigrationSimulatorStateStore
    private let snapshotLock: OSAllocatedUnfairLock<SimulatorSnapshot>
    private let stateSubject: CurrentValueSubject<MigrationState, Never>
    private let broadcastingId = OSAllocatedUnfairLock<String?>(initialState: nil)

    var isActive: Bool {
        withSnapshot { $0.isActive }
    }

    init(store: MigrationSimulatorStateStore) {
        self.store = store
        let initial = store.load()
        self.snapshotLock = OSAllocatedUnfairLock(initialState: initial)
        self.stateSubject = CurrentValueSubject<MigrationState, Never>(initial.state)
    }

    // MARK: - State reads

    func currentState() -> MigrationState {
        withSnapshot { $0.state }
    }

    func statePublisher() -> AnyPublisher<MigrationState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func progress() -> MigrationProgress? {
        withSnapshot { snapshot in
            guard case MigrationState.inProgress = snapshot.state else { return nil }
            return MigrationSimulatorEngineDerivations.computeProgress(for: snapshot)
        }
    }

    func setActive(_ isActive: Bool) {
        withSnapshot { $0.isActive = isActive }
    }

    func orchardBalance() -> Zatoshi {
        withSnapshot { $0.orchardBalance }
    }

    func hasOverdue() -> Bool {
        withSnapshot { snapshot in
            MigrationSimulatorEngineDerivations.hasOverdue(snapshot: snapshot, now: self.simNow(snapshot))
        }
    }

    func hasInvalid() -> Bool {
        withSnapshot { snapshot in
            MigrationSimulatorEngineDerivations.hasInvalid(snapshot: snapshot)
        }
    }

    /// Simulator-side substitute for the real SDK-facing `isNextTransferDue()` derivation
    /// (`MigrationManagerLiveKey.swift`), which compares `progress().nextTransferReadyAtHeight`
    /// against the real chain's `latestBlockHeight` — a comparison that can never fire against our
    /// synthetic (epoch-seconds) heights. `MigrationManagerLiveKey`'s simulated hook calls this
    /// instead whenever the engine is active (MOB-1480).
    func isNextTransferDue() -> Bool {
        withSnapshot { snapshot in
            MigrationSimulatorEngineDerivations.isNextTransferDue(snapshot: snapshot, now: self.simNow(snapshot))
        }
    }

    func summary() -> MigrationSummary {
        withSnapshot { MigrationSimulatorEngineDerivations.computeSummary(for: $0) }
    }

    func transferRows() -> [MigrationTransferRow] {
        withSnapshot { snapshot in
            MigrationSimulatorEngineDerivations.rows(
                for: snapshot,
                now: self.simNow(snapshot),
                broadcastingId: self.broadcastingId.withLock { $0 }
            )
        }
    }

    // MARK: - Note splitting

    func isNoteSplitNeeded() -> Bool {
        withSnapshot { snapshot in
            snapshot.mode == MigrationMode.privateScheduled
                && snapshot.state == MigrationState.notStarted
                && snapshot.notes.count == 1
        }
    }

    func prepareSplit() async -> NoteSplitProposal {
        let (net, seed) = withSnapshot { snapshot in
            (MigrationSimulatorEngineDerivations.netOfFee(snapshot.orchardBalance), snapshot.rngSeed)
        }
        let notes = MigrationSimulatorEngineDerivations.splitNotes(net: net, seed: seed)
        return NoteSplitProposal(outputNotes: notes, fee: MigrationSimulatorEngineDerivations.Constants.fee)
    }

    func submitSplit(_ proposal: NoteSplitProposal) async -> TransferResult {
        await submitSplitCore(outputNotes: proposal.outputNotes)
    }

    func submitSignedSplit(_ pczt: Pczt) async -> TransferResult {
        let proposal = await prepareSplit()
        return await submitSplitCore(outputNotes: proposal.outputNotes)
    }

    func confirmSplitNow() {
        withSnapshot { snapshot in
            guard snapshot.state == MigrationState.splitPendingConfirmation else { return }
            snapshot.state = MigrationState.readyToPropose
        }
    }

    // MARK: - Proposal / commit

    func selectMode(_ mode: MigrationMode) {
        withSnapshot { $0.mode = mode }
    }

    /// Stamps each `TransferProposal`'s height fields with a synthetic height derived from its
    /// `dueAt` (MOB-1480, supersedes spec §9.1 as an improvement): `nextExecutableAfterHeight` and
    /// `anchorHeight` both carry `dueAt`'s synthetic height, `expiryHeight` is one synthetic day
    /// past it. `dueAt` uses the exact same formula `signAndStore()` will seed
    /// `SimulatorTransfer.dueAt` with (`MigrationSimulatorEngineDerivations.dueAt`), so a
    /// transfer's proposed height and its later-stored due time never drift apart.
    func propose() async -> MigrationSchedule {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)

            if snapshot.mode == MigrationMode.immediate {
                let dueAt = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: 0, isImmediate: true, now: now)
                let height = MigrationSimulatorEngineDerivations.syntheticHeight(for: dueAt)
                let proposal = TransferProposal(
                    id: MigrationSimulatorEngineDerivations.makeTransferId(index: 0),
                    amount: snapshot.orchardBalance,
                    anchorHeight: height,
                    nextExecutableAfterHeight: height,
                    expiryHeight: height + MigrationSimulatorEngineDerivations.Constants.syntheticExpiryOffset
                )
                return MigrationSchedule(transfers: [proposal], estimatedDurationHours: 0)
            }

            // Pre-split preview (MOB-1480 QA fix): with the silent split running under the plan's
            // Confirm CTA, `notes` still holds the single unsplit note at propose time — but the
            // plan must show the post-split schedule the confirm will produce. `splitNotes` is
            // pure in `(net, seed)`, so this preview and the actual split yield identical notes.
            let notes: [Zatoshi]
            if snapshot.notes.count > 1 {
                notes = snapshot.notes
            } else {
                let previewed = MigrationSimulatorEngineDerivations.splitNotes(
                    net: MigrationSimulatorEngineDerivations.netOfFee(snapshot.orchardBalance),
                    seed: snapshot.rngSeed
                )
                notes = previewed.isEmpty ? [snapshot.orchardBalance] : previewed
            }
            let transfers = notes.enumerated().map { index, note -> TransferProposal in
                let dueAt = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: index, isImmediate: false, now: now)
                let height = MigrationSimulatorEngineDerivations.syntheticHeight(for: dueAt)
                return TransferProposal(
                    id: MigrationSimulatorEngineDerivations.makeTransferId(index: index),
                    amount: note,
                    anchorHeight: height,
                    nextExecutableAfterHeight: height,
                    expiryHeight: height + MigrationSimulatorEngineDerivations.Constants.syntheticExpiryOffset
                )
            }
            return MigrationSchedule(
                transfers: transfers,
                estimatedDurationHours: MigrationSimulatorEngineDerivations.scheduleDurationHours(transferCount: transfers.count)
            )
        }
    }

    func signAndStore(_ schedule: MigrationSchedule) async {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)
            let isImmediate = snapshot.mode == MigrationMode.immediate
            snapshot.transfers = schedule.transfers.enumerated().map { index, proposal in
                let dueAt = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: index, isImmediate: isImmediate, now: now)
                return SimulatorTransfer(id: proposal.id, index: index, amount: proposal.amount, dueAt: dueAt)
            }
            // Legitimately arrives while `.splitPendingConfirmation` (the UI's silent split commits
            // optimistically) — accept unconditionally; the pending 15s confirm task then no-ops
            // since it only acts while state is still `.splitPendingConfirmation`.
            snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
        }
    }

    // MARK: - Background execution

    func isSyncRequired() -> Bool {
        withSnapshot { $0.syncRequired }
    }

    func setSyncRequired(_ required: Bool) {
        withSnapshot { $0.syncRequired = required }
    }

    func executeNext(_ options: NetworkPrivacyOptions) async -> TransferResult? {
        let pendingIndex = withSnapshot { snapshot in
            snapshot.transfers.filter { $0.sentAt == nil }.min(by: { $0.index < $1.index })?.index
        }
        guard let targetIndex = pendingIndex else { return nil }

        let armed = withSnapshot { snapshot -> TransferResult? in
            guard let armed = snapshot.armedTransferResult else { return nil }
            snapshot.armedTransferResult = nil
            return armed
        }
        if let armed {
            return await apply(armed, toPendingIndex: targetIndex)
        }

        let isDue = withSnapshot { snapshot -> Bool in
            guard let transfer = snapshot.transfers.first(where: { $0.index == targetIndex }) else { return false }
            return self.simNow(snapshot) >= transfer.dueAt
        }
        guard isDue else { return nil }
        return await performSend(targetIndex: targetIndex)
    }

    // MARK: - Recovery

    func restart() async -> MigrationSchedule {
        withSnapshot { snapshot in
            snapshot.transfers.removeAll { $0.sentAt == nil }
            snapshot.armedTransferResult = nil
            snapshot.armedSplitFailure = false
            snapshot.syncRequired = false
            if snapshot.mode == MigrationMode.privateScheduled {
                let net = MigrationSimulatorEngineDerivations.netOfFee(snapshot.orchardBalance)
                snapshot.notes = MigrationSimulatorEngineDerivations.splitNotes(net: net, seed: snapshot.rngSeed)
            } else {
                snapshot.notes = snapshot.orchardBalance.amount > 0 ? [snapshot.orchardBalance] : []
            }
            snapshot.state = MigrationState.readyToPropose
            snapshot.lastBackgroundRunSummary = "restarted"
        }
        return await propose()
    }

    func rescheduleStalled() async {
        withSnapshot { snapshot in
            guard case MigrationState.requiresAttention(let reason) = snapshot.state,
                  case AttentionReason.transferStalled = reason else { return }

            let now = self.simNow(snapshot)
            let unsentInOrder = snapshot.transfers.filter { $0.sentAt == nil }.sorted { $0.index < $1.index }
            for (offset, transfer) in unsentInOrder.enumerated() {
                guard let index = snapshot.transfers.firstIndex(where: { $0.id == transfer.id }) else { continue }
                let step = MigrationSimulatorEngineDerivations.Constants.transferSpacing * Double(offset + 1)
                snapshot.transfers[index].dueAt = now.addingTimeInterval(step)
            }
            snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
            snapshot.lastBackgroundRunSummary = "rescheduled stalled transfer"
        }
    }

    func recreateInvalid() async {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)
            if case MigrationState.requiresAttention(let reason) = snapshot.state {
                if case AttentionReason.invalidTransfer(let transferId) = reason,
                   let index = snapshot.transfers.firstIndex(where: { $0.id == transferId }) {
                    let step = MigrationSimulatorEngineDerivations.Constants.transferSpacing
                    snapshot.transfers[index].dueAt = now.addingTimeInterval(step)
                } else if case AttentionReason.transferExpired = reason {
                    for index in snapshot.transfers.indices {
                        let transfer = snapshot.transfers[index]
                        let expiryWindow = MigrationSimulatorEngineDerivations.Constants.expiryWindow
                        guard transfer.sentAt == nil, now > transfer.dueAt.addingTimeInterval(expiryWindow) else { continue }
                        snapshot.transfers[index].dueAt = now.addingTimeInterval(
                            MigrationSimulatorEngineDerivations.Constants.transferSpacing
                        )
                    }
                }
            }
            snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
            snapshot.lastBackgroundRunSummary = "recreated invalid/expired transfer(s)"
        }
    }

    // MARK: - Keystone (PCZT)

    func fabricateNoteSplitPCZT() -> Pczt {
        let balance = orchardBalance()
        return MigrationSimulatorEngineDerivations.fabricatePczt(index: -1, amount: balance)
    }

    func fabricateMigrationPCZTs(_ schedule: MigrationSchedule) -> [Pczt] {
        schedule.transfers.enumerated().map { index, transfer in
            MigrationSimulatorEngineDerivations.fabricatePczt(index: index, amount: transfer.amount)
        }
    }

    func storeSignedBatch(_ pczts: [Pczt]) {
        withSnapshot { $0.signedBatchCount = pczts.count }
    }

    // MARK: - Lifecycle

    func initializePostUpgrade() {
        withSnapshot { _ in }
    }

    // MARK: - Debug controls

    func reset() {
        replaceSnapshot(SimulatorSnapshot.seeded())
    }

    func seed(orchard: Zatoshi, noteCount: Int) {
        withSnapshot { snapshot in
            snapshot.orchardBalance = orchard
            let count = max(1, noteCount)
            if count <= 1 {
                snapshot.notes = orchard.amount > 0 ? [orchard] : []
            } else {
                let net = MigrationSimulatorEngineDerivations.netOfFee(orchard)
                snapshot.notes = MigrationSimulatorEngineDerivations.splitNotes(net: net, seed: snapshot.rngSeed, countOverride: count)
            }
            snapshot.transfers = []
            snapshot.armedTransferResult = nil
            snapshot.armedSplitFailure = false
            snapshot.syncRequired = false
            snapshot.dustRemainder = Zatoshi.zero
            snapshot.signedBatchCount = 0
            snapshot.state = MigrationState.notStarted
            snapshot.lastBackgroundRunSummary = "seeded \(orchard.amount) zats, \(count) note(s)"
        }
    }

    func applyPreset(_ preset: SimulatorPreset) {
        withSnapshot { snapshot in
            MigrationSimulatorEngineDerivations.applyPreset(preset, to: &snapshot, now: self.simNow(snapshot))
        }
    }

    func advanceTime(by interval: TimeInterval) {
        withSnapshot { $0.timeOffset += interval }
    }

    func makeNextTransferDueNow() {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)
            guard let earliest = snapshot.transfers.filter({ $0.sentAt == nil }).min(by: { $0.index < $1.index }),
                  let index = snapshot.transfers.firstIndex(where: { $0.id == earliest.id }) else { return }
            snapshot.transfers[index].dueAt = now
        }
    }

    func armTransferResult(_ result: TransferResult) {
        withSnapshot { $0.armedTransferResult = result }
    }

    func armSplitFailure() {
        withSnapshot { $0.armedSplitFailure = true }
    }

    func readout() -> SimulatorReadout {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)
            return SimulatorReadout(
                isActive: snapshot.isActive,
                state: snapshot.state,
                mode: snapshot.mode,
                orchardBalance: snapshot.orchardBalance,
                timeOffset: snapshot.timeOffset,
                rows: MigrationSimulatorEngineDerivations.rows(
                    for: snapshot,
                    now: now,
                    broadcastingId: self.broadcastingId.withLock { $0 }
                ),
                signedBatchCount: snapshot.signedBatchCount,
                armedResultDescription: MigrationSimulatorEngineDerivations.describeArmedResult(
                    snapshot.armedTransferResult,
                    splitFailureArmed: snapshot.armedSplitFailure
                ),
                isSplitPending: snapshot.state == MigrationState.splitPendingConfirmation,
                lastBackgroundRunSummary: snapshot.lastBackgroundRunSummary
            )
        }
    }
}

// MARK: - Private helpers

private extension MigrationSimulatorEngine {
    func simNow(_ snapshot: SimulatorSnapshot) -> Date {
        Date().addingTimeInterval(snapshot.timeOffset)
    }

    /// Every public accessor/mutator funnels through here: recomputes time-driven derived state
    /// first (so reads/mutations see fresh truth), runs `body`, then persists and — only if the
    /// resulting `MigrationState` actually changed — emits to the state stream.
    @discardableResult
    func withSnapshot<T: Sendable>(_ body: @Sendable (inout SimulatorSnapshot) -> T) -> T {
        let (result, updated) = snapshotLock.withLock { snapshot -> (T, SimulatorSnapshot) in
            MigrationSimulatorEngineDerivations.recompute(&snapshot, now: Date().addingTimeInterval(snapshot.timeOffset))
            let result = body(&snapshot)
            return (result, snapshot)
        }
        store.save(updated)
        if stateSubject.value != updated.state {
            stateSubject.send(updated.state)
        }
        return result
    }

    func replaceSnapshot(_ fresh: SimulatorSnapshot) {
        snapshotLock.withLock { $0 = fresh }
        store.save(fresh)
        if stateSubject.value != fresh.state {
            stateSubject.send(fresh.state)
        }
    }

    /// Applies a (just-consumed) armed result to `targetIndex`, bypassing due-gating entirely —
    /// arming a result is a deliberate debug action meant to force the NEXT `executeNext` call's
    /// outcome regardless of timing.
    func apply(_ armed: TransferResult, toPendingIndex targetIndex: Int) async -> TransferResult {
        switch armed {
        case TransferResult.invalidNote:
            return withSnapshot { snapshot in
                guard let transfer = snapshot.transfers.first(where: { $0.index == targetIndex }) else {
                    return TransferResult.invalidNote
                }
                snapshot.state = MigrationState.requiresAttention(AttentionReason.invalidTransfer(transferId: transfer.id))
                snapshot.lastBackgroundRunSummary = "armed invalidNote -> transfer \(targetIndex + 1) invalid"
                return TransferResult.invalidNote
            }

        case TransferResult.expired:
            return withSnapshot { snapshot in
                let now = self.simNow(snapshot)
                if let index = snapshot.transfers.firstIndex(where: { $0.index == targetIndex }) {
                    let pastExpiry = -(MigrationSimulatorEngineDerivations.Constants.expiryWindow + 1)
                    snapshot.transfers[index].dueAt = now.addingTimeInterval(pastExpiry)
                }
                snapshot.state = MigrationState.requiresAttention(AttentionReason.transferExpired)
                snapshot.lastBackgroundRunSummary = "armed expired -> transfer \(targetIndex + 1) expired"
                return TransferResult.expired
            }

        case TransferResult.networkError(let retryable):
            return withSnapshot { snapshot in
                let now = self.simNow(snapshot)
                if let index = snapshot.transfers.firstIndex(where: { $0.index == targetIndex }) {
                    snapshot.transfers[index].dueAt = now.addingTimeInterval(-MigrationSimulatorEngineDerivations.Constants.overdueGrace)
                }
                snapshot.state = MigrationState.requiresAttention(
                    AttentionReason.transferStalled(transferNumber: targetIndex + 1)
                )
                snapshot.lastBackgroundRunSummary = "armed networkError -> stalled"
                return TransferResult.networkError(retryable: retryable)
            }

        case TransferResult.success:
            return await performSend(targetIndex: targetIndex)
        }
    }

    /// Simulates ~1.5s of broadcast latency (`isBroadcasting` set on the target row throughout),
    /// then marks it sent, decrements the balance, and rolls the whole migration to `.complete`
    /// once every transfer has been sent.
    func performSend(targetIndex: Int) async -> TransferResult {
        guard let transferId = withSnapshot({ snapshot in
            snapshot.transfers.first(where: { $0.index == targetIndex })?.id
        }) else {
            return TransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: "missing"))
        }

        broadcastingId.withLock { $0 = transferId }
        try? await Task.sleep(for: .seconds(MigrationSimulatorEngineDerivations.Constants.broadcastLatency))
        broadcastingId.withLock { $0 = nil }

        return withSnapshot { snapshot in
            guard let index = snapshot.transfers.firstIndex(where: { $0.id == transferId }),
                  snapshot.transfers[index].sentAt == nil else {
                return TransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: transferId))
            }

            let now = self.simNow(snapshot)
            snapshot.transfers[index].sentAt = now
            let amount = snapshot.transfers[index].amount
            let total = snapshot.transfers.count
            let allSent = snapshot.transfers.allSatisfy { $0.sentAt != nil }

            if allSent {
                snapshot.orchardBalance = snapshot.dustRemainder
                snapshot.state = MigrationState.complete
                snapshot.lastBackgroundRunSummary = "sent #\(index + 1) of \(total) -> complete"
            } else {
                snapshot.orchardBalance = Zatoshi(max(0, snapshot.orchardBalance.amount - amount.amount))
                snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
                snapshot.lastBackgroundRunSummary = "sent #\(index + 1) of \(total)"
            }
            return TransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: transferId))
        }
    }

    /// Shared core for `submitSplit`/`submitSignedSplit`: consumes `armedSplitFailure` if set
    /// (returning a network error with NO state change), otherwise commits `outputNotes` and arms
    /// the 15s confirm task.
    func submitSplitCore(outputNotes: [Zatoshi]) async -> TransferResult {
        let shouldFail = withSnapshot { snapshot -> Bool in
            guard snapshot.armedSplitFailure else { return false }
            snapshot.armedSplitFailure = false
            return true
        }
        if shouldFail {
            return TransferResult.networkError(retryable: true)
        }

        withSnapshot { snapshot in
            snapshot.notes = outputNotes
            snapshot.state = MigrationState.splitPendingConfirmation
            snapshot.splitSubmittedAt = self.simNow(snapshot)
        }
        armSplitConfirmTask()
        return TransferResult.success(
            txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "split", discriminator: "\(outputNotes.count)")
        )
    }

    /// The one real timer in the engine: after `splitConfirmDelay`, flips
    /// `.splitPendingConfirmation -> .readyToPropose` — but only if state is STILL
    /// `.splitPendingConfirmation` by then (a `signAndStore` arriving first moves state to
    /// `.inProgress`, and this task correctly no-ops).
    func armSplitConfirmTask() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MigrationSimulatorEngineDerivations.Constants.splitConfirmDelay))
            self?.withSnapshot { snapshot in
                guard snapshot.state == MigrationState.splitPendingConfirmation else { return }
                snapshot.state = MigrationState.readyToPropose
            }
        }
    }
}
