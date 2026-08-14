//
//  MigrationCoordFlowCoordinator.swift
//  Zodl
//
//  The migration flow's routing table — see `MigrationCoordFlowStore.swift` for the Phase 3 scope
//  and the two lanes it covers. Each case below is the Phase 3 reduction of the identically-named
//  case in #1930's coordinator; where #1930 does more, the comment says what and which phase
//  restores it.
//
//  WHY THIS FILE IS EXTRACTED CASE-BY-CASE rather than copied whole, unlike the manager and every
//  screen: #1930's coordinator is 2,923 lines whose `Path` enum names five screens this build does
//  not have — `MigrationKeystoneSign` (Phase 7), `MigrationRecovery` (5), `MigrationComplete` (6),
//  `MigrationNotifications` + `MigrationBackgroundDelivery` (4). Copying it whole means deleting
//  ~40% of it or pulling four later phases in at once. The rows below are #1930's own, at its line
//  numbers; everything in its 685-1158 (Keystone) and 1289-1642 (Recovery/Complete) stays out.
//

import Foundation
import SwiftUI
import ComposableArchitecture
import OrderedCollections
@preconcurrency import ZcashLightClientKit

// MARK: - PHASE 7: the SDK's own Keystone firmware type

extension ZcashLightClientKit.KeystoneFirmwareVersion {
    /// The dotted `major.minor.build` rendering of the version the Keystone BATCH-signing response
    /// envelope reports, for the migration flow's firmware-gate copy.
    ///
    /// A SEPARATE type from the app's own `KeystoneDisplayFirmwareVersion`
    /// (`Features/SendConfirmation/KeystoneDisplayFirmwareVersion.swift`). A21 gave them distinct
    /// names — they used to share the bare `KeystoneFirmwareVersion`, kept apart only by
    /// same-module shadowing, which compiled and did the right thing right up until someone
    /// assigned one to the other. They differ in substance, not merely in module: this one carries
    /// the device's RAW triple (the SDK documents that display offsets are deliberately NOT applied
    /// to it), while the app type normalizes a PCZT stamp through `stampedMajorOffset`. Do not
    /// bridge them: the batch protocol has no PCZT-embedded stamp at all, and the two floors are
    /// checked against different sources by design.
    var versionString: String {
        "\(major).\(minor).\(build)"
    }
}

extension MigrationCoordFlow {
    func coordinatorReduce() -> some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // Audit 2026-08-03 (#15): THE ARM the guard's docs always promised — with zero
                // arm sites, `isMigrationFlowPresented` read false forever and `reconcile()`'s
                // remainder evaluation could overwrite the SDK's one-slot plan cache underneath an
                // open flow's uncommitted propose (the documented `migrationPlanStale` race).
                // Armed unconditionally: the flow is on screen whether this open is fresh or a
                // re-entry mid-stack; disarmed at `flowFinished`/`switchServerRequested`.
                migrationManager.setMigrationFlowPresented(state.selectedWalletAccount?.id, true)
                // A screen is already on the stack: routing already ran (or the stack was
                // hydrated) and the root's visibility is whatever that resolution chose. The
                // old force-reveal here re-revealed the fork beneath a pushed re-entry stack.
                guard state.path.isEmpty else { return .none }
                return .run { [accountUUID = state.selectedWalletAccount?.id] send in
                    let pathState = await reentryPathState(accountUUID: accountUUID)
                    // The fork reveals ONLY when routing chose it (`nil` — the fork IS the
                    // destination). A pushed destination leaves the root hidden forever, and
                    // the push lands without an animation frame so the destination appears
                    // directly instead of sliding over the hidden root.
                    if let pathState {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        await send(.pushHydratedPathState(pathState), transaction: transaction)
                    } else {
                        await send(.reentryResolved)
                    }
                }

            case .reentryResolved:
                state.isReentryResolved = true
                return .none

                // MARK: - Sheet presentation bindings

            case .binding(\.isTorSheetPresented):
                // `BindingReducer()` already wrote the flag; forward to the existing action for its
                // side effects (which are real — see its own case). Sending rather than duplicating
                // keeps ONE implementation for both the swipe-dismiss and the programmatic path.
                return .send(.torSheetPresentationChanged(state.isTorSheetPresented))

            case .binding(\.isKeystoneFirmwareGatePresented):
                return .send(.keystoneFirmwareGatePresentationChanged(state.isKeystoneFirmwareGatePresented))

            case .binding:
                return .none

            case .flowFinished:
                return .none

            case .switchServerRequested:
                // Root opens Server Setup and tears this flow down; the coordinator owns no
                // navigation outside its own `path`.
                return .none

            case .pushHydratedPathState(let pathState):
                // Append WITHOUT revealing the root: the fork renders only when routing chose
                // it (`.reentryResolved`), so a pushed re-entry destination sits over the
                // neutral, permanently-hidden spinner — never over a tappable fork offering a
                // choice the committed run already made.
                state.path.append(pathState)
                return .none

            case .pushHydratedStatus(let statusState):
                state.path.append(.status(statusState))
                return .none

                // MARK: - Entry: the one fork (D8/D12)

            case .entry(.dismissRequired):
                // Entry is the flow's ROOT, so SwiftUI `dismiss()` is a no-op here — the coordinator
                // exits the flow instead (mirrors `SendForm.dismissRequired`).
                return .send(.flowFinished)

            case .entry(.delegate(.chose(let mode))):
                state.mode = mode
                migrationManager.setMigrationMode(state.selectedWalletAccount?.id, mode)

                switch mode {
                case .immediate:
                    return torGate(state: &state, destination: .reviewTransfer, usesFullBalanceCopy: true)

                case .privateScheduled:
                    state.path.append(.howItWorks(MigrationHowItWorks.State()))
                    return .none
                }

            case .entry:
                return .none

                // MARK: - HowItWorks -> the same Tor gate the immediate lane uses

            case .path(.element(id: _, action: .howItWorks(.delegate(.continueTapped)))):
                // PHASE 3: #1930 (:477) resolves the Tor choice exactly as below and THEN runs the
                // notification-permission chain (`nextPermissionStepResult`) before the plan.
                // Permissions are Phase 4; the Tor half is here in full, and Phase 4 inserts its
                // chain between this gate and the plan push.
                return torGate(state: &state, destination: .transferPlan, usesFullBalanceCopy: false)

                // MARK: - Tor bottom sheet (#1930 :519-568, verbatim)

            case .torSheet(.delegate(.gotIt)):
                return confirmTorSheet(state: &state)

            case .torSheet(.delegate(.switchServer)):
                // The custom-server variant's "Switch Server" — leave the flow for Server Setup and
                // persist NOTHING for the abandoned attempt: no `setNetworkPrivacyOptions`, no
                // `confirmProvisionalTorChoice`. The snapshot stays PROVISIONAL, so Root's teardown
                // discards it and a re-entry re-rolls.
                state.isTorSheetPresented = false
                state.pendingTorDestination = nil
                return .send(.switchServerRequested)

            case .torSheet:
                return .none

            case .torSheetStateReady(let sheetState, let destination):
                // Presentation-time forming/hydration resolved — show the sheet now.
                state.torSheetState = sheetState
                state.pendingTorDestination = destination
                state.isTorSheetPresented = true
                return .none

            case .torSheetPresentationChanged(let isPresented):
                state.isTorSheetPresented = isPresented
                // `false` covers both an explicit "Got it" (which already ran `confirmTorSheet`, so
                // `pendingTorDestination` is nil and the guard below exits) and a swipe-dismiss,
                // which never routed through `.delegate(.gotIt)` at all.
                guard !isPresented, state.pendingTorDestination != nil else { return .none }

                // R3/R11: a GENUINE swipe-dismiss showing a PROVIDER sheet with the toggle OFF
                // carries no warning-alert confirmation — persisting that OFF choice here would be
                // exactly the unwarned clearnet opt-out R3 forbids. Treat that one combination as a
                // full cancel: nothing persisted, `path` untouched, the flow does not advance.
                // Every other combination (ON, or identity-custom, where R12's disclosure already
                // stood in for the warning) keeps the persist-and-resume semantics.
                if !state.torSheetState.isCustomServer && !state.torSheetState.isTorOn {
                    state.pendingTorDestination = nil
                    return .none
                }
                return confirmTorSheet(state: &state)

                // MARK: - Notifications permission (#1930 :613)

            case .path(.element(id: _, action: .notifications(.delegate(.continued)))):
                // Allowed or skipped, both land here — the plan is next either way.
                state.path.append(.transferPlan(MigrationTransferPlan.State()))
                return .none

                // MARK: - TransferPlan (#1930 :620)

                // MOB-1466 (Lukas, 2026-08-07): the commit landed; the ~30 s first drive is still
                // running. Put the designed Scheduling screen up NOW rather than leaving the user
                // on the plan under a button spinner. Its hydrated twin arrives at `.confirmed`
                // below, which mutates THIS element rather than pushing a second one.
            case .path(.element(id: _, action: .transferPlan(.delegate(.scheduling)))):
                guard case .transferPlan = state.path.last else { return .none }
                state.path.append(.scheduled(MigrationScheduled.State(phase: .scheduling)))
                return .none

