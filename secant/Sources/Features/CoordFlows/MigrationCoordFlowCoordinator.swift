//
//  MigrationCoordFlowCoordinator.swift
//  Zashi
//
//  Routing brain for `MigrationCoordFlow` (MOB-1466): re-entry (`.onAppear`), the chaining table
//  from Entry through Complete, and the shared permission-step helper (BackgroundDelivery ->
//  Notifications -> TransferPlan). See the MOB-1466 implementation spec's `MigrationCoordFlow`
//  section for the full chaining table this mirrors row by row.
//
//  MOB-1468 (Keystone) adds a QR sign/scan round-trip ahead of the two signing sources
//  (TransferPlan/ReviewTransfer): each delegates `.keystoneSignRequested(pczts)` instead of signing
//  locally, which sets `pendingKeystoneSigning` and pushes `keystoneSign`; `keystoneSign(.delegate
//  (.getSignature))` pushes `scan` configured with the migration batch checker; `scan(.foundPCZTBatch
//  (signed))` stores the signed PCZTs and resumes whichever chain the source represents, popping both
//  pushed elements and clearing the context. `keystoneSign(.delegate(.rejected))` pops back to the
//  signing source with its state untouched (no partial storage ever happens on that path). See the
//  "Keystone signing" section below.
//
//  MOB-1478 reshapes the scheduled entry chain and the note-split lifecycle:
//  - W2: the full-screen Network Privacy step is replaced by a coordinator-owned Tor bottom sheet.
//    `presentTorSheet`/`confirmTorSheet` gate the two points that used to push Network Privacy —
//    Entry (immediate mode) and How This Works (scheduled mode) — behind the same
//    `walletStorage.exportTorSetupFlag()` check as before.
//  - W3: Entry's scheduled/private path now always pushes the new `howItWorks` screen (no more
//    `isNoteSplitNeeded()` branch at Entry).
//  - W4: note splitting leaves forward routing entirely — `MigrationNoteSplit` is reached only via
//    re-entry (`reentryRoute() == .noteSplitProgress`), so it no longer requests Keystone signing;
//    `KeystoneSigningContext` lost its `.noteSplit` case, and `MigrationTransferPlan`'s Keystone batch
//    now carries the split PCZT itself, when needed.
//  - W7: `Status`'s reschedule lands `.rescheduleCompleted` on the SAME status element instead of
//    pushing a new `TransferPlan`.
//  - W8: `nextPermissionStepResult()` picks the Notifications variant off `isManualDelivery()`.
//  - W10: the Keystone scan push sets `instructions`/`forceLibraryToHide`.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension MigrationCoordFlow {
    func coordinatorReduce() -> Reduce<MigrationCoordFlow.State, MigrationCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                // MARK: - Self: onAppear (re-entry)

            case .onAppear:
                guard state.path.isEmpty else { return .none }
                return .run { send in
                    let pathState = await reentryPathState()
                    await send(.pushNextPermissionStep(PermissionStepResult(pathState: pathState)))
                }

            case .pushNextPermissionStep(let result):
                if let pathState = result.pathState {
                    state.path.append(pathState)
                }
                return .none

                // MARK: - Entry

            case .entry(.delegate(.chose(let mode))):
                state.mode = mode
                migrationManager.setMigrationMode(mode)
                sdkSynchronizer.selectMigrationMode(mode)

                switch mode {
                case .immediate:
                    // Skip the Tor sheet iff the app-wide Tor setup flag is on — in that case
                    // `useTor` is implicitly `true` and Review is pushed directly; otherwise the
                    // sheet is shown so the user can opt in explicitly. Both checks here are
                    // synchronous SDK/dependency reads, so no effect is needed.
                    if walletStorage.exportTorSetupFlag() == true {
                        state.networkPrivacyOptions.useTor = true
                        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                    } else {
                        presentTorSheet(destination: .reviewTransfer, state: &state)
                    }
                    return .none

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

                // MARK: - HowItWorks (MOB-1478 W3)

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // Same Tor-sheet gate as Entry's immediate branch above, just reached later in the
                // scheduled chain.
                if walletStorage.exportTorSetupFlag() == true {
                    state.networkPrivacyOptions.useTor = true
                    return .run { send in
                        await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                    }
                }
                presentTorSheet(destination: .permissionChain, state: &state)
                return .none

                // MARK: - Tor bottom sheet (MOB-1478 W2)

            case .torSheet(.delegate(.gotIt)):
                return confirmTorSheet(state: &state)

            case .torSheetPresentationChanged(let isPresented):
                state.isTorSheetPresented = isPresented
                // `false` covers both an explicit "Got it" (which already ran `confirmTorSheet`
                // itself, so `pendingTorDestination` is already `nil` and this is a harmless no-op)
                // and a swipe-to-dismiss, which never routed through `.delegate(.gotIt)` at all —
                // the spec treats both identically, so this is the swipe path's own trigger.
                guard !isPresented else { return .none }
                return confirmTorSheet(state: &state)

                // MARK: - NoteSplit (re-entry-only, MOB-1478 W4)

            case .path(.element(id: let id, action: .noteSplit(.delegate(.continued)))):
                // Forward routing never pushes `.noteSplit` any more (the split now runs silently
                // under the TransferPlan/ReviewTransfer commit CTAs), so every reachable `.noteSplit`
                // element is a re-entry root and this always takes the `isFlowRoot` branch in
                // practice. The non-root branch is kept defensively (the exhaustive shape this
                // reducer already had) rather than deleted.
                if case .noteSplit(let noteSplitState) = state.path[id: id], noteSplitState.isFlowRoot {
                    return .send(.flowFinished)
                }
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

                // MARK: - BackgroundDelivery

            case .path(.element(id: _, action: .backgroundDelivery(.delegate(.continued(let backgroundAllowed))))):
                if !backgroundAllowed {
                    migrationManager.setManualDelivery(true)
                }
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

                // MARK: - Notifications

            case .path(.element(id: _, action: .notifications(.delegate(.continued)))):
                return .run { send in
                    await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                }

                // MARK: - TransferPlan

            case .path(.element(id: _, action: .transferPlan(.delegate(.confirmed)))):
                guard case let .transferPlan(planState) = state.path.last else { return .none }

                // Rescheduled variant (`requiresSigning == false`): its confirm is a plain
                // acknowledgment of an already-committed reschedule (`scheduleFirstWindow()` ran
                // once already, at reschedule-initiation) — no re-sign, no terminal `.scheduled`
                // screen, straight to `.flowFinished` ("Got-it" per the spec).
                guard planState.requiresSigning else {
                    return .send(.flowFinished)
                }

                return transferPlanPostConfirmChain(variant: planState.variant, state: &state)

                // MARK: - ReviewTransfer

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                var sendingState = MigrationSending.State(totalCount: 1)
                sendingState.networkPrivacyOptions = state.networkPrivacyOptions
                state.path.append(.sending(sendingState))
                return .none

                // MARK: - Keystone signing (MOB-1468)

            case .path(.element(id: _, action: .transferPlan(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .planCommit
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .immediateReview
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.getSignature)))):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystoneMigrationBatchScanChecker]
                // MOB-1478 (W10): matches the design's single centered flash control (precedent:
                // `AddKeystoneHWWalletCoordFlowCoordinator` already sets `forceLibraryToHide`).
                scanState.instructions = String(localizable: .migrationKeystoneScanInstructions)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .scan(.foundPCZTBatch(let signed)))):
                guard let context = state.pendingKeystoneSigning else { return .none }

                // Empty batch: nothing decoded to a usable signed PCZT — this abandons the signing
                // session like a rejection (deferred pop of scan + sign back to the initiating
                // screen, context cleared) and never stores anything (no-partial-storage invariant).
                // The user re-initiates from the confirm button.
                guard !signed.isEmpty else { return .send(.keystoneScanAbandoned) }

                return .run { [sdkSynchronizer] send in
                    await sdkSynchronizer.storeSignedMigrationTransactions(signed)
                    await send(.keystoneSigningSubmitted(context: context))
                }

            case .keystoneSigningSubmitted(let context):
                return resumeAfterKeystoneSigning(context: context, state: &state)

            case .path(.element(id: _, action: .keystoneSign(.delegate(.rejected)))):
                // No-partial-storage invariant: nothing was stored — just pop back to the signing
                // source with its state untouched (plan/review still unsigned) and clear the
                // context. The pop is deferred to a follow-up self-action (mirrors
                // `sendNowCompleted`'s deferred pop) rather than done inline here: `.forEach(\.path,
                // action:)` still needs to deliver this SAME action to the `keystoneSign` element
                // after this case returns, and popping it first would leave `.forEach` with no
                // element to deliver to (a TCA "missing element" runtime error).
                return .send(.keystoneSignRejected)

            case .keystoneSignRejected:
                state.pendingKeystoneSigning = nil
                let _ = state.path.popLast()
                return .none

            case .keystoneScanAbandoned:
                state.pendingKeystoneSigning = nil
                let _ = state.path.popLast()
                let _ = state.path.popLast()
                return .none

                // MARK: - Sending

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                if state.mode == .immediate {
                    migrationManager.acknowledgeComplete()
                    return .send(.flowFinished)
                }

                let hasStatusBeneath = state.path.contains { $0.is(\.status) }
                if hasStatusBeneath {
                    return .run { [sdkSynchronizer] send in
                        await send(.sendNowCompleted(rows: sdkSynchronizer.migrationTransfers()))
                    }
                }

                // Manual-first-transfer path: no `.status` yet on the path — push a fresh one.
                return .run { send in
                    await send(.pushHydratedStatus(await statusProgressState(isFlowRoot: false)))
                }

                // MARK: - Self: pushHydratedStatus / pushHydratedPathState / sendNowCompleted

            case .pushHydratedStatus(let statusState):
                state.path.append(.status(statusState))
                return .none

            case .pushHydratedPathState(let pathState):
                state.path.append(pathState)
                return .none

            case .sendNowCompleted(let rows):
                // Pop the Sending element and refresh the `.status` element now on top.
                let _ = state.path.popLast()
                guard let statusId = state.path.ids.last, case .status(var statusState) = state.path.last else {
                    return .none
                }
                statusState.rows = IdentifiedArrayOf(uniqueElements: rows)
                state.path[id: statusId] = .status(statusState)
                return .none

                // MARK: - Status

            case .path(.element(id: _, action: .status(.delegate(.sendNow)))):
                let networkPrivacyOptions = state.networkPrivacyOptions
                return .run { [sdkSynchronizer] send in
                    let rows = sdkSynchronizer.migrationTransfers()
                    let overdueCount = rows.filter { $0.status == MigrationTransferRow.Status.overdue }.count
                    var sendingState = MigrationSending.State(totalCount: max(overdueCount, 1))
                    sendingState.networkPrivacyOptions = networkPrivacyOptions
                    await send(.pushHydratedPathState(.sending(sendingState)))
                }

            case .path(.element(id: let id, action: .status(.delegate(.reschedule)))):
                if case .status(var statusState) = state.path[id: id] {
                    statusState.isRescheduling = true
                    state.path[id: id] = .status(statusState)
                }
                // MOB-1478 (W7): lands `.rescheduleCompleted` on the SAME status element instead of
                // pushing a fresh `TransferPlan` — `MigrationStatus` itself now owns the
                // post-reschedule confirmation presentation.
                return .run { [migrationBGScheduler, sdkSynchronizer, id] send in
                    await sdkSynchronizer.rescheduleStalledMigrationTransfer()
                    await migrationBGScheduler.scheduleFirstWindow()
                    let rows = sdkSynchronizer.migrationTransfers()
                    let totalDurationHours = sdkSynchronizer.migrationSummary().estimatedDurationHours
                    await send(
                        .path(
                            .element(
                                id: id,
                                action: .status(.rescheduleCompleted(rows: rows, totalDurationHours: totalDurationHours))
                            )
                        )
                    )
                }

                // MARK: - Recovery

            case .path(.element(id: _, action: .recovery(.delegate(.recreate)))):
                return .run { [sdkSynchronizer] send in
                    let schedule = await sdkSynchronizer.restartCurrentMigrationStep()
                    let planState = recreatedPlanState(schedule: schedule)
                    await send(.pushHydratedPathState(.transferPlan(planState)))
                }

                // MARK: - Flow-root closes / terminal delegates -> .flowFinished

            case .path(.element(id: _, action: .complete(.delegate(.done)))):
                migrationManager.acknowledgeComplete()
                return .send(.flowFinished)

            case .path(.element(id: _, action: .status(.delegate(.done)))),
                 .path(.element(id: _, action: .scheduled(.delegate(.done)))),
                 .path(.element(id: _, action: .recovery(.delegate(.close)))),
                 .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))):
                return .send(.flowFinished)

            default: return .none
            }
        }
    }

    // MARK: - TransferPlan: shared post-confirm chain (software `.confirmed` + Keystone `planCommit`)

    /// Scheduled/recreated push `.scheduled`; manual pushes `.sending` (totalCount 1, current
    /// network-privacy options) — then schedules the first background window either way. Shared by
    /// the software `TransferPlan.delegate(.confirmed)` row and the Keystone `planCommit` resume
    /// (`resumeAfterKeystoneSigning`), which both reach this point with a signed+stored schedule
    /// (and, when needed, an already-signed+submitted note split — MOB-1478 W4).
    private func transferPlanPostConfirmChain(
        variant: MigrationTransferPlan.State.Variant,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        switch variant {
        case .scheduled, .recreated:
            state.path.append(.scheduled(MigrationScheduled.State()))
        case .manual:
            var sendingState = MigrationSending.State(totalCount: 1)
            sendingState.networkPrivacyOptions = state.networkPrivacyOptions
            state.path.append(.sending(sendingState))
        }
        return .run { [migrationBGScheduler] _ in await migrationBGScheduler.scheduleFirstWindow() }
    }

    // MARK: - Keystone signing (MOB-1468): resume after store

    /// Pops `scan`+`keystoneSign` (the two elements the QR round-trip pushed) and resumes whichever
    /// chain `context` represents, mirroring how the equivalent software `.confirmed` row would
    /// proceed from the now-topmost signing-source element:
    /// - `.planCommit`: the `transferPlan` element now on top never re-signs again — resumes via
    ///   `transferPlanPostConfirmChain(variant:state:)`, identical to the software `.confirmed` row.
    /// - `.immediateReview`: pushes `.sending`, identical to the software `reviewTransfer.confirmed`
    ///   row.
    ///
    /// Clears `pendingKeystoneSigning` in every case.
    private func resumeAfterKeystoneSigning(
        context: MigrationCoordFlow.KeystoneSigningContext,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        state.pendingKeystoneSigning = nil
        state.path.removeLast(2)

        switch context {
        case .planCommit:
            guard case let .transferPlan(planState) = state.path.last else { return .none }
            return transferPlanPostConfirmChain(variant: planState.variant, state: &state)

        case .immediateReview:
            var sendingState = MigrationSending.State(totalCount: 1)
            sendingState.networkPrivacyOptions = state.networkPrivacyOptions
            state.path.append(.sending(sendingState))
            return .none
        }
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): present + confirm/dismiss

    /// Presents the Tor sheet fresh (reset toggle to its no-bias default) and stashes `destination`
    /// to resume once the user confirms or swipes the sheet away.
    private func presentTorSheet(
        destination: MigrationCoordFlow.PendingTorDestination,
        state: inout MigrationCoordFlow.State
    ) {
        state.torSheetState = MigrationTorSheet.State()
        state.pendingTorDestination = destination
        state.isTorSheetPresented = true
    }

    /// "Got it" and swipe-to-dismiss both land here (the spec treats them identically): persists
    /// whatever `isTorOn` is currently showing exactly as `MigrationNetworkPrivacyStore` did, dismisses
    /// the sheet, then resumes the stashed destination. A no-op if nothing is pending (defensive
    /// against a stray `torSheetPresentationChanged(false)` after "Got it" already handled it).
    private func confirmTorSheet(state: inout MigrationCoordFlow.State) -> Effect<MigrationCoordFlow.Action> {
        guard let destination = state.pendingTorDestination else { return .none }
        state.pendingTorDestination = nil
        state.isTorSheetPresented = false

        let options = NetworkPrivacyOptions(useTor: state.torSheetState.isTorOn, submissionEndpoint: nil)
        migrationManager.setNetworkPrivacyOptions(options)
        state.networkPrivacyOptions = options

        switch destination {
        case .reviewTransfer:
            state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
            return .none

        case .permissionChain:
            return .run { send in
                await send(.pushNextPermissionStep(await nextPermissionStepResult()))
            }
        }
    }

    // MARK: - Re-entry

    /// Maps `manager.reentryRoute()` onto the flow-root screen State to append, hydrated from SDK
    /// members per the MOB-1466 spec's re-entry table. `.entry` appends nothing (Entry is the
    /// coordinator's own root screen, already showing).
    private func reentryPathState() async -> MigrationCoordFlow.Path.State? {
        switch migrationManager.reentryRoute() {
        case .recovery(let isExpired):
            return .recovery(recoveryState(isExpired: isExpired, isFlowRoot: true))

        case .statusResume:
            return .status(await statusResumeState(isFlowRoot: true))

        case .statusProgress:
            return .status(await statusProgressState(isFlowRoot: true))

        case .complete:
            return .complete(completeState(isFlowRoot: true))

        case .noteSplitProgress:
            return .noteSplit(MigrationNoteSplit.State(phase: .splitting, isFlowRoot: true))

        case .reviewManual(let step, let total):
            return .reviewTransfer(await reviewManualState(step: step, total: total, isFlowRoot: true))

        case .entry:
            return nil
        }
    }

    // MARK: - Permission-step routing

    /// Shared helper (used after How This Works/the Tor sheet, and each permission screen's
    /// continue/skip): computes the next needed screen in order — `backgroundDelivery` iff
    /// background refresh isn't `.available` -> `notifications` iff authorization is still
    /// `.notDetermined` (granted/denied both skip, per §5 S4) -> `transferPlan`. MOB-1478 (W2): Tor
    /// resolution no longer lives in this chain — the bottom-sheet gate already ran once, earlier,
    /// immediately after How This Works.
    private func nextPermissionStepResult() async -> MigrationCoordFlow.PermissionStepResult {
        if await migrationBGScheduler.backgroundRefreshStatus() != .available {
            return MigrationCoordFlow.PermissionStepResult(pathState: .backgroundDelivery(MigrationBackgroundDelivery.State()))
        }

        if await userNotifications.authorizationStatus() == .notDetermined {
            // MOB-1478 (W8): mirrors `freshPlanVariant()`'s ternary — today `.manual` was
            // unreachable since this always defaulted to `.scheduled`.
            let variant: MigrationNotifications.State.Variant = migrationManager.isManualDelivery() ? .manual : .scheduled
            return MigrationCoordFlow.PermissionStepResult(pathState: .notifications(MigrationNotifications.State(variant: variant)))
        }

        return MigrationCoordFlow.PermissionStepResult(pathState: .transferPlan(MigrationTransferPlan.State(variant: freshPlanVariant())))
    }

    /// Fresh-entry plan variant: manual delivery (background delivery declined) shows the manual
    /// copy and its confirm sends the first transfer now (§6.3); otherwise the scheduled variant.
    private func freshPlanVariant() -> MigrationTransferPlan.State.Variant {
        migrationManager.isManualDelivery() ? .manual : .scheduled
    }

    // MARK: - Recovery: TransferPlan hydration

    /// Recovery `.recreate`'s follow-up plan screen: `restartCurrentMigrationStep()` returns a
    /// fresh `MigrationSchedule`, injected via `injectedSchedule` so the screen's own `onAppear`
    /// populates rows (no coordinator-side duplication of that row-building logic). This variant
    /// DOES sign — `requiresSigning` stays at its default `true`.
    private func recreatedPlanState(schedule: MigrationSchedule) -> MigrationTransferPlan.State {
        var state = MigrationTransferPlan.State(variant: .recreated)
        state.injectedSchedule = schedule
        return state
    }

    private func recoveryState(isExpired: Bool, isFlowRoot: Bool) -> MigrationRecovery.State {
        let rows = sdkSynchronizer.migrationTransfers()
        let (first, last) = expiredOrInvalidBounds(rows: rows)
        return MigrationRecovery.State(
            reason: isExpired ? .expired : .notesSpent,
            firstTransfer: first,
            lastTransfer: last,
            isFlowRoot: isFlowRoot
        )
    }

    private func statusResumeState(isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = sdkSynchronizer.migrationTransfers()
        let summary = sdkSynchronizer.migrationSummary()
        let stalledRow = rows.first { $0.status == MigrationTransferRow.Status.overdue }
        var state = MigrationStatus.State(
            presentation: .resume,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            stalledNumber: (stalledRow?.index ?? 0) + 1,
            stalledHoursAgo: stalledRow?.hoursFromNow ?? 0,
            isFlowRoot: isFlowRoot
        )
        state.isSendNowDisabled = migrationManager.sendGate() != MigrationSendGate.allowed
        return state
    }

    private func statusProgressState(isFlowRoot: Bool) async -> MigrationStatus.State {
        let rows = sdkSynchronizer.migrationTransfers()
        let summary = sdkSynchronizer.migrationSummary()
        var state = MigrationStatus.State(
            presentation: .progress,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot
        )
        state.isSendNowDisabled = migrationManager.sendGate() != MigrationSendGate.allowed
        return state
    }

    private func completeState(isFlowRoot: Bool) -> MigrationComplete.State {
        let summary = sdkSynchronizer.migrationSummary()
        return MigrationComplete.State(
            totalTransferred: summary.transferred,
            dust: summary.dust,
            transfersSent: summary.transfersSent,
            transfersTotal: summary.transfersTotal,
            durationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot
        )
    }

    private func reviewManualState(step: Int, total: Int, isFlowRoot: Bool) async -> MigrationReviewTransfer.State {
        let rows = sdkSynchronizer.migrationTransfers()
        let nextRow = rows.first { $0.status == MigrationTransferRow.Status.active }
            ?? rows.first { $0.status == MigrationTransferRow.Status.overdue }
        return MigrationReviewTransfer.State(
            mode: .manualStep(number: step, total: total),
            amount: nextRow?.amount ?? Zatoshi.zero,
            // Standard ZIP-317 marginal fee (`MigrationReviewTransfer.State.standardFee`'s value —
            // that constant is `fileprivate` to its own file, so it's mirrored here literally).
            fee: Zatoshi(100_000),
            isFlowRoot: isFlowRoot
        )
    }

    /// 1-based `(first, last)` bounds among rows flagged `.expired` or `.invalid`; falls back to
    /// `(1, total)` when none match (mirrors `MigrationDerivations.expiredBounds`'s fallback shape).
    private func expiredOrInvalidBounds(rows: [MigrationTransferRow]) -> (first: Int, last: Int) {
        let flaggedIndexes = rows
            .filter { $0.status == MigrationTransferRow.Status.expired || $0.status == MigrationTransferRow.Status.invalid }
            .map { $0.index + 1 }

        guard let first = flaggedIndexes.min(), let last = flaggedIndexes.max() else {
            return (1, rows.count)
        }

        return (first, last)
    }
}
