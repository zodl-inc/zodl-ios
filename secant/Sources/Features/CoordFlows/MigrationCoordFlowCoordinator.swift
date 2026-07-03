//
//  MigrationCoordFlowCoordinator.swift
//  Zashi
//
//  Routing brain for `MigrationCoordFlow` (MOB-1466): re-entry (`.onAppear`), the chaining table
//  from Entry through Complete, and the shared permission-step helper (BackgroundDelivery ->
//  Notifications -> NetworkPrivacy -> TransferPlan). See the MOB-1466 implementation spec's
//  `MigrationCoordFlow` section for the full chaining table this mirrors row by row.
//
//  MOB-1468 (Keystone) adds a QR sign/scan round-trip ahead of the three signing sources
//  (NoteSplit/TransferPlan/ReviewTransfer): each delegates `.keystoneSignRequested(pczts)` instead
//  of signing locally, which sets `pendingKeystoneSigning` and pushes `keystoneSign`;
//  `keystoneSign(.delegate(.getSignature))` pushes `scan` configured with the migration batch
//  checker; `scan(.foundPCZTBatch(signed))` switches on `pendingKeystoneSigning` to submit/store the
//  signed PCZTs and resume whichever chain the source represents, popping both pushed elements and
//  clearing the context. `keystoneSign(.delegate(.rejected))` pops back to the signing source with
//  its state untouched (no partial storage ever happens on that path). See the "Keystone signing"
//  section below.
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
                if result.forcedUseTor {
                    state.networkPrivacyOptions.useTor = true
                }
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
                    // Skip Network Privacy (S5) iff the app-wide Tor setup flag is on — in that
                    // case `useTor` is implicitly `true` and Review is pushed directly; otherwise
                    // Network Privacy is shown so the user can opt in explicitly. Both checks here
                    // are synchronous SDK/dependency reads, so no effect is needed.
                    if walletStorage.exportTorSetupFlag() == true {
                        state.networkPrivacyOptions.useTor = true
                        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                    } else {
                        state.path.append(.networkPrivacy(MigrationNetworkPrivacy.State(variant: .immediate)))
                    }
                    return .none

                case .privateScheduled:
                    if sdkSynchronizer.isNoteSplitNeeded() {
                        state.path.append(.noteSplit(MigrationNoteSplit.State()))
                        return .none
                    }
                    return .run { send in
                        await send(.pushNextPermissionStep(await nextPermissionStepResult()))
                    }
                }

                // MARK: - NoteSplit

            case .path(.element(id: let id, action: .noteSplit(.delegate(.continued)))):
                // NoteSplit's `closeTapped` (flow-root back, splitting phase) and `continueTapped`
                // (normal chain progression, confirmed phase) both emit the same `.continued`
                // delegate value — `isFlowRoot` on the element disambiguates them, since only the
                // flow-root splitting re-entry root can reach `closeTapped` at all.
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

                // MARK: - NetworkPrivacy

            case .path(.element(id: _, action: .networkPrivacy(.delegate(.confirmed(let options))))):
                migrationManager.setNetworkPrivacyOptions(options)
                state.networkPrivacyOptions = options

                if state.mode == .immediate {
                    state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                } else {
                    state.path.append(.transferPlan(MigrationTransferPlan.State(variant: freshPlanVariant())))
                }
                return .none

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

            case .path(.element(id: _, action: .noteSplit(.delegate(.keystoneSignRequested(let pczts))))):
                state.pendingKeystoneSigning = .noteSplit
                state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: pczts)))
                return .none

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
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .scan(.foundPCZTBatch(let signed)))):
                guard let context = state.pendingKeystoneSigning else { return .none }

                switch context {
                case .noteSplit:
                    // Empty batch: nothing decoded to a usable signed PCZT — treat it as a failure
                    // the same way an unparseable/rejected QR does elsewhere, without ever calling
                    // `submitSignedNoteSplit` (no-partial-storage invariant).
                    guard let pczt = signed.first else {
                        return .send(
                            .keystoneSigningSubmitted(
                                context: .noteSplit,
                                result: .networkError(retryable: true),
                                signedPczt: nil
                            )
                        )
                    }
                    return .run { [sdkSynchronizer] send in
                        let result = await sdkSynchronizer.submitSignedNoteSplit(pczt)
                        await send(.keystoneSigningSubmitted(context: .noteSplit, result: result, signedPczt: pczt))
                    }

                case .planCommit, .immediateReview:
                    // Empty batch: nothing to store — no-partial-storage invariant (never call
                    // `storeSignedMigrationTransactions` with an incomplete/empty set).
                    guard !signed.isEmpty else { return .none }

                    return .run { [sdkSynchronizer] send in
                        await sdkSynchronizer.storeSignedMigrationTransactions(signed)
                        await send(.keystoneSigningSubmitted(context: context, result: nil, signedPczt: nil))
                    }
                }

            case .keystoneSigningSubmitted(let context, let result, let signedPczt):
                return resumeAfterKeystoneSigning(context: context, result: result, signedPczt: signedPczt, state: &state)

            case .path(.element(id: _, action: .keystoneSign(.delegate(.rejected)))):
                // No-partial-storage invariant: nothing was submitted/stored — just pop back to the
                // signing source with its state untouched (NoteSplit still explainer, plan/review
                // still unsigned) and clear the context. The pop is deferred to a follow-up
                // self-action (mirrors `sendNowCompleted`'s deferred pop) rather than done inline
                // here: `.forEach(\.path, action:)` still needs to deliver this SAME action to the
                // `keystoneSign` element after this case returns, and popping it first would leave
                // `.forEach` with no element to deliver to (a TCA "missing element" runtime error).
                return .send(.keystoneSignRejected)

            case .keystoneSignRejected:
                state.pendingKeystoneSigning = nil
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
                return .run { [migrationBGScheduler, sdkSynchronizer] send in
                    await sdkSynchronizer.rescheduleStalledMigrationTransfer()
                    await migrationBGScheduler.scheduleFirstWindow()
                    let rows = sdkSynchronizer.migrationTransfers()
                    let planState = rescheduledPlanState(rows: rows)
                    await send(.pushHydratedPathState(.transferPlan(planState)))
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
    /// (`resumeAfterKeystoneSigning`), which both reach this point with a signed+stored schedule.
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

    // MARK: - Keystone signing (MOB-1468): resume after submit/store

    /// Pops `scan`+`keystoneSign` (the two elements the QR round-trip pushed) and resumes whichever
    /// chain `context` represents, mirroring how the equivalent software `.confirmed` row would
    /// proceed from the now-topmost signing-source element:
    /// - `.noteSplit`: mutates the `noteSplit` element now on top in place (the `isRescheduling`
    ///   precedent) — `phase = .splitting`, `signedNoteSplitPczt` set to the PCZT that was
    ///   submitted — then applies `result` exactly like that element's own `.splitResult` handling
    ///   (success sets `txId`; failure presents the failure sheet).
    /// - `.planCommit`: the `transferPlan` element now on top never re-signs again — resumes via
    ///   `transferPlanPostConfirmChain(variant:state:)`, identical to the software `.confirmed` row.
    /// - `.immediateReview`: pushes `.sending`, identical to the software `reviewTransfer.confirmed`
    ///   row.
    ///
    /// Clears `pendingKeystoneSigning` in every case.
    private func resumeAfterKeystoneSigning(
        context: MigrationCoordFlow.KeystoneSigningContext,
        result: TransferResult?,
        signedPczt: Pczt?,
        state: inout MigrationCoordFlow.State
    ) -> Effect<MigrationCoordFlow.Action> {
        state.pendingKeystoneSigning = nil
        state.path.removeLast(2)

        switch context {
        case .noteSplit:
            guard
                let noteSplitId = state.path.ids.last,
                case .noteSplit(var noteSplitState) = state.path[id: noteSplitId]
            else {
                return .none
            }

            noteSplitState.phase = .splitting
            noteSplitState.signedNoteSplitPczt = signedPczt
            switch result {
            case .success(let txId):
                noteSplitState.txId = txId
                noteSplitState.isFailurePresented = false
            case .networkError, .invalidNote, .expired, .none:
                noteSplitState.isFailurePresented = true
            }
            state.path[id: noteSplitId] = .noteSplit(noteSplitState)
            return .none

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

    /// Shared helper (used after Entry-scheduled-no-split, NoteSplit-continued, and each
    /// permission screen's continue/skip): computes the next needed screen in order —
    /// `backgroundDelivery` iff background refresh isn't `.available` -> `notifications` iff
    /// authorization is still `.notDetermined` (granted/denied both skip, per §5 S4) ->
    /// `networkPrivacy` iff the app-wide Tor setup flag isn't on -> `transferPlan`. When S5 is
    /// skipped because Tor is already on, `forcedUseTor` tells the reducer to set
    /// `networkPrivacyOptions.useTor = true` before the plan screen is reached.
    private func nextPermissionStepResult() async -> MigrationCoordFlow.PermissionStepResult {
        if await migrationBGScheduler.backgroundRefreshStatus() != .available {
            return MigrationCoordFlow.PermissionStepResult(pathState: .backgroundDelivery(MigrationBackgroundDelivery.State()))
        }

        if await userNotifications.authorizationStatus() == .notDetermined {
            return MigrationCoordFlow.PermissionStepResult(pathState: .notifications(MigrationNotifications.State()))
        }

        if walletStorage.exportTorSetupFlag() != true {
            let transferCount = sdkSynchronizer.migrationTransfers().count
            let variant = MigrationNetworkPrivacy.State.Variant.scheduled(transferCount: transferCount)
            return MigrationCoordFlow.PermissionStepResult(
                pathState: .networkPrivacy(MigrationNetworkPrivacy.State(variant: variant))
            )
        }

        return MigrationCoordFlow.PermissionStepResult(
            pathState: .transferPlan(MigrationTransferPlan.State(variant: freshPlanVariant())),
            forcedUseTor: true
        )
    }

    /// Fresh-entry plan variant: manual delivery (background delivery declined) shows the manual
    /// copy and its confirm sends the first transfer now (§6.3); otherwise the scheduled variant.
    private func freshPlanVariant() -> MigrationTransferPlan.State.Variant {
        migrationManager.isManualDelivery() ? .manual : .scheduled
    }

    // MARK: - Reschedule / Recovery: TransferPlan hydration

    /// Status `.reschedule`'s follow-up plan screen: `rescheduleStalledMigrationTransfer()`
    /// returns `Void` (no schedule), so `rows` are built directly from a fresh
    /// `migrationTransfers()` read rather than via `injectedSchedule`. `requiresSigning: false`
    /// marks this variant's confirm as a plain acknowledgment (transfers are already signed).
    private func rescheduledPlanState(rows: [MigrationTransferRow]) -> MigrationTransferPlan.State {
        MigrationTransferPlan.State(
            variant: .scheduled,
            rows: IdentifiedArrayOf(uniqueElements: rows),
            totalDurationHours: sdkSynchronizer.migrationSummary().estimatedDurationHours,
            requiresSigning: false
        )
    }

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