            case .path(.element(id: _, action: .transferPlan(.delegate(.confirmed)))):
                // NOT `path.last` any more: the Scheduling screen above is pushed on top of the
                // plan before this lands, so the plan is the last `.transferPlan` ELEMENT rather
                // than the last element. Reading `.last` here is what would silently no-op the
                // whole post-confirm chain.
                guard let planState = state.path.compactMap({ pathState -> MigrationTransferPlan.State? in
                    guard case let .transferPlan(planState) = pathState else { return nil }
                    return planState
                }).last else { return .none }

                guard planState.requiresSigning else {
                    // A `requiresSigning == false` confirm is a plain acknowledgment of an
                    // already-committed schedule — no re-sign, no terminal screen, straight out
                    // ("Got it" per the spec). (Audit 2026-08-03, C10: #1930's planned
                    // `isExpiredRecoveryReview` fork was never built and its flag was deleted —
                    // both acknowledge-only screens route here identically.)
                    return .send(.flowFinished)
                }

                return transferPlanPostConfirmChain(
                    variant: planState.variant,
                    schedule: planState.schedule,
                    state: &state
                )

            case .path(.element(id: _, action: .transferPlan(.delegate(.leftWithoutConfirming)))):
                // MOB-1466 (field finding O5): "Leave anyway" on the back-out guard, or the
                // store's own silent pass-through — either way an ordinary pop, the same
                // coordinator-side path mutation every other plain back/cancel in this file uses
                // (e.g. `.scan(.cancelTapped)`, `.keystoneSignRejected` below). Nothing to undo:
                // the guard's whole premise is that nothing was committed on this leg.
                _ = state.path.popLast()
                return .none

