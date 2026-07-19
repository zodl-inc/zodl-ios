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
//  MOB-1496: adapted onto the real SDK's model types (`MigrationTransferProposal`,
//  `MigrationTransferResult`, `MigrationAttentionReason`, `MigrationNetworkPrivacyOptions`) and
//  Keystone PCZT wrapper types (`MigrationUnsignedTransferPczt`/`MigrationSignedTransferPczt`) —
//  the SDK's `MigrationAttentionReason` has no `.transferStalled` case, so "stalled" is now a pure
//  derivation elsewhere (`MigrationDerivations.bannerVariant`) rather than a state this engine
//  ever constructs; see `rescheduleOverdue()`'s doc for how the old `rescheduleStalled()` adapts.
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

    func submitSplit(_ proposal: NoteSplitProposal) async -> MigrationTransferResult {
        await submitSplitCore(outputNotes: proposal.outputNotes)
    }

    func submitSignedSplit(_ pczt: Data) async -> MigrationTransferResult {
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

    /// Stamps each `MigrationTransferProposal`'s height fields with a synthetic height derived
    /// from its `dueAt` (MOB-1480, supersedes spec §9.1 as an improvement): `nextExecutableAfterHeight`
    /// and `anchorHeight` both carry `dueAt`'s synthetic height, `expiryHeight` is one synthetic
    /// day past it. `dueAt` uses the exact same formula `signAndStore()` will seed
    /// `SimulatorTransfer.dueAt` with (`MigrationSimulatorEngineDerivations.dueAt`), so a
    /// transfer's proposed height and its later-stored due time never drift apart. Serves BOTH
    /// `proposeMigrationTransfers` (scheduled mode) and `proposeImmediateMigration` (immediate
    /// mode) — the branch below is keyed on the snapshot's OWN `mode`, not a caller-supplied flag,
    /// so either simulator override can call this identically (MOB-1496).
    func propose() async -> MigrationSchedule {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)

            if snapshot.mode == MigrationMode.immediate {
                let dueAt = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: 0, isImmediate: true, now: now)
                let height = MigrationSimulatorEngineDerivations.syntheticHeight(for: dueAt)
                let proposal = MigrationTransferProposal(
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
            let transfers = notes.enumerated().map { index, note -> MigrationTransferProposal in
                let dueAt = MigrationSimulatorEngineDerivations.dueAt(forTransferAt: index, isImmediate: false, now: now)
                let height = MigrationSimulatorEngineDerivations.syntheticHeight(for: dueAt)
                return MigrationTransferProposal(
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

    func executeNext(_ options: MigrationNetworkPrivacyOptions) async -> MigrationTransferResult? {
        let pendingIndex = withSnapshot { snapshot in
            snapshot.transfers.filter { $0.sentAt == nil }.min(by: { $0.index < $1.index })?.index
        }
        guard let targetIndex = pendingIndex else { return nil }

        let armed = withSnapshot { snapshot -> MigrationTransferResult? in
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

    // MARK: - Dust resolution (MOB-1487)

    /// "Lock balance" on Migration Complete: marks the dust remainder unspendable. Persisted so
    /// re-entering the complete screen lands on the locked confirmation instead of re-offering.
    func lockDust() {
        withSnapshot { snapshot in
            guard snapshot.dustRemainder.amount > 0 else { return }
            snapshot.isDustLocked = true
            snapshot.lastBackgroundRunSummary = "dust locked"
        }
    }

    func isDustLocked() -> Bool {
        withSnapshot { $0.isDustLocked }
    }

    /// "Migrate anyway" on Migration Complete: broadcasts the dust remainder as one final
    /// transfer. Same broadcast latency as `performSend`; `nil` when there is nothing sweepable
    /// (no dust, or already locked) so the Sending screen's failure sheet surfaces misuse.
    func migrateDust() async -> MigrationTransferResult? {
        let hasSweepableDust = withSnapshot { snapshot in
            snapshot.dustRemainder.amount > 0 && !snapshot.isDustLocked
        }
        guard hasSweepableDust else { return nil }

        try? await Task.sleep(for: .seconds(MigrationSimulatorEngineDerivations.Constants.broadcastLatency))

        return withSnapshot { snapshot -> MigrationTransferResult? in
            guard snapshot.dustRemainder.amount > 0, !snapshot.isDustLocked else { return nil }
            snapshot.dustRemainder = Zatoshi.zero
            snapshot.orchardBalance = Zatoshi.zero
            snapshot.lastBackgroundRunSummary = "dust migrated"
            return MigrationTransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "dust", discriminator: "sweep"))
        }
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

    /// MOB-1496: simulator counterpart of the real SDK's `rescheduleOverdueMigrationTransfer(
    /// accountUUID:)`. The real member is a pure read (reports the next height-due proposal so the
    /// host can re-arm its own background window — "the local decision not to broadcast before
    /// that window IS the reschedule", per the SDK's own doc), but the coordinator's `.reschedule`
    /// flow (`MigrationCoordFlowCoordinator.swift`) expects an actual state change it can then
    /// re-read rows/summary from — so, matching this engine's existing "make the UI outcome
    /// observable" precedent (`lockDust`'s pause, `performSend`'s broadcast latency), this pushes
    /// the earliest overdue transfer's `dueAt` forward by one `transferSpacing` step (un-stalling
    /// it) and returns a `MigrationTransferProposal` built from the result — a no-op (returns
    /// `nil`) when nothing is actually overdue. Was named `rescheduleStalled()` pre-MOB-1496, back
    /// when the engine could set a literal `.transferStalled` state; that state no longer exists
    /// (see the file-level doc), so this now keys off `hasOverdue()`'s time math instead.
    func rescheduleOverdue() async -> MigrationTransferProposal? {
        withSnapshot { snapshot in
            let now = self.simNow(snapshot)
            guard MigrationSimulatorEngineDerivations.hasOverdue(snapshot: snapshot, now: now),
                  let earliest = snapshot.transfers.filter({ $0.sentAt == nil }).min(by: { $0.index < $1.index }),
                  let index = snapshot.transfers.firstIndex(where: { $0.id == earliest.id }) else {
                return nil
            }

            let step = MigrationSimulatorEngineDerivations.Constants.transferSpacing
            let newDueAt = now.addingTimeInterval(step)
            snapshot.transfers[index].dueAt = newDueAt
            snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
            snapshot.lastBackgroundRunSummary = "rescheduled overdue transfer"

            let height = MigrationSimulatorEngineDerivations.syntheticHeight(for: newDueAt)
            return MigrationTransferProposal(
                id: snapshot.transfers[index].id,
                amount: snapshot.transfers[index].amount,
                anchorHeight: height,
                nextExecutableAfterHeight: height,
                expiryHeight: height + MigrationSimulatorEngineDerivations.Constants.syntheticExpiryOffset
            )
        }
    }

    // MARK: - Keystone (PCZT)

    func fabricateNoteSplitPCZT() -> Data {
        let balance = orchardBalance()
        return MigrationSimulatorEngineDerivations.fabricatePczt(index: -1, amount: balance)
    }

    func fabricateMigrationPCZTs(_ schedule: MigrationSchedule) -> [MigrationUnsignedTransferPczt] {
        schedule.transfers.enumerated().map { index, transfer in
            MigrationUnsignedTransferPczt(
                id: transfer.id,
                pczt: MigrationSimulatorEngineDerivations.fabricatePczt(index: index, amount: transfer.amount)
            )
        }
    }

    func storeSignedBatch(_ signed: [MigrationSignedTransferPczt]) {
        withSnapshot { $0.signedBatchCount = signed.count }
    }

    // MARK: - Lifecycle

    func initializePostUpgrade() {
        withSnapshot { _ in }
    }

    // MARK: - Debug controls

    func reset() {
        // Reset re-seeds the simulation's DATA but preserves the activation toggle — the panel's
        // "Reset simulation" must not silently turn the (opt-in) simulation back off.
        let wasActive = isActive
        var fresh = SimulatorSnapshot.seeded()
        fresh.isActive = wasActive
        replaceSnapshot(fresh)
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

    func armTransferResult(_ result: MigrationTransferResult) {
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
                lastBackgroundRunSummary: snapshot.lastBackgroundRunSummary,
                dustRemainder: snapshot.dustRemainder,
                isDustLocked: snapshot.isDustLocked
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
    ///
    /// MOB-1496: the `.networkError` case used to escalate `state` to a literal
    /// `.requiresAttention(.transferStalled)` — that case no longer exists on the SDK's
    /// `MigrationAttentionReason`, so it now just leaves `state` at `.inProgress` (recomputed) and
    /// relies on the `dueAt` shift below (past `overdueGrace`) for `hasOverdue()`'s time math to
    /// pick up, exactly like `MigrationSimulatorEngineDerivations.applyPreset`'s `.transferStalled`
    /// case.
    func apply(_ armed: MigrationTransferResult, toPendingIndex targetIndex: Int) async -> MigrationTransferResult {
        switch armed {
        case MigrationTransferResult.invalidNote:
            return withSnapshot { snapshot in
                guard let transfer = snapshot.transfers.first(where: { $0.index == targetIndex }) else {
                    return MigrationTransferResult.invalidNote
                }
                snapshot.state = MigrationState.requiresAttention(MigrationAttentionReason.invalidTransfer(transferId: transfer.id))
                snapshot.lastBackgroundRunSummary = "armed invalidNote -> transfer \(targetIndex + 1) invalid"
                return MigrationTransferResult.invalidNote
            }

        case MigrationTransferResult.expired:
            return withSnapshot { snapshot in
                let now = self.simNow(snapshot)
                if let index = snapshot.transfers.firstIndex(where: { $0.index == targetIndex }) {
                    let pastExpiry = -(MigrationSimulatorEngineDerivations.Constants.expiryWindow + 1)
                    snapshot.transfers[index].dueAt = now.addingTimeInterval(pastExpiry)
                }
                snapshot.state = MigrationState.requiresAttention(MigrationAttentionReason.transferExpired)
                snapshot.lastBackgroundRunSummary = "armed expired -> transfer \(targetIndex + 1) expired"
                return MigrationTransferResult.expired
            }

        case MigrationTransferResult.networkError(let retryable):
            return withSnapshot { snapshot in
                let now = self.simNow(snapshot)
                if let index = snapshot.transfers.firstIndex(where: { $0.index == targetIndex }) {
                    let pastOverdue = -(MigrationSimulatorEngineDerivations.Constants.overdueGrace + 1)
                    snapshot.transfers[index].dueAt = now.addingTimeInterval(pastOverdue)
                }
                snapshot.state = MigrationState.inProgress(MigrationSimulatorEngineDerivations.computeProgress(for: snapshot))
                snapshot.lastBackgroundRunSummary = "armed networkError -> overdue"
                return MigrationTransferResult.networkError(retryable: retryable)
            }

        case MigrationTransferResult.success:
            return await performSend(targetIndex: targetIndex)
        }
    }

    /// Simulates ~1.5s of broadcast latency (`isBroadcasting` set on the target row throughout),
    /// then marks it sent, decrements the balance, and rolls the whole migration to `.complete`
    /// once every transfer has been sent.
    func performSend(targetIndex: Int) async -> MigrationTransferResult {
        guard let transferId = withSnapshot({ snapshot in
            snapshot.transfers.first(where: { $0.index == targetIndex })?.id
        }) else {
            return MigrationTransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: "missing"))
        }

        broadcastingId.withLock { $0 = transferId }
        try? await Task.sleep(for: .seconds(MigrationSimulatorEngineDerivations.Constants.broadcastLatency))
        broadcastingId.withLock { $0 = nil }

        return withSnapshot { snapshot in
            guard let index = snapshot.transfers.firstIndex(where: { $0.id == transferId }),
                  snapshot.transfers[index].sentAt == nil else {
                return MigrationTransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: transferId))
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
            return MigrationTransferResult.success(txId: MigrationSimulatorEngineDerivations.makeTxId(prefix: "xfer", discriminator: transferId))
        }
    }

    /// Shared core for `submitSplit`/`submitSignedSplit`: consumes `armedSplitFailure` if set
    /// (returning a network error with NO state change), otherwise commits `outputNotes` and arms
    /// the 15s confirm task.
    func submitSplitCore(outputNotes: [Zatoshi]) async -> MigrationTransferResult {
        let shouldFail = withSnapshot { snapshot -> Bool in
            guard snapshot.armedSplitFailure else { return false }
            snapshot.armedSplitFailure = false
            return true
        }
        if shouldFail {
            return MigrationTransferResult.networkError(retryable: true)
        }

        withSnapshot { snapshot in
            snapshot.notes = outputNotes
            snapshot.state = MigrationState.splitPendingConfirmation
            snapshot.splitSubmittedAt = self.simNow(snapshot)
        }
        armSplitConfirmTask()
        return MigrationTransferResult.success(
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