                // MARK: - ReviewTransfer (#1930 :651)

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed)))):
                // `totalCount: 1` — a send-max proposal is a single transaction BY CONSTRUCTION
                // (`Proposal.transactionCount() == 1`). The proposal is guaranteed populated for the
                // immediate lane: the guard chain in `MigrationReviewTransferStore.confirmTapped`
                // never reaches this delegate with a nil one. (The manual-STEP peek that lived
                // here was REMOVED 2026-08-07 with the manual-delivery lane — every confirm is
                // the immediate one-shot sweep now.)
                var immediateProposal: ImmediateMigrationProposal?
                if case .reviewTransfer(let reviewState) = state.path.last {
                    immediateProposal = reviewState.immediateProposal
                }
                state.path.append(
                    .sending(
                        MigrationSending.State(
                            totalCount: 1,
                            immediateProposal: immediateProposal
                        )
                    )
                )
                return .none

            // The flow's terminal closes. `.scheduled(.delegate(.done))` is the commit's own exit —
            // it was MISSING (the screen emitted the delegate, nothing consumed it, so Done was a
            // dead button that stranded the user on the screen). PHASE 5 adds the recovery screen's
            // flow-root close to the same list.
            case .path(.element(id: _, action: .reviewTransfer(.delegate(.closed)))),
                 .path(.element(id: _, action: .recovery(.delegate(.close)))),
                 .path(.element(id: _, action: .scheduled(.delegate(.done)))):
                return .send(.flowFinished)

                // MARK: - PHASE 5: attention + recovery

            case .path(.element(id: let id, action: .recovery(.delegate(.recreate)))):
                guard case .recovery(var recoveryState) = state.path[id: id] else { return .none }
                // Single-flight: a refresh/restart is multi-second and a second one would race the
                // first over the same run. The disabled button covers the common double-tap; this
                // covers the rest.
                guard !recoveryState.isRecovering else { return .none }
                guard let account = state.selectedWalletAccount else { return .none }
                let reason = recoveryState.reason
                recoveryState.isRecovering = true
                state.path[id: id] = .recovery(recoveryState)

                switch reason {
                case .notesSpent:
                    // A funding note left the wallet: nothing about the old plan is salvageable, so
                    // the whole step is re-planned from live balances.
                    return .send(.recoveryRestartRequested)

                case .expired:
                    // Only the elapsed rows are rebuilt, IN PLACE — amounts do not change, so there
                    // is no new consent decision to take the user back through.
                    guard account.vendor != WalletAccount.Vendor.keystone else {
                        // Keystone: refresh with a nil usk (rebuilt rows come back UNSIGNED) and
                        // hand the rebuilt batch to the same ceremony the plan commit uses.
                        return .run { [sdkSynchronizer, migrationManager, account] send in
                            do {
                                let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(account.id, nil)
                                await migrationManager.recordCommittedSchedule(account.id, schedule)
                                await migrationManager.reconcile()
                                // Land on the plan screen carrying the REBUILT schedule. Its own
                                // Confirm runs `proposeKeystoneBatch` and hands the batch to the
                                // ceremony the plan-commit lane already owns — deliberately NOT
                                // pre-proposed here, because proposing twice would create two runs.
                                var planState = MigrationTransferPlan.State(variant: .recreated)
                                planState.injectedSchedule = schedule
                                await send(.pushHydratedPathState(.transferPlan(planState)))
                            } catch {
                                await send(.recoveryFailed)
                            }
                        }
                    }

                    // Software: derive the account's real usk so the engine can re-sign every rebuilt
                    // transfer in place. A nil usk here would strand the rebuilt rows awaiting a
                    // ceremony that never comes, so a software account must never take the branch
                    // above. A missing `zip32AccountIndex` on a software account is a "can't happen",
                    // but it routes to the same failure rather than a silent no-op — the recover
                    // button must never die without feedback.
                    guard let zip32AccountIndex = account.zip32AccountIndex else {
                        return .send(.recoveryFailed)
                    }
                    let networkType = zcashSDKEnvironment.network().networkType
                    return .run { [sdkSynchronizer, migrationManager, walletStorage, mnemonic, derivationTool, networkType, zip32AccountIndex, account] send in
                        do {
                            let usk = try await MigrationSpendingKeyDerivation.deriveUSK(
                                zip32AccountIndex: zip32AccountIndex,
                                walletStorage: walletStorage,
                                mnemonic: mnemonic,
                                derivationTool: derivationTool,
                                networkType: networkType
                            )
                            let schedule = try await sdkSynchronizer.refreshStaleMigrationTransfers(account.id, usk)
                            // Persist the RETURNED schedule as committed truth BEFORE reconcile: the
                            // SDK keeps no app-facing schedule post-refresh (the refreshed heights
                            // live only in the returned value), and the summary, the rows and the
                            // Home banner all render from the locally persisted one. Without this the
                            // app would keep showing the STALE pre-refresh schedule.
                            await migrationManager.recordCommittedSchedule(account.id, schedule)
                            await migrationManager.reconcile()
                            await send(.pushHydratedPathState(.scheduled(Self.scheduledStateNow(
                                schedule: schedule,
                                snapshot: migrationManager.currentMigrationSnapshot(account.id)
                            ))))
                        } catch {
                            await send(.recoveryFailed)
                        }
                    }
                }

            case .recoveryRestartRequested:
                guard let accountUUID = state.selectedWalletAccount?.id else { return .send(.recoveryFailed) }
                return .run { [sdkSynchronizer, migrationManager, accountUUID] send in
                    // E2E harness F#2/F#3b (2026-08-04): this is the run-discharging call of the
                    // notes-spent replan lane, and the field pinned the engine's "complete" mis-report
                    // to the moment right after it — so both its outcome AND its error must trace
                    // (the old `try?` swallowed the error a silent recovery failure died on).
                    MigrationTrace.event("RECOVERY restart — discharging the attention-blocked run for a fresh plan")
                    do {
                        _ = try await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
                    } catch {
                        MigrationTrace.event("RECOVERY restart FAILED — \(error); Continue re-enabled")
                        await send(.recoveryFailed)
                        return
                    }
                    MigrationTrace.event("RECOVERY restart done — reconciling, then fresh plan screen")
                    // Reconcile so the restart's state transition (off `.requiresAttention`) is
                    // observed promptly. The fresh plan's own commit reconciles again later.
                    await migrationManager.reconcile()
                    // No injected schedule: the pushed screen's own `onAppear` proposes fresh. A
                    // silent empty-schedule fallback would render an empty plan as if it were real.
                    await send(.pushHydratedPathState(.transferPlan(MigrationTransferPlan.State(variant: .recreated))))
                }

            case .recoveryFailed:
                // Clear the in-flight flag wherever the recovery element currently sits, so Continue
                // is tappable again. No alert: this lane's whole design premise is that attention
                // states are calm and re-tryable, never error surfaces.
                for id in state.path.ids {
                    if case .recovery(var recoveryState) = state.path[id: id] {
                        recoveryState.isRecovering = false
                        state.path[id: id] = .recovery(recoveryState)
                    }
                }
                return .none

                // MARK: - PHASE 6: completion + the residual fork

            case .path(.element(id: _, action: .complete(.delegate(.done)))):
                // Acknowledging is what lets the NEXT round (or nothing) take over: it wipes the
                // finished run's schedule/snapshot/failure records.
                return .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] send in
                    await migrationManager.acknowledgeComplete(accountUUID)
                    await migrationManager.reconcile()
                    await send(.flowFinished)
                }

            case .path(.element(id: _, action: .complete(.delegate(.migrateAnyway)))):
                // The residual is below the transfer threshold, so it cannot ride the scheduled lane.
                // "Migrate anyway" unlocks it and sweeps it through the ordinary immediate pipeline —
                // one transaction, engine-external, exactly like the manual lane's own sweep.
                guard let accountUUID = state.selectedWalletAccount?.id else { return .send(.migrateAnywayFailed) }
                return .run { [sdkSynchronizer, migrationManager, accountUUID] send in
                    do {
                        _ = try await sdkSynchronizer.unlockMigrationResidual(accountUUID)
                        // Reconcile before handing over: the unlock changes the account's spendable
                        // Orchard balance, and the Review screen's own proposal reads from it.
                        await migrationManager.reconcile()
                        await send(.migrateAnywayUnlocked)
                    } catch {
                        await send(.migrateAnywayFailed)
                    }
                }

            case .migrateAnywayUnlocked:
                // Straight onto the manual lane's own review screen: the user still confirms the
                // sweep, and every downstream path (software commit, Keystone single-PCZT ceremony,
                // broadcast-failure routing) is the one that lane already owns. `.immediate` carries
                // no proposal — that screen proposes for itself on appear.
                state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
                return .none

            case .migrateAnywayFailed:
                for id in state.path.ids {
                    if case .complete(var completeState) = state.path[id: id] {
                        completeState.isMigratingAnyway = false
                        state.path[id: id] = .complete(completeState)
                    }
                }
                return .none

                // MARK: - PHASE 7: Keystone ceremony — the two entries (#1930 :685-1158)

            case .path(.element(id: _, action: .transferPlan(.delegate(.keystoneSignRequested(let batch))))):
                // The BATCH lane. `proposeKeystoneBatch` has already run, which means the engine has
                // CREATED AND PERSISTED THE WHOLE RUN — every abandon route below must cancel it.
                state.pendingKeystoneSigning = .planCommit
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                state.keystoneBatchApplyInFlight = false
                beginKeystoneCeremony(batch: batch, state: &state)
                return .none

            case .path(.element(id: _, action: .reviewTransfer(.delegate(.keystoneImmediateSignRequested(let unsigned, let redacted))))):
                // The SINGLE-PCZT lane — an ordinary, engine-external proposal. No run was created,
                // so its abandon routes deliberately skip the stray-run cancel.
                state.pendingKeystoneSigning = .immediateReview
                state.pendingKeystoneSigningAccountUUID = state.selectedWalletAccount?.id
                beginImmediateKeystoneCeremony(unsigned: unsigned, redacted: redacted, state: &state)
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.getSignature)))):
                guard case let .keystoneSign(signState)? = state.path.last else { return .none }
                var scanState = Scan.State.initial
                if signState.redactedSinglePczt != nil {
                    // Single-PCZT ceremony — the PRODUCTION checker: the device echoes the full
                    // signed PCZT as a `zcash-pczt` UR, no batch decode session and no request-id
                    // correlation. Reset the shared BC-UR fountain decoder so a retry ceremony never
                    // inherits a previous session's accumulated frames (`SendConfirmation`
                    // precedent).
                    keystoneHandler.resetQRDecoder()
                    scanState.checkers = [.keystonePCZTScanChecker]
                } else {
                    // The batch scan session needs THIS ceremony's correlation token so
                    // `decodeKeystoneSignBatchPart` can reject a stale or unrelated response.
                    scanState.checkers = [.keystoneMigrationBatchScanChecker]
                    scanState.keystoneBatchRequestId = signState.requestId
                }
                scanState.instructions = String(localizable: .migrationKeystoneScanInstructions)
                scanState.forceLibraryToHide = true
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .keystoneSign(.delegate(.buildFailed)))):
                // `buildKeystoneSignBatchQRParts` threw — no QR was ever shown, so `.scan` was never
                // pushed either. Deferred for the same reason `.rejected` is: `.forEach` still needs
                // to deliver THIS action to the `keystoneSign` element after this case returns.
                return .send(.keystoneScanAbandoned)

            case .path(.element(id: _, action: .keystoneSign(.delegate(.rejected)))):
                // No-partial-storage invariant: nothing was stored — pop back to the signing source
                // with its state untouched. Deferred pop, same reason as `.buildFailed`.
                return .send(.keystoneSignRejected)

                // MARK: - PHASE 7: Keystone ceremony — the SINGLE-PCZT round-trip (immediate lane)

            case .path(.element(id: _, action: .scan(.foundPCZT(let signedPczt)))):
                // One-shot guard: a duplicate for an in-flight submit is DROPPED, never abandoned.
                guard !state.keystoneImmediateSubmitInFlight else { return .none }

                guard case .immediateReview? = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // This lane's minimum-firmware gate is the PRODUCTION one: the stamp the device
                // writes into every signed PCZT's proprietary fields, checked against the
                // `SendConfirmation` floor. An UNSTAMPED PCZT is necessarily below minimum (the
                // stamp ships since firmware 2.4.6), never merely "unknown" — same reasoning as
                // `SendConfirmation`'s own gate. The batch envelope's version and its separate floor
                // never enter this lane.
                let detectedFirmware = signedPczt.keystoneFirmwareStamp().map(KeystoneDisplayFirmwareVersion.fromStamp)
                guard let detectedFirmware, detectedFirmware >= KeystoneDisplayFirmwareVersion.minimumSupported else {
                    state.detectedKeystoneFirmwareVersion = detectedFirmware?.versionString
                    state.keystoneFirmwareGateMinimumVersion = KeystoneDisplayFirmwareVersion.minimumSupported.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // The scanned payload IS the device-signed PCZT — hand it, with the retained
                // unredacted original still on the `keystoneSign` element beneath `scan`, to the
                // proofs+combine+submit step. Armed across the WHOLE leg.
                state.keystoneImmediateSubmitInFlight = true
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return submitImmediateKeystoneTransaction(
                    accountUUID: accountUUID,
                    unsignedPczt: signState.pczts.first?.pczt ?? Data(),
                    signedPczt: signedPczt
                )

            case .keystoneImmediateSubmitted(let txId):
                state.keystoneImmediateSubmitInFlight = false
                // The ceremony may have been torn down while this effect was in flight (a reject
                // after a swipe-back off `scan` mid-proving cleared `pendingKeystoneSigning` — the
                // tombstone). The scan/sign elements are gone and the pop below would delete
                // whatever screen the user backed onto. The broadcast DID land, so still surface the
                // success — but push it over the CURRENT top without popping anything.
                guard case .immediateReview? = state.pendingKeystoneSigning else {
                    state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                    return .none
                }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                state.path.append(.sending(MigrationSending.State(phase: .success, txId: txId, totalCount: 1)))
                return .none

            case .keystoneImmediateSubmitFailed:
                state.keystoneImmediateSubmitInFlight = false
                // Same tombstone check as the success twin: the user already walked away from this
                // ceremony, so drop the late failure silently (it is logged at the throw site).
                guard case .immediateReview? = state.pendingKeystoneSigning else { return .none }
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                if let reviewId = state.path.ids.last, case .reviewTransfer(var reviewState) = state.path.last {
                    reviewState.isConfirming = false
                    reviewState.isFailurePresented = true
                    reviewState.failureReason = MigrationReviewTransfer.State.FailureReason.commit
                    state.path[id: reviewId] = .reviewTransfer(reviewState)
                    return .none
                }
                // THE REVIEW ELEMENT IS GONE (the user backed past it before the submit answered),
                // so there is no sheet to arm — but the REMEDY is unchanged, and so is the screen
                // that offers it. Push a FRESH immediate Review carrying the same commit-failure
                // sheet: `.immediate` re-proposes for itself on appear (the idiom
                // `.migrateAnywayUnlocked` already uses), and Retry on a `.commit` failure re-runs
                // the immediate ceremony from a fresh PCZT + redact — exactly what
                // `submitImmediateKeystoneTransaction`'s doc promises and what the arm above does.
                //
                // This used to push a Sending screen instead. That screen carries no
                // `immediateProposal`, so its Retry ran the scheduled-run delivery branch and
                // attempted an ENGINE drive for an engine-EXTERNAL immediate sweep failure — a
                // silent wrong-lane retry. (The defect predates this branch: upstream's fallback
                // had the same shape through `executeNextPendingMigrationTransfer`.)
                var reviewState = MigrationReviewTransfer.State(mode: .immediate)
                reviewState.isFailurePresented = true
                reviewState.failureReason = MigrationReviewTransfer.State.FailureReason.commit
                state.path.append(.reviewTransfer(reviewState))
                return .none

                // MARK: - PHASE 7: Keystone ceremony — the BATCH round-trip (scheduled lane)

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                // NOT in #1930 — its migration coordinator is the only coordflow that never handled
                // scan-Cancel, so the button was dead there (every sibling coordinator pops:
                // `SignWithKeystone`, `Send`, `SwapAndPay`, `AddKeystoneHWWallet`, `ScanCoordFlow`).
                //
                // Cancel backs out of the CAMERA, not the ceremony: pop only `scan`, landing back on
                // `keystoneSign` with its own Reject / Get Signature intact. Nothing was stored and
                // nothing is in flight (a completed decode has already left this screen), so there is
                // no state to unwind — and abandoning here instead would cancel the engine run over
                // what is really a "wrong QR / let me try again" tap.
                _ = state.path.popLast()
                return .none

            case .path(.element(id: _, action: .scan(.keystoneBatchDecodeFailed))):
                // `decodeKeystoneSignBatchPart` threw on a frame — a stale, mismatched or corrupt
                // response, including the SDK's own request-id-mismatch throw at completion. `.scan`
                // is still the top element here, so this reuses the abandon's pop-2 semantics.
                return .send(.keystoneScanAbandoned)

            case .path(.element(id: _, action: .scan(.foundKeystoneBatchSignatures(let data, let firmwareVersion)))):
                // One-shot guard — see `keystoneBatchApplyInFlight`'s doc. A duplicate for an
                // already in-flight ceremony is DROPPED, never routed through the abandon: nothing
                // went wrong, the first delivery is simply still being applied.
                guard !state.keystoneBatchApplyInFlight else { return .none }

                guard let context = state.pendingKeystoneSigning,
                      case let .keystoneSign(signState)? = state.path.dropLast().last,
                      let accountUUID = state.selectedWalletAccount?.id else {
                    return .send(.keystoneScanAbandoned)
                }

                // The batch lane's gate reads the decode envelope's OWN reported version (there is
                // no PCZT-embedded stamp in this protocol). Below the floor, or no version reported
                // at all, presents the gate sheet and abandons.
                //
                // The gate runs on ROUND 0 ONLY (Android parity): the same physical device signs
                // every round, and gating a later round would make the user scan through every
                // remaining round only to be blocked at the very end. A `nil` rounds state
                // (defensive) gates like round 0.
                let isFirstKeystoneRound = (state.keystoneBatchRounds?.roundIndex ?? 0) == 0
                guard !isFirstKeystoneRound
                    || (firmwareVersion.map { $0 >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware } ?? false) else {
                    state.detectedKeystoneFirmwareVersion = firmwareVersion?.versionString
                    state.keystoneFirmwareGateMinimumVersion = MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware.versionString
                    state.isKeystoneFirmwareGatePresented = true
                    return .send(.keystoneScanAbandoned)
                }

                // `applyKeystoneBatchSignatures` does the positional pairing itself, and it is
                // `async throws` — hand off to a `.run` rather than continuing inline. Nothing here
                // touches `state.path`, so it is still exactly `[..., keystoneSign, scan]` when
                // `.keystoneBatchSignaturesApplied` is handled below.
                let unsignedPczts = signState.pczts
                state.keystoneBatchApplyInFlight = true
                if let scanId = state.path.ids.last, case .scan(var scanState) = state.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    state.path[id: scanId] = .scan(scanState)
                }
                return .run { [sdkSynchronizer, unsignedPczts, data] send in
                    do {
                        let signed = try await sdkSynchronizer.applyKeystoneBatchSignatures(unsignedPczts, data)
                        await send(
                            .keystoneBatchSignaturesApplied(
                                context: context,
                                accountUUID: accountUUID,
                                unsignedPczts: unsignedPczts,
                                signed: signed
                            )
                        )
                    } catch {
                        // Log before abandoning: a silently-discarded apply failure is exactly what
                        // made #1930's original QA scan loop undiagnosable.
                        LoggerProxy.error("[MOB-1466] Keystone batch signature apply failed: \(error)")
                        await send(.keystoneScanAbandoned)
                    }
                }

            case .keystoneBatchSignaturesApplied(let context, let accountUUID, let unsignedPczts, let signed):
                // The apply landed — clear the one-shot guard. `Scan`'s own intake gate flipped
                // synchronously when THIS action was forwarded to the `scan` element, so no NEW
                // camera frame can start a fresh decode past this point.
                state.keystoneBatchApplyInFlight = false

                // Retained defensively: the live immediate lane rides the single-PCZT round-trip and
                // never arms a batch scan session, so a batch completion cannot carry this context
                // in practice.
                if case .immediateReview = context {
                    return submitImmediateKeystoneTransaction(
                        accountUUID: accountUUID,
                        unsignedPczt: unsignedPczts.first?.pczt ?? Data(),
                        signedPczt: signed.first?.pczt ?? Data()
                    )
                }

                // Tombstone: a reject/abandon can land while THIS apply effect is still in flight.
                // The ceremony is over — a late completion must store NOTHING. Without this guard
                // the nil rounds state below would masquerade as a single-round ceremony and store
                // THIS ROUND'S SLICE as if it were the whole batch: a partial store, the exact
                // invariant rounds exist to prevent. Dropping is safe — the engine still holds the
                // run's transactions awaiting signatures and re-serves them on the next entry.
                guard state.pendingKeystoneSigning != nil else { return .none }

                // Accumulate this round and, if rounds remain, arm the next one instead of storing:
                // the stores run exactly once, over the FULL accumulated batch, after the last round
                // (Android parity). The pop-2 + push keeps the path shape `[..., source,
                // keystoneSign]` constant however many rounds a large migration needs, and the fresh
                // `MigrationKeystoneSign.State` gives the next round its own request id.
                let fullSigned: [MigrationSignedTransferPczt]
                let preparationCount: Int
                if var rounds = state.keystoneBatchRounds {
                    rounds.accumulatedSigned.append(contentsOf: signed)
                    let totalRounds = rounds.rounds.count
                    let nextRoundIndex = rounds.roundIndex + 1
                    if nextRoundIndex < totalRounds {
                        rounds.roundIndex = nextRoundIndex
                        state.keystoneBatchRounds = rounds
                        state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)
                        state.path.append(
                            .keystoneSign(
                                MigrationKeystoneSign.State(
                                    pczts: rounds.rounds[nextRoundIndex],
                                    roundIndex: nextRoundIndex,
                                    totalRounds: totalRounds
                                )
                            )
                        )
                        return .none
                    }
                    preparationCount = rounds.preparationCount
                    state.keystoneBatchRounds = nil
                    fullSigned = rounds.accumulatedSigned
                } else {
                    // Defensive: treat `signed` as the whole batch with no preparations. Every batch
                    // ceremony sets the rounds state, so this is unreachable in practice.
                    preparationCount = 0
                    fullSigned = signed
                }

                // The schedule that was just signed lives on the `.transferPlan` element still
                // beneath `keystoneSign` + `scan` — read it now, before the resume pops past it.
                let schedule = pendingKeystoneSchedule(context: context, depthBelowTop: 2, state: state)
                let split = MigrationCoordFlow.splitKeystoneBatch(fullSigned, preparationCount: preparationCount)

                return storeKeystoneSignedBatch(
                    context: context,
                    accountUUID: accountUUID,
                    schedule: schedule,
                    prepEntries: split.prepEntries,
                    scheduleEntries: split.scheduleEntries
                )

            case .keystoneSigningSubmitted(let context):
                return resumeAfterKeystoneSigning(context: context, state: &state)

                // MARK: - PHASE 7: Keystone ceremony — the two terminal exits

            case .keystoneSignRejected:
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                // A reject can land while a post-scan leg is still in flight (the user swipe-backs
                // off `scan` mid-proving and taps Reject — the coordinator-level effects survive the
                // pop). Clear BOTH in-flight guards so the next ceremony starts clean; clearing
                // `pendingKeystoneSigning` above doubles as the tombstone those late completions
                // check. A reject mid-sequence discards the whole capped ceremony, accumulated
                // rounds included (no-partial-storage: nothing was stored).
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                state.keystoneBatchRounds = nil
                _ = state.path.popLast()
                return .none

            case .keystoneScanAbandoned:
                // Read BEFORE clearing. A live `pendingKeystoneSigning` on the BATCH lane means a
                // PCZT batch was already proposed for this ceremony — and `proposeNoteSplitPCZTs`
                // CREATED AND PERSISTED THE WHOLE RUN at that moment. The engine always resumes a
                // stored non-terminal run on the next attempt, ignoring any newer preview, so
                // abandoning without cancelling would strand it: a later re-entry would silently
                // resume signing these same, by-then-stale PCZTs.
                //
                // The immediate lane is exempt — its `createPCZTFromProposal` is engine-external and
                // created no run to cancel.
                state.keystoneBatchApplyInFlight = false
                state.keystoneImmediateSubmitInFlight = false
                state.keystoneBatchRounds = nil
                let pendingContext = state.pendingKeystoneSigning
                state.pendingKeystoneSigning = nil
                state.pendingKeystoneSigningAccountUUID = nil
                // The real round-trip's failure guards run with `.scan` on top (pop 2); a build
                // failure or a store failure never pushed `.scan` at all (pop 1).
                state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)

                guard case .planCommit? = pendingContext, let accountUUID = state.selectedWalletAccount?.id else {
                    return .none
                }
                return .run { [sdkSynchronizer, accountUUID] _ in
                    // Fire-and-forget: a failure here just leaves the stray run for the next attempt
                    // to encounter (and cancel) itself.
                    _ = try? await sdkSynchronizer.restartCurrentMigrationStep(accountUUID)
                }

            case .keystoneFirmwareGatePresentationChanged(let isPresented):
                state.isKeystoneFirmwareGatePresented = isPresented
                if !isPresented {
                    state.detectedKeystoneFirmwareVersion = nil
                    state.keystoneFirmwareGateMinimumVersion = nil
                }
                return .none

                // MARK: - Status (#1930 :1232 / :1262)

            // (The `.status(.delegate(.sendNow))` arm — the manual-delivery Send-now push — was
            // REMOVED 2026-08-07 with the whole manual-tap send surface.)

            case .path(.element(id: let id, action: .status(.delegate(.reschedule)))):
                // An overdue transfer the user chose to reschedule rather than send now: ask the
                // engine for a fresh window, then re-render the plan as the RESCHEDULED variant
                // (`requiresSigning == false` — it is already signed; its confirm is an
                // acknowledgment, handled above).
                //
                // FIELD-CAUGHT 2026-07-31: this used to send `.sendNowCompleted`, which refreshes
                // rows and NOTHING else — while `rescheduleTapped` had already set
                // `isRescheduling = true` to drive the button's spinner. `rescheduleCompleted` is
                // the only action that clears it, and nobody sent it: its own doc said so ("the
                // coordinator doesn't send this yet"), and the captured `id` was discarded with
                // `_ = id`, which is what an unfinished intention looks like. The spinner therefore
                // turned forever, and with "Send now" failing the user could neither send NOR
                // reschedule — a dead end reachable from an ordinary failed broadcast.
                //
                // Every exit from this effect now lands on `rescheduleCompleted`, including the
                // no-account branch: a spinner with no terminating path is worse than a wrong
                // answer, because the user cannot tell it from work in progress.
                let currentRows: [MigrationTransferRow]
                if case .status(let statusState) = state.path[id: id] {
                    currentRows = Array(statusState.rows)
                } else {
                    currentRows = []
                }
                // Audit 2026-08-03 (#17): the result routes through `.rescheduleResultReady`, a
                // COORDINATOR action whose reducer checks the element still exists before
                // forwarding — this parent-level effect survives the element's removal (forEach
                // teardown does not cancel it), so a back-tap mid-reschedule used to deliver the
                // result to a missing element (the same runtime-warning class the status screen's
                // own pulse fix eliminated).
                return .run { [accountUUID = state.selectedWalletAccount?.id, currentRows] send in
                    guard let accountUUID else {
                        await send(.rescheduleResultReady(id: id, rows: currentRows, totalDurationHours: nil))
                        return
                    }
                    // (A discarded `pendingMigrationTransferProposal` read sat here as a
                    // reconcile-nudge. Deleted 2026-08-07 with the accessor: the engine performs
                    // that reconcile inside every `migrationAdvanceStep` crank now, and the
                    // `reconcile()` on the next line was always the real work.)
                    await migrationManager.reconcile()
                    let rows = await migrationManager.migrationTransfers(accountUUID)
                    let summary = await migrationManager.migrationSummary(accountUUID)
                    await send(.rescheduleResultReady(id: id, rows: rows, totalDurationHours: summary.estimatedDurationHours))
                }

            case .path(.element(id: _, action: .status(.delegate(.done)))):
                return .send(.flowFinished)

            case let .rescheduleResultReady(id, rows, totalDurationHours):
                // (#17) The element-existence gate: a result whose screen was popped mid-flight is
                // dropped here, silently and deliberately — the screen that would render it is
                // gone, and `isRescheduling` died with its state.
                guard state.path[id: id] != nil else { return .none }
                return .send(.path(.element(id: id, action: .status(
                    .rescheduleCompleted(rows: rows, totalDurationHours: totalDurationHours)
                ))))

                // MARK: - Sending (#1930 :1161)

            case .path(.element(id: _, action: .sending(.delegate(.closed)))):
                // PHASE 3: #1930 forks on `state.mode` and on whether a Complete screen sits
                // beneath (the dust lane), and acknowledges a genuinely-`.complete` run — both
                // Phase 6. A scheduled run's remaining transfers stay scheduled; the user returns
                // via the banner or a notification (Phase 4).
                return .send(.flowFinished)

            case .path(.element(id: _, action: .sending(.delegate(.viewTransaction)))):
                // Closes the flow the same way; Root routes on to Activity.
                return .send(.flowFinished)

            case .path(.popFrom(id: let id)):
                // An interactive back-swipe off the LAST element of a re-entry stack whose fork
                // was never revealed would land on the permanently-hidden spinner root — a
                // dead end with no toolbar and no gestures. Leaving the flow is what the
                // gesture meant; finish it. (A pop deeper in the stack, or any pop when the
                // fork IS the revealed root, keeps ordinary pop semantics.) Runs BEFORE
                // `.forEach(\.path, action: \.path)` below removes the element, so `state.path`
                // here is still the PRE-pop stack — see `MigrationCoordFlowStore.body`.
                guard !state.isReentryResolved && state.path.ids == [id] else { return .none }
                return .send(.flowFinished)

            case .path:
                return .none
            }
        }
    }

    // MARK: - Tor gate

    /// The Tor-choice resolution point, shared by both lanes (#1930 :407 immediate / :477 scheduled
    /// — the two branches are identical apart from the destination and the sheet's copy).
    ///
    /// Skip the sheet iff the app-wide Tor flag is on AND the account's sync server is not
    /// identity-custom. A custom server's snapshot forces clearnet, so skipping straight through
    /// would silently route those users over clearnet with no unavailable-server notice ever shown.
    ///
    /// Detection is `isSyncServerIdentityCustom()` — a SYNCHRONOUS, snapshot-free read — checked
    /// before entering any effect, deliberately NOT the sheet state's own `isCustomServer`, which
    /// requires FORMING first. Order matters on the non-custom branch: `setNetworkPrivacyOptions`
    /// must run BEFORE `formNetworkSnapshot`, because forming BAKES IN whatever is currently
    /// persisted and a later persist does not correct an already-formed snapshot. Detecting via the
    /// sheet state would force a form-before-persist and could silently bake in a stale OFF choice.
    ///
    /// The identity-custom branch persists NOTHING: that sheet offers no choice, so storing its
    /// forced value would overwrite a real stored preference.
    private func torGate(
        state: inout State,
        destination: PendingTorDestination,
        usesFullBalanceCopy: Bool
    ) -> Effect<Action> {
        let accountUUID = state.selectedWalletAccount?.id

        if walletStorage.exportTorSetupFlag() == true {
            guard !migrationManager.isSyncServerIdentityCustom() else {
                return .run { send in
                    let sheetState = await torSheetState(usesFullBalanceCopy: usesFullBalanceCopy, accountUUID: accountUUID)
                    await send(.torSheetStateReady(sheetState, destination: destination))
                }
            }
            migrationManager.setNetworkPrivacyOptions(true)
            return .run { [migrationManager] send in
                await migrationManager.formNetworkSnapshot(accountUUID)
                await send(.pushHydratedPathState(destinationPathState(destination)))
            }
        }
        return .run { send in
            let sheetState = await torSheetState(usesFullBalanceCopy: usesFullBalanceCopy, accountUUID: accountUUID)
            await send(.torSheetStateReady(sheetState, destination: destination))
        }
    }

    /// Forms the run's provisional snapshot and derives the sheet's state from it — presentation-time
    /// forming, so the broadcast endpoint exists on the choice surface the user is shown.
    private func torSheetState(usesFullBalanceCopy: Bool, accountUUID: AccountUUID?) async -> MigrationTorSheet.State {
        await migrationManager.formNetworkSnapshot(accountUUID)
        let snapshot = await migrationManager.networkSnapshot(accountUUID)
        let isCustomServer = Self.isIdentityCustom(snapshot)

        var sheetState = MigrationTorSheet.State(usesFullBalanceCopy: usesFullBalanceCopy)
        sheetState.isCustomServer = isCustomServer
        if isCustomServer {
            sheetState.isTorOn = false
        }
        return sheetState
    }

    /// "Got it" (both the toggle-ON path and the off-warning alert's "Proceed without Tor"), the
    /// custom variant's acknowledge, and swipe-to-dismiss (for every combination except the one
    /// R3/R11 guards) all land here: persist whatever `isTorOn` is showing, dismiss, resume the
    /// stashed destination. A no-op when nothing is pending.
    ///
    /// Does NOT re-form the snapshot: presentation already formed the one the user was shown, and
    /// confirm must not re-roll the endpoint out from under them. `confirmProvisionalTorChoice`
    /// mutates ONLY `useTor` on that already-formed provisional snapshot — skipped entirely for an
    /// identity-custom confirm, whose forced `isTorOn == false` is a circumstance, not a preference.
    private func confirmTorSheet(state: inout State) -> Effect<Action> {
        guard let destination = state.pendingTorDestination else { return .none }
        state.pendingTorDestination = nil
        state.isTorSheetPresented = false

        let isTorOn = state.torSheetState.isTorOn
        let isCustomServer = state.torSheetState.isCustomServer
        let accountUUID = state.selectedWalletAccount?.id

        if !isCustomServer {
            migrationManager.setNetworkPrivacyOptions(isTorOn)
            migrationManager.confirmProvisionalTorChoice(accountUUID, isTorOn)
        }

        return .send(.pushHydratedPathState(destinationPathState(destination)))
    }

    private func destinationPathState(_ destination: PendingTorDestination) -> Path.State {
        switch destination {
        case .reviewTransfer:
            return .reviewTransfer(MigrationReviewTransfer.State(mode: .immediate))
        case .transferPlan:
            // PHASE 4: the permission ask sits BETWEEN the Tor choice and the plan, exactly where
            // #1930 ran `nextPermissionStepResult()`. Either outcome continues — permission is a
            // nice-to-have, never a blocker: without it the flow still works entirely via the
            // app-open reconcile (matrix D2), the user just gets no reminders.
            return .notifications(MigrationNotifications.State(variant: .scheduled))
        }
    }

    /// Identity-custom = the sync endpoint the run pinned is not one of the shipped providers.
    private static func isIdentityCustom(_ snapshot: MigrationNetworkSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.syncProvider == nil
    }

    // MARK: - Post-confirm (#1930 :1689)

    /// Post-commit hydration WITHOUT the engine: a just-committed schedule's transfer count and
    /// amount sum are known by definition (the schedule IS the plan), and both the moved value
    /// AND the sent count fold in the PUBLISHED snapshot's cumulative totals — a synchronous read
    /// of the channel's last value, never actor-bound.
    ///
    /// `sentCount` is not always 0: a fresh round-1 commit has nothing sent yet (a `nil`
    /// snapshot folds in nothing), but the recovery refresh-stale lane re-serves the run's
    /// STORED schedule, which can already carry transfers broadcast in an earlier round. The
    /// snapshot's `doneTransfers`/`movedByDoneTransfers` re-materialize those via `leadingRows`
    /// (prior `sentRecords` no longer in the current schedule) pre- or post-commit, so folding
    /// `doneTransfers` here keeps the count on the SAME cumulative-confirmed basis `totalAmount`
    /// already uses — a hardcoded 0 would have regressed the recovery lane's success screen to
    /// "0 of N" for a run that had already sent several.
    ///
    /// The async summary this replaces crossed the DB write actor twice (`migrationState`'s
    /// advance-step read, `residualAfterMigration`) and queued behind the post-commit prove
    /// sweep — the first-tap "nothing happens" stall, which survived the read-only-reads work
    /// precisely because those two hops are writers.
    ///
    /// Field 2026-08-06: for the software `.transferPlan(.delegate(.confirmed))` caller (:196)
    /// ONLY, `.delegate(.confirmed)` itself now arrives LATER than it used to —
    /// `MigrationTransferPlan` holds it back behind an awaited first drive (`.scheduleCommitted`),
    /// so by the time THAT caller reaches this builder, the drive (at tip) has already run its
    /// course, or was skipped mid-sync. This builder has two OTHER callers that reach it WITHOUT
    /// any awaited drive at all: the recovery refresh-stale push below (:335), and the Keystone
    /// `planCommit` resume (`resumeCommittedMigrationChain`, :1290) — the Keystone lane's own
    /// first-drive gap is a known limitation, flagged in the PR as not yet fixed.
    static func scheduledStateNow(
        schedule: MigrationSchedule?,
        snapshot: MigrationViewSnapshot?
    ) -> MigrationScheduled.State {
        let newScheduleAmount = schedule?.transfers.reduce(Zatoshi.zero) { $0 + $1.amount } ?? Zatoshi.zero
        let priorMoved = snapshot?.movedByDoneTransfers ?? Zatoshi.zero
        return MigrationScheduled.State(
            totalAmount: priorMoved + newScheduleAmount,
            sentCount: snapshot?.doneTransfers ?? 0,
            totalCount: schedule?.transfers.count ?? (snapshot?.totalTransfers ?? 0),
            durationHours: schedule?.estimatedDurationHours ?? 0
        )
    }

    private func transferPlanPostConfirmChain(
        variant: MigrationTransferPlan.State.Variant,
        schedule: MigrationSchedule?,
        state: inout State
    ) -> Effect<Action> {
        let accountUUID = state.selectedWalletAccount?.id
        switch variant {
        case .scheduled, .recreated:
            // PUSH SYNCHRONOUSLY — the same shape the `.manual` arm below has always used.
            // Everything the Scheduled screen shows is in hand (see `scheduledStateNow`);
            // the engine work that remains (window arming, the snapshot rebuild) runs AFTER
            // the screen is up, its latency off the navigation path — where a post-commit
            // prove sweep can no longer hold the push hostage.
            //
            // Field 2026-08-06: for this function's SOFTWARE caller (the `.transferPlan
            // (.delegate(.confirmed))` case at :196) ONLY, this push now lands AFTER the run's
            // awaited first drive — `MigrationTransferPlan` holds `.delegate(.confirmed)` back
            // behind its own `.scheduleCommitted` handler until that drive completes (or is
            // skipped mid-sync), so by the time control reaches here on THAT path the write actor
            // the drive's prove sweep can hold is free again, and the snapshot refresh below
            // republishes against a free actor. This function's OTHER caller — the Keystone
            // `planCommit` resume (`resumeCommittedMigrationChain`, :1290) — reaches here WITHOUT
            // any awaited drive at all; the Keystone lane's own first-drive gap is a known
            // limitation, flagged in the PR as not yet fixed.
            let hydrated = Self.scheduledStateNow(
                schedule: schedule,
                snapshot: migrationManager.currentMigrationSnapshot(accountUUID)
            )
            // MOB-1466: HYDRATE-OR-PUSH. The software lane already put this screen up in its
            // `.scheduling` phase when the commit landed, so here it only fills in the numbers —
            // no second push, no navigation animation, the card's skeleton bars simply become
            // values in place. The OTHER caller (the Keystone `planCommit` resume, :1290) reaches
            // this without a scheduling screen of its own and still pushes, unchanged.
            if let id = state.path.ids.last,
               case .scheduled(let existing) = state.path[id: id],
               existing.isScheduling {
                state.path[id: id] = .scheduled(hydrated)
            } else {
                state.path.append(.scheduled(hydrated))
            }
            return .run { [migrationManager] _ in
                await migrationManager.armNextWindowNotifications(accountUUID)
                migrationManager.refreshMigrationSnapshot(accountUUID)
            }
        }
        // (The `.manual` arm — the manual-delivery run's first-transfer push — was REMOVED
        // 2026-08-07 with the manual-delivery lane; the plan variant itself is gone too.)
    }

    // MARK: - PHASE 7: Keystone ceremony (#1930 :2024-2542)

    /// Keystone "cypherpunk" firmware floor for migration BATCH signing: 3.0.2 is the first firmware
    /// that supports this protocol at all — older firmware either cannot sign the batch correctly or
    /// will not report a version in the response envelope, which is why the gate treats "no version
    /// reported" the same as "below floor". Checked directly against
    /// `KeystoneBatchDecodeResult.firmwareVersion`; there is no PCZT-embedded stamp to fall back on
    /// in this protocol.
    ///
    /// Deliberately distinct from — and unrelated to — the single-transaction flow's own floor,
    /// `KeystoneDisplayFirmwareVersion.minimumSupported` (`Features/SendConfirmation/`), which reads its
    /// version from a stamp embedded in the signed PCZT bytes. The two `KeystoneDisplayFirmwareVersion`
    /// types share a bare name, so every reference to the SDK's is module-qualified.
    static let keystoneMigrationBatchMinimumFirmware = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)

    /// Splits an applied batch into its preparation entries and the schedule's own transfers.
    ///
    /// Positional, by `preparationCount`: `proposeKeystoneBatch` built the unsigned array as
    /// preparations-then-transfers, and `applyKeystoneBatchSignatures` echoes ids back positionally,
    /// so the same boundary holds on the signed side. ONLY the schedule half is safe to hand to
    /// `storeSignedMigrationTransactions`, and only the preparation half to `storeSignedNoteSplits`
    /// — each store looks its transactions up by the engine id they already carry.
    ///
    /// Defensive: a `preparationCount` beyond the array (which would mean the SDK broke the
    /// positional contract) clamps rather than trapping.
    static func splitKeystoneBatch(
        _ signed: [MigrationSignedTransferPczt],
        preparationCount: Int
    ) -> (prepEntries: [MigrationSignedTransferPczt], scheduleEntries: [MigrationSignedTransferPczt]) {
        let boundary = min(max(preparationCount, 0), signed.count)
        return (Array(signed[..<boundary]), Array(signed[boundary...]))
    }

    /// Starts the BATCH signing ceremony over the rounds the SDK already packed by ACTION budget
    /// (`MigrationKeystoneBatch.rounds`, 96 actions per Keystone round).
    ///
    /// A batch that fits one round is ONE animated QR session. A larger batch signs across several,
    /// each a full self-contained ceremony over its own round with a fresh request id; the applied
    /// signatures accumulate in `state.keystoneBatchRounds` and nothing stores until the last round
    /// lands. Within a round, `buildKeystoneSignBatchQRParts` is a fountain encoder and the SDK
    /// decides the frame count.
    ///
    /// The action budget also subsumes the old device-safety ITEM cap this used to enforce (Android
    /// observed a real Keystone OOM at 50 items): 96 actions can never exceed 32 items, since the
    /// lightest transaction — a transfer — weighs 3.
    private func beginKeystoneCeremony(batch: MigrationKeystoneBatch, state: inout State) {
        state.keystoneBatchRounds = KeystoneBatchRounds(
            rounds: batch.rounds,
            preparationCount: batch.preparationCount
        )
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: batch.rounds.first ?? [],
                    roundIndex: 0,
                    totalRounds: batch.rounds.count
                )
            )
        )
    }

    /// Starts the IMMEDIATE lane's SINGLE-PCZT ceremony — the PRODUCTION `SignWithKeystone`
    /// pipeline: the sign screen computes `urEncoderForPCZT` live over `redacted`, `.getSignature`
    /// pushes a scan session with the production checker, the device echoes the FULL signed PCZT,
    /// and the post-scan step is the proofs+combine `submitImmediateKeystoneTransaction`.
    ///
    /// NEVER the batch bridge. Android draws the same lane boundary (its immediate Keystone lane is
    /// the ordinary single-PCZT pipeline; the batch bridge is scheduled-mode machinery on both
    /// platforms). `pczts` carries the UNREDACTED original under an inert state-side id — the
    /// post-scan submit reads it positionally, and it never reaches the SDK.
    private func beginImmediateKeystoneCeremony(unsigned: Data, redacted: Data, state: inout State) {
        state.keystoneImmediateSubmitInFlight = false
        // The single-PCZT ceremony never chunks — a leftover rounds state from an earlier batch
        // ceremony must not leak into this one (defensive; every ceremony-ending route clears it).
        state.keystoneBatchRounds = nil
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    // `actions: 0` — this PCZT is NOT an engine row. The immediate lane is an
                    // ordinary send-max proposal built outside the migration engine, so no
                    // action weight exists for it, and 0 is the same "unknown" the SDK itself
                    // returns from `applyKeystoneBatchSignatures`. It never reaches
                    // `batchMigrationPcztsForSigning` (one transaction, one session); if it ever
                    // did, that call throws on a 0 weight rather than mis-packing a session —
                    // the safe direction.
                    pczts: [
                        MigrationUnsignedTransferPczt(
                            id: MigrationReviewTransfer.immediateKeystonePcztId,
                            pczt: unsigned,
                            actions: 0
                        )
                    ],
                    redactedSinglePczt: redacted
                )
            )
        )
    }

    /// The store sequence for a signed Keystone batch: the note-split preps (when present), then
    /// the schedule's own transfers, then the committed-schedule record and a reconcile — one
    /// straight line, abandoning on the FIRST store failure (the honest-failure surface: the
    /// ceremony is still up at this point, so `.keystoneScanAbandoned` pops it and cancels the
    /// stored run) rather than landing on the terminal "Migration Scheduled" screen with anything
    /// missing.
    ///
    /// HISTORY (audit 2026-08-03, P1): the preps-present branch used to DEFER the schedule store
    /// into a `PendingScheduleStore` "until a preparation broadcast lands" — and the deferred
    /// payload had NO consumer, so a preps-present ceremony's schedule transfers were silently
    /// dropped while the flow reported success. The deferral's own doc traced its motivation to a
    /// run-level phase overwrite ("a prep broadcast-success unconditionally sets
    /// `WaitingDenomConfirmations`, clobbering `BroadcastScheduled`") — a state machine the
    /// current engine no longer has: migration state is now PER-TRANSACTION
    /// (`MigrationTxState`: `apply_signature` moves one row `AwaitingSignature → Signed`; a prep
    /// broadcast moves ITS row to `Broadcast`), so the two stores are order-independent signature
    /// applications over one run, exactly as the old doc's own "original premise no longer holds"
    /// note already conceded for the run-creation half. Both entries store here, immediately.
    private func storeKeystoneSignedBatch(
        context: KeystoneSigningContext,
        accountUUID: AccountUUID,
        schedule: MigrationSchedule?,
        prepEntries: [MigrationSignedTransferPczt],
        scheduleEntries: [MigrationSignedTransferPczt]
    ) -> Effect<Action> {
        .run { [sdkSynchronizer, migrationManager, context, accountUUID, schedule, prepEntries, scheduleEntries] send in
            do {
                if !prepEntries.isEmpty {
                    try await sdkSynchronizer.storeSignedNoteSplits(accountUUID, prepEntries)
                }
            } catch {
                LoggerProxy.error("[MOB-1466] Keystone note-split store failed: \(error)")
                await send(.keystoneScanAbandoned)
                return
            }
            do {
                if !scheduleEntries.isEmpty {
                    try await sdkSynchronizer.storeSignedMigrationTransactions(accountUUID, scheduleEntries)
                }
            } catch {
                // The preps DID store; the abandon's run-cancel still applies — the engine
                // re-serves the whole batch on the next ceremony rather than resuming a
                // half-signed one.
                LoggerProxy.error("[MOB-1466] Keystone schedule store failed: \(error)")
                await send(.keystoneScanAbandoned)
                return
            }
            if let schedule {
                await migrationManager.recordCommittedSchedule(accountUUID, schedule)
            }
            await migrationManager.reconcile()
            await send(.keystoneSigningSubmitted(context: context))
        }
    }

    /// The immediate lane's post-signing step. An `ImmediateMigrationProposal` is engine-external:
    /// there is no `MigrationSchedule` to store and no engine run this ceremony created. The signed
    /// PCZT is proved and broadcast RIGHT HERE — unlike the software lane, a Keystone-signed PCZT
    /// can only be finalized once, immediately after the signature comes back; there is no
    /// engine-held "signed and stored, broadcast whenever" indirection for a proposal the engine
    /// never held.
    ///
    /// On failure, `.keystoneImmediateSubmitFailed` pops like an abandon but arms the Review
    /// element's commit-failure sheet, so Retry re-runs the whole ceremony from a fresh
    /// PCZT + redact. A "retry just the broadcast" lane would need to persist the already-signed
    /// PCZT bytes across the retry — infrastructure this ceremony does not have for a proposal the
    /// engine never stored.
    private func submitImmediateKeystoneTransaction(
        accountUUID: AccountUUID,
        unsignedPczt: Data,
        signedPczt: Data
    ) -> Effect<Action> {
        .run { [sdkSynchronizer, accountUUID, unsignedPczt, signedPczt] send in
            do {
                let txId = try await MigrationCommitPipeline.commitImmediateKeystone(
                    unsignedPczt: unsignedPczt,
                    signedPczt: signedPczt,
                    accountUUID: accountUUID,
                    sdkSynchronizer: sdkSynchronizer
                )
                await send(.keystoneImmediateSubmitted(txId: txId))
            } catch {
                LoggerProxy.error("[MOB-1466] immediate Keystone post-signing submit failed (proofs/combine/broadcast): \(error)")
                await send(.keystoneImmediateSubmitFailed)
            }
        }
    }

    /// Locates the `MigrationSchedule` that was signed for `context`, read off the `.transferPlan`
    /// element still beneath `keystoneSign` + `scan` at the point the signed PCZTs are about to be
    /// stored. `depthBelowTop` is how many elements sit above it (2 for the real scan round-trip).
    /// `nil` when that element carries no schedule of its own — the caller then skips
    /// `recordCommittedSchedule` rather than persisting nothing.
    private func pendingKeystoneSchedule(
        context: KeystoneSigningContext,
        depthBelowTop: Int,
        state: State
    ) -> MigrationSchedule? {
        switch context {
        case .planCommit:
            guard case let .transferPlan(planState)? = state.path.dropLast(depthBelowTop).last else { return nil }
            return planState.schedule

        case .immediateReview:
            // Unreachable in practice — the call site intercepts `.immediateReview` before ever
            // reaching this function. `MigrationReviewTransfer.State` carries no engine schedule at
            // all; the immediate lane's proposal is engine-external.
            return nil
        }
    }

    /// Pops back to the signing-source element and resumes whichever chain `context` represents.
    ///
    /// The real QR round-trip pushes `scan` on top of `keystoneSign` — 2 elements to unwind. Rather
    /// than trust the caller, this reads the actual top of the path: `.scan` on top pops 2, anything
    /// else pops 1 (a build failure never pushed `scan`).
    private func resumeAfterKeystoneSigning(
        context: KeystoneSigningContext,
        state: inout State
    ) -> Effect<Action> {
        state.pendingKeystoneSigning = nil
        state.pendingKeystoneSigningAccountUUID = nil
        // Belt — the last round's store handoff already cleared the rounds state.
        state.keystoneBatchRounds = nil
        state.path.removeLast(state.path.last?.is(\.scan) == true ? 2 : 1)

        return resumeCommittedMigrationChain(context: context, state: &state)
    }

    /// The shared post-commit resume: a `planCommit` ceremony reaches the IDENTICAL post-commit
    /// routing the software path's `.confirmed` row would.
    private func resumeCommittedMigrationChain(
        context: KeystoneSigningContext,
        state: inout State
    ) -> Effect<Action> {
        switch context {
        case .planCommit:
            // The underlying `MigrationTransferPlan.State.hasConfirmed` is still `false` here —
            // the Keystone lane deliberately never sets it (see the Store's own doc on that
            // property) — but that's safe at this exact point: the push below covers this screen
            // with `.scheduled`, which hides its back affordance, so the un-latched plan screen
            // is never reachable again for `.backTapped`/`.confirmTapped` to act on.
            guard case let .transferPlan(planState) = state.path.last else { return .none }
            return transferPlanPostConfirmChain(variant: planState.variant, schedule: planState.schedule, state: &state)

        case .immediateReview:
            // Unreachable: `submitImmediateKeystoneTransaction` intercepts `.immediateReview` at the
            // scan round-trip, before `resumeAfterKeystoneSigning` can be reached. Kept for the
            // switch's exhaustiveness — if it ever DID run it would incorrectly push a second
            // broadcast attempt for a transaction that already submitted.
            state.path.append(.sending(MigrationSending.State(totalCount: 1)))
            return .none
        }
    }

    // MARK: - State hydration (#1930 :1777 / :2750 / :2837)

    /// R13 Brick 2: hydration is ONE read of ONE value. The pre-Brick-2 version fetched rows,
    /// summary and the snapshot as three separate calls at three moments — three clocks inside a
    /// single hydration, on the screen whose whole design brief is "no two facts from different
    /// moments". Everything now comes off the same `MigrationViewSnapshot` the screen's own
    /// subscription will keep live.
    ///
    /// THE FOURTH OCCUPANT (handover O2, the QA force-quit). `reentryRoute`'s doc chronicles three
    /// lives of the actor-starvation class and its own fix — the work-in-flight route
    /// SHORT-CIRCUIT — resolves the ROUTE in milliseconds. This hydration then undid it: it awaited
    /// the BUILDER (`migrationViewSnapshot`), whose actor-bound reads (`transferDerivation`,
    /// `getAccountsBalances`) queue behind the same in-flight prove sweep, so the PUSH waited out
    /// the sweep behind the flow container's bare spinner — measured 15–45 s, read as a hang. The
    /// builder belongs to the publish lane, where "the build simply lands late" is a coalesced
    /// republish; on the navigation path it is a blocked screen.
    ///
    /// So: hydrate from the PUBLISHED WINDOW — the same `currentMigrationSnapshot` value the
    /// screen's own `.onAppear` prime paints, read synchronously, never actor-bound. `nil` means no
    /// session has published yet; the screen presents anyway in its explicit evaluating state
    /// (chrome + "Evaluating state…"), and its own subscription + `refreshMigrationSnapshot` kick
    /// fill it the moment the actor frees. The push is unconditional and immediate.
    private func statusResumeState(accountUUID: AccountUUID?, isFlowRoot: Bool) -> MigrationStatus.State {
        let snapshot = migrationManager.currentMigrationSnapshot(accountUUID)
        let stalledRow = snapshot?.transfers.first { $0.status == MigrationTransferRow.Status.overdue }
        var state = MigrationStatus.State(
            presentation: .resume,
            rows: IdentifiedArrayOf(uniqueElements: snapshot?.transfers ?? []),
            totalDurationHours: snapshot?.summary.estimatedDurationHours,
            stalledNumber: (stalledRow?.index ?? 0) + 1,
            stalledHoursAgo: stalledRow?.hoursFromNow ?? 0,
            isFlowRoot: isFlowRoot
        )
        state.isTorHoldActive = snapshot?.isTorHoldActive ?? false
        state.isEvaluating = snapshot == nil
        if let snapshot {
            state.poolFlow = snapshot
        }
        return state
    }

    /// R13 Brick 2: see `statusResumeState` — same one-read rule, same published-window source.
    private func statusProgressState(accountUUID: AccountUUID?, isFlowRoot: Bool) -> MigrationStatus.State {
        let snapshot = migrationManager.currentMigrationSnapshot(accountUUID)
        var state = MigrationStatus.State(
            presentation: .progress,
            rows: IdentifiedArrayOf(uniqueElements: snapshot?.transfers ?? []),
            totalDurationHours: snapshot?.summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot
        )
        state.isTorHoldActive = snapshot?.isTorHoldActive ?? false
        state.isEvaluating = snapshot == nil
        if let snapshot {
            state.poolFlow = snapshot
        }
        return state
    }

    // MARK: - Re-entry (#1930 :2636)

    /// Maps `migrationManager.reentryRoute()` onto the flow-root screen to append. `.entry` appends
    /// nothing — Entry is the coordinator's own root screen, already showing.
    ///
    private func reentryPathState(accountUUID: AccountUUID?) async -> Path.State? {
        switch await migrationManager.reentryRoute() {
        case .statusResume:
            return .status(statusResumeState(accountUUID: accountUUID, isFlowRoot: true))

        case .statusProgress:
            return .status(statusProgressState(accountUUID: accountUUID, isFlowRoot: true))

        // (`.reviewManual` — the manual-delivery per-transfer re-entry — was REMOVED 2026-08-07
        // with the whole manual-tap send surface.)

        // PHASE 5 / PHASE 6: these two used to fall through to Entry because their screens did not
        // exist. They exist now, and re-entry lands on them directly — which is the whole point: a
        // run needing attention must say so at the door, not present the fork again as if nothing
        // had happened.
        case .recovery(let isExpired):
            return .recovery(await recoveryState(accountUUID: accountUUID, isExpired: isExpired, isFlowRoot: true))

        case .complete:
            return .complete(await completeState(accountUUID: accountUUID, isFlowRoot: true))

        case .entry:
            return nil
        }
    }

    // MARK: - PHASE 5 / PHASE 6 state hydration

    /// PHASE 5: the attention screen's state, hydrated from the live rows so the "Transfers {a}–{b}"
    /// range in the copy names the transfers that actually need attention rather than a placeholder.
    ///
    /// `isExpired` comes from the re-entry route (which derives it from the engine's own attention
    /// reason), so the screen never has to guess which of the two lanes it is on.
    private func recoveryState(accountUUID: AccountUUID?, isExpired: Bool, isFlowRoot: Bool) async -> MigrationRecovery.State {
        let rows = await migrationManager.migrationTransfers(accountUUID)
        // The affected rows are the ones that are not already on the chain's side. R11:
        // `.confirming` is excluded like `.sent` — a broadcast-or-mined transfer awaiting the
        // wallet's own sync cannot be re-planned any more than a green one can, and naming it in
        // the recovery range would claim attention over a transfer that is already delivered.
        // Falling back to the whole list's bounds (rather than to the hardcoded 3–5 the screen
        // defaults to) keeps the copy honest even if the status classification is momentarily
        // empty.
        let affected = rows.filter {
            $0.status != MigrationTransferRow.Status.sent && $0.status != MigrationTransferRow.Status.confirming
        }
        let candidates = affected.isEmpty ? rows : affected
        return MigrationRecovery.State(
            reason: isExpired ? .expired : .notesSpent,
            firstTransfer: (candidates.first?.index ?? 0) + 1,
            lastTransfer: (candidates.last?.index ?? 0) + 1,
            isFlowRoot: isFlowRoot
        )
    }

    /// PHASE 6: the terminal screen's state. `dust` drives the residual fork — `MigrationComplete
    /// .State`'s own init derives `.offered` from a non-zero value, so nothing here names it.
    ///
    /// `migrationLockedAmount` wins over `summary.dust` when the residual is ALREADY locked: after a
    /// lock, `migrationSummary().dust` re-plans from live spendable notes and reports zero, so
    /// reading it alone would make a locked balance vanish from the screen that exists to report it.
    private func completeState(accountUUID: AccountUUID?, isFlowRoot: Bool) async -> MigrationComplete.State {
        let summary = await migrationManager.migrationSummary(accountUUID)
        let isLocked = await migrationManager.isMigrationDustLocked(accountUUID)
        let lockedAmount = await migrationManager.migrationLockedAmount(accountUUID)
        return MigrationComplete.State(
            totalTransferred: summary.transferred,
            dust: isLocked ? lockedAmount : summary.dust,
            transfersSent: summary.transfersSent,
            transfersTotal: summary.transfersTotal,
            durationHours: summary.estimatedDurationHours,
            isFlowRoot: isFlowRoot,
            dustResolution: isLocked ? .locked : nil
        )
    }
}
